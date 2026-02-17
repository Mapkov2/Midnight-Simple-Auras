-- ########################################################
-- MSA_UpdateEngine.lua  (v2 â€“ perf + item autobuff)
--
-- Changes vs original:
--   â€¢ 10 Hz throttle (coalesce rapid events)
--   â€¢ ShouldLoad â†’ delegates to MSWA_ShouldLoadAura
--   â€¢ PositionButton moved outside UpdateSpells (no closure alloc)
--   â€¢ Item section: AUTOBUFF mode added (mirrors spell AUTOBUFF)
--   â€¢ Item CD trigger via BAG_UPDATE_COOLDOWN
--   â€¢ Lightweight autobuff tick (no full rebuild per frame)
-- ########################################################

local pairs, type, pcall, tostring, tonumber = pairs, type, pcall, tostring, tonumber
local GetTime         = GetTime
local GetItemCooldown = GetItemCooldown
local GetItemIcon     = GetItemIcon

-- Local upvalues for hot path
local MSWA_GetDB                = MSWA_GetDB
local MSWA_GetAuraGroup         = MSWA_GetAuraGroup
local MSWA_GetAnchorFrame       = MSWA_GetAnchorFrame
local MSWA_GetIconForKey         = MSWA_GetIconForKey
local MSWA_IsSpellInstanceKey    = MSWA_IsSpellInstanceKey
local MSWA_KeyToSpellID          = MSWA_KeyToSpellID
local MSWA_IsItemKey             = MSWA_IsItemKey
local MSWA_KeyToItemID           = MSWA_KeyToItemID
local MSWA_GetSpellCooldown      = MSWA_GetSpellCooldown
local MSWA_ApplyCooldownFrame    = MSWA_ApplyCooldownFrame
local MSWA_ClearCooldownFrame    = MSWA_ClearCooldownFrame
local MSWA_ClearCooldown         = MSWA_ClearCooldown
local MSWA_UpdateBuffVisual      = MSWA_UpdateBuffVisual
local MSWA_ApplyTextStyleToButton = MSWA_ApplyTextStyleToButton
local MSWA_ApplyGrayscaleOnCooldownToButton = MSWA_ApplyGrayscaleOnCooldownToButton
local MSWA_ReskinMasque          = MSWA_ReskinMasque
local MSWA_TryComputeExpirationFromRemaining = MSWA_TryComputeExpirationFromRemaining
local MSWA_UpdateGlow            = MSWA_UpdateGlow
local MSWA_StopGlow              = MSWA_StopGlow

-----------------------------------------------------------
-- Constants
-----------------------------------------------------------

local THROTTLE_INTERVAL = 0.100   -- 10 Hz

-----------------------------------------------------------
-- Engine frame (hidden = zero CPU)
-----------------------------------------------------------

local engineFrame = CreateFrame("Frame", "MSWA_EngineFrame", UIParent)
engineFrame:Hide()

local dirty          = false
local autoBuffActive = false
local lastFullUpdate = 0
local forceImmediate = false

-----------------------------------------------------------
-- Forward-declared event registration
-----------------------------------------------------------

local MSWA_UpdateEventRegistration -- assigned below

-----------------------------------------------------------
-- Icon state cache
-----------------------------------------------------------

local iconCache = {}

local function WipeIconCache()
    for i = 1, MSWA.MAX_ICONS do
        iconCache[i] = nil
    end
end

-----------------------------------------------------------
-- ShouldLoad â†’ centralized MSWA_ShouldLoadAura
-----------------------------------------------------------

local function ShouldLoad(s)
    return MSWA_ShouldLoadAura(s)
end

-----------------------------------------------------------
-- PositionButton  (top-level, zero closure allocation)
-----------------------------------------------------------

local function PositionButton(btn, s, key, idx, frame, ICON_SIZE, ICON_SPACE, db)
    local gid = MSWA_GetAuraGroup(key)
    local group = gid and db.groups and db.groups[gid] or nil
    if group then
        local gx = group.x or 0
        local gy = group.y or 0
        local lx = (s and s.x or 0) + gx
        local ly = (s and s.y or 0) + gy
        btn:SetPoint("CENTER", frame, "CENTER", lx, ly)
        local size = group.size or ICON_SIZE
        local w = (s and s.width) or size
        local h = (s and s.height) or w
        btn:SetSize(w, h)
    else
        local anchorFrame = MSWA_GetAnchorFrame(s or {})
        local lx = s and s.x or 0
        local ly = s and s.y or 0
        if s and s.anchorFrame then
            btn:SetPoint("CENTER", anchorFrame, "CENTER", lx, ly)
        elseif s and s.x and s.y then
            btn:SetPoint("CENTER", frame, "CENTER", lx, ly)
        else
            local offsetX = (idx - 1) * (ICON_SIZE + ICON_SPACE)
            btn:SetPoint("LEFT", frame, "LEFT", offsetX, 0)
        end
        if s and s.width and s.height then
            btn:SetSize(s.width, s.height)
        else
            btn:SetSize(ICON_SIZE, ICON_SIZE)
        end
    end
end

-----------------------------------------------------------
-- UpdateSpells (the main hot loop)
-----------------------------------------------------------

local function MSWA_UpdateSpells()
    local db            = MSWA_GetDB()
    local tracked       = db.trackedSpells
    local trackedItems  = db.trackedItems or {}
    local settingsTable = db.spellSettings or {}
    local index         = 1
    local frame         = MSWA.frame
    local ICON_SIZE     = MSWA.ICON_SIZE
    local ICON_SPACE    = MSWA.ICON_SPACE
    local MAX_ICONS     = MSWA.MAX_ICONS
    local previewMode   = MSWA.previewMode
    local autoBuff      = MSWA._autoBuff

    -----------------------------------------------------------
    -- 1) Spells  (logic preserved 1:1 from original)
    -----------------------------------------------------------
    if C_Spell and C_Spell.GetSpellCooldown then
        for trackedKey, enabled in pairs(tracked) do
            local spellID
            if type(trackedKey) == "number" then
                spellID = trackedKey
            elseif MSWA_IsSpellInstanceKey(trackedKey) then
                spellID = MSWA_KeyToSpellID(trackedKey)
            end
            if enabled and spellID and index <= MAX_ICONS then
                local btn  = MSWA.icons[index]
                local key  = trackedKey
                local icon = MSWA_GetIconForKey(key)

                btn.icon:SetTexture(icon)
                btn:Show()
                btn.spellID = key
                MSWA_ApplyTextStyleToButton(btn, key)

                btn:ClearAllPoints()
                local s = settingsTable[key] or settingsTable[tostring(key)]
                local previewOnly = not ShouldLoad(s)
                if previewOnly and not previewMode then
                    -- skip slot

                elseif s and s.auraMode == "AUTOBUFF" then
                    -- ========== SPELL AUTO BUFF MODE ==========
                    local ab = autoBuff[key]
                    local buffDur = tonumber(s.autoBuffDuration) or 10
                    if buffDur < 0.1 then buffDur = 0.1 end

                    local showBuff = false
                    if ab and ab.active then
                        local now = GetTime()
                        if (now - ab.startTime) < buffDur then
                            showBuff = true
                        else
                            ab.active = false
                        end
                    end

                    if showBuff then
                        btn.icon:SetTexture(icon)
                        btn:Show()
                        btn.spellID = key
                        MSWA_ApplyTextStyleToButton(btn, key)
                        PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db)
                        MSWA_ApplyCooldownFrame(btn.cooldown, ab.startTime, buffDur, 1)
                        btn.icon:SetDesaturated(previewOnly)
                        btn:SetAlpha(previewOnly and 0.5 or 1.0)
                        if btn.count then btn.count:SetText(""); btn.count:Hide() end
                        btn._msaGlowRemaining = buffDur - (GetTime() - ab.startTime)
                        if btn._msaGlowRemaining < 0 then btn._msaGlowRemaining = 0 end
                        btn._msaGlowOnCD = btn._msaGlowRemaining > 0
                        index = index + 1
                    elseif previewMode then
                        btn.icon:SetTexture(icon)
                        btn:Show()
                        btn.spellID = key
                        MSWA_ApplyTextStyleToButton(btn, key)
                        PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db)
                        MSWA_ClearCooldownFrame(btn.cooldown)
                        btn.icon:SetDesaturated(true)
                        btn:SetAlpha(0.5)
                        if btn.count then btn.count:SetText(""); btn.count:Hide() end
                        btn._msaGlowRemaining = 0
                        btn._msaGlowOnCD = false
                        index = index + 1
                    else
                        btn:Hide()
                        btn.icon:SetTexture(nil)
                        MSWA_ClearCooldownFrame(btn.cooldown)
                        MSWA_StopGlow(btn)
                        btn.spellID = nil
                    end

                else
                    -- ========== NORMAL SPELL MODE ==========
                    PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db)

                    local cdInfo = MSWA_GetSpellCooldown(spellID)
                    if cdInfo then
                        local exp = cdInfo.expirationTime
                        if C_Spell and C_Spell.GetSpellCooldownRemaining then
                            local remaining = C_Spell.GetSpellCooldownRemaining(spellID)
                            local exp2 = MSWA_TryComputeExpirationFromRemaining(remaining)
                            if exp2 ~= nil then exp = exp2 end
                        end
                        MSWA_ApplyCooldownFrame(btn.cooldown, cdInfo.startTime, cdInfo.duration, cdInfo.modRate, exp)
                    else
                        MSWA_ClearCooldown(btn)
                    end

                    MSWA_UpdateBuffVisual(btn, key)
                    MSWA_ApplyGrayscaleOnCooldownToButton(btn, key)

                    -- Store glow data for end-of-loop glow pass
                    if cdInfo and cdInfo.startTime and cdInfo.duration and cdInfo.duration > 0 then
                        local gr = (cdInfo.startTime + cdInfo.duration) - GetTime()
                        btn._msaGlowRemaining = gr > 0 and gr or 0
                        btn._msaGlowOnCD = gr > 0
                    else
                        btn._msaGlowRemaining = 0
                        btn._msaGlowOnCD = false
                    end

                    if previewOnly then
                        btn.icon:SetDesaturated(true)
                        btn:SetAlpha(0.5)
                    else
                        btn:SetAlpha(1.0)
                    end

                    index = index + 1
                end
            end
        end
    end

    -----------------------------------------------------------
    -- 2) Items  (original normal mode + new AUTOBUFF mode)
    -----------------------------------------------------------
    for itemID, enabled in pairs(trackedItems) do
        if enabled and index <= MAX_ICONS then
            if GetItemCooldown and GetItemIcon then
                local key = ("item:%d"):format(itemID)
                local tex = MSWA_GetIconForKey(key)
                if tex then
                    local btn = MSWA.icons[index]
                    local s   = settingsTable[key] or settingsTable[tostring(key)]
                    local previewOnly = not ShouldLoad(s)

                    if previewOnly and not previewMode then
                        -- skip

                    elseif s and s.auraMode == "AUTOBUFF" then
                        -- ========== ITEM AUTO BUFF MODE (new) ==========
                        local ab = autoBuff[key]
                        local buffDur = tonumber(s.autoBuffDuration) or 10
                        if buffDur < 0.1 then buffDur = 0.1 end

                        local showBuff = false
                        if ab and ab.active then
                            local now = GetTime()
                            if (now - ab.startTime) < buffDur then
                                showBuff = true
                            else
                                ab.active = false
                            end
                        end

                        if showBuff then
                            btn.icon:SetTexture(tex)
                            btn:Show()
                            btn.spellID = key
                            MSWA_ApplyTextStyleToButton(btn, key)
                            btn:ClearAllPoints()
                            PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db)
                            MSWA_ApplyCooldownFrame(btn.cooldown, ab.startTime, buffDur, 1)
                            btn.icon:SetDesaturated(previewOnly)
                            btn:SetAlpha(previewOnly and 0.5 or 1.0)
                            if btn.count then btn.count:SetText(""); btn.count:Hide() end
                            btn._msaGlowRemaining = buffDur - (GetTime() - ab.startTime)
                            if btn._msaGlowRemaining < 0 then btn._msaGlowRemaining = 0 end
                            btn._msaGlowOnCD = btn._msaGlowRemaining > 0
                            index = index + 1
                        elseif previewMode then
                            btn.icon:SetTexture(tex)
                            btn:Show()
                            btn.spellID = key
                            MSWA_ApplyTextStyleToButton(btn, key)
                            btn:ClearAllPoints()
                            PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db)
                            MSWA_ClearCooldownFrame(btn.cooldown)
                            btn.icon:SetDesaturated(true)
                            btn:SetAlpha(0.5)
                            if btn.count then btn.count:SetText(""); btn.count:Hide() end
                            btn._msaGlowRemaining = 0
                            btn._msaGlowOnCD = false
                            index = index + 1
                        else
                            btn:Hide()
                            btn.icon:SetTexture(nil)
                            MSWA_ClearCooldownFrame(btn.cooldown)
                            MSWA_StopGlow(btn)
                            btn.spellID = nil
                        end

                    else
                        -- ========== NORMAL ITEM MODE (original) ==========
                        btn.icon:SetTexture(tex)
                        btn:Show()
                        btn.spellID = key
                        MSWA_ApplyTextStyleToButton(btn, key)

                        btn:ClearAllPoints()
                        PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db)

                        local start, duration, enable, modRate = GetItemCooldown(itemID)
                        MSWA_ApplyCooldownFrame(btn.cooldown, start, duration, modRate)
                        MSWA_UpdateBuffVisual(btn, key)
                        MSWA_ApplyGrayscaleOnCooldownToButton(btn, key)

                        -- Store glow data for end-of-loop glow pass
                        if start and start > 0 and duration and duration > 1.5 then
                            local gr = (start + duration) - GetTime()
                            btn._msaGlowRemaining = gr > 0 and gr or 0
                            btn._msaGlowOnCD = gr > 0
                        else
                            btn._msaGlowRemaining = 0
                            btn._msaGlowOnCD = false
                        end

                        if previewOnly then
                            btn.icon:SetDesaturated(true)
                            btn:SetAlpha(0.5)
                        else
                            btn:SetAlpha(1.0)
                        end

                        index = index + 1
                    end
                end
            end
        end
    end

    -----------------------------------------------------------
    -- 3) Glow pass: apply/remove glow on all visible buttons
    -----------------------------------------------------------
    for i = 1, index - 1 do
        local btn = MSWA.icons[i]
        if btn and btn:IsShown() and btn.spellID then
            MSWA_UpdateGlow(btn, btn.spellID, btn._msaGlowRemaining or 0, btn._msaGlowOnCD or false)
        end
    end

    -----------------------------------------------------------
    -- 4) Hide remaining buttons
    -----------------------------------------------------------
    for i = index, MAX_ICONS do
        local btn = MSWA.icons[i]
        btn:Hide()
        btn.icon:SetTexture(nil)
        MSWA_ClearCooldown(btn)
        MSWA_StopGlow(btn)
        btn.spellID = nil
        if btn.count then btn.count:SetText(""); btn.count:Hide() end
    end

    MSWA.activeIconCount = index - 1
    MSWA_ReskinMasque()

    if MSWA_UpdateEventRegistration then
        MSWA_UpdateEventRegistration()
    end

    -----------------------------------------------------------
    -- 5) Check if any auto-buff is still active (for engine)
    -----------------------------------------------------------
    autoBuffActive = false
    local now = GetTime()
    for key, ab in pairs(autoBuff) do
        if ab and ab.active then
            local s2 = settingsTable[key] or settingsTable[tostring(key)]
            local dur = (s2 and tonumber(s2.autoBuffDuration)) or 10
            if (now - ab.startTime) < dur then
                autoBuffActive = true
                break
            end
        end
    end
end

-- Export globally
MSWA.UpdateSpells    = MSWA_UpdateSpells
_G.MSWA_UpdateSpells = MSWA_UpdateSpells

-----------------------------------------------------------
-- Lightweight autobuff tick (no full rebuild per frame)
-----------------------------------------------------------

local function AutoBuffTick(settingsTable)
    local now     = GetTime()
    local anyLeft = false
    local anyExpired = false

    for key, ab in pairs(MSWA._autoBuff) do
        if ab and ab.active then
            local s2 = settingsTable[key] or settingsTable[tostring(key)]
            local dur = (s2 and tonumber(s2.autoBuffDuration)) or 10
            if (now - ab.startTime) < dur then
                anyLeft = true
            else
                ab.active = false
                anyExpired = true
            end
        end
    end

    autoBuffActive = anyLeft
    if anyExpired then
        dirty = true
    end
end

-----------------------------------------------------------
-- OnUpdate: 10 Hz throttled + lightweight autobuff tick
-----------------------------------------------------------

engineFrame:SetScript("OnUpdate", function(self)
    local now = GetTime()

    if autoBuffActive then
        local db = MSWA_GetDB()
        AutoBuffTick(db.spellSettings or {})
    end

    if dirty then
        if forceImmediate or (now - lastFullUpdate) >= THROTTLE_INTERVAL then
            dirty = false
            forceImmediate = false
            lastFullUpdate = now
            MSWA_UpdateSpells()
        end
    end

    if not dirty and not autoBuffActive then
        self:Hide()
    end
end)

-----------------------------------------------------------
-- Request / Force
-----------------------------------------------------------

function MSWA_RequestUpdateSpells()
    dirty = true
    engineFrame:Show()
end

function MSWA_ForceUpdateSpells()
    dirty = true
    forceImmediate = true
    engineFrame:Show()
end

function MSWA_InvalidateIconCache()
    WipeIconCache()
    MSWA_ForceUpdateSpells()
end

-----------------------------------------------------------
-- Event registration (dynamic based on active icons)
-----------------------------------------------------------

MSWA_UpdateEventRegistration = function()
    local mainFrame = MSWA.frame
    if not mainFrame or not mainFrame.RegisterEvent then return end

    if MSWA.activeIconCount and MSWA.activeIconCount > 0 then
        mainFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        mainFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
        mainFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
        mainFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
        mainFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
        mainFrame:RegisterEvent("BAG_UPDATE")
        if mainFrame.RegisterUnitEvent then
            mainFrame:RegisterUnitEvent("UNIT_AURA", "player")
        else
            mainFrame:RegisterEvent("UNIT_AURA")
        end
    else
        mainFrame:UnregisterEvent("SPELL_UPDATE_COOLDOWN")
        mainFrame:UnregisterEvent("PLAYER_TALENT_UPDATE")
        mainFrame:UnregisterEvent("PLAYER_EQUIPMENT_CHANGED")
        mainFrame:UnregisterEvent("UNIT_INVENTORY_CHANGED")
        mainFrame:UnregisterEvent("BAG_UPDATE_COOLDOWN")
        mainFrame:UnregisterEvent("BAG_UPDATE")
        mainFrame:UnregisterEvent("UNIT_AURA")
    end
end

-----------------------------------------------------------
-- Main event handler
-----------------------------------------------------------

local mainFrame = MSWA.frame

mainFrame:RegisterEvent("PLAYER_LOGIN")
mainFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

mainFrame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        MSWA_UpdatePositionFromDB()
        MSWA_RefreshPlayerIdentity()
        WipeIconCache()
        MSWA_ForceUpdateSpells()
        MSWA_ApplyUIFont()
    elseif event == "UNIT_INVENTORY_CHANGED" and arg1 ~= "player" then
        return
    elseif event == "UNIT_AURA" then
        if arg1 ~= "player" then return end
        MSWA_RequestUpdateSpells()
    elseif event == "SPELL_UPDATE_COOLDOWN"
        or event == "PLAYER_TALENT_UPDATE"
        or event == "PLAYER_EQUIPMENT_CHANGED"
        or event == "UNIT_INVENTORY_CHANGED"
        or event == "BAG_UPDATE_COOLDOWN"
        or event == "BAG_UPDATE" then
        MSWA_RequestUpdateSpells()
    end
end)

-----------------------------------------------------------
-- Load filter refresh (combat/encounter state changes)
-----------------------------------------------------------
do
    local loadFilterFrame = CreateFrame("Frame")
    loadFilterFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    loadFilterFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    loadFilterFrame:RegisterEvent("ENCOUNTER_START")
    loadFilterFrame:RegisterEvent("ENCOUNTER_END")

    loadFilterFrame:SetScript("OnEvent", function()
        MSWA_InvalidateIconCache()
        if MSWA_RefreshOptionsList and MSWA and MSWA.optionsFrame and MSWA.optionsFrame:IsShown() then
            MSWA_RefreshOptionsList()
        end
    end)
end

-----------------------------------------------------------
-- Auto Buff (Spells): cast detection via UNIT_SPELLCAST_SUCCEEDED
-- (preserved 1:1 from original)
-----------------------------------------------------------
do
    local abFrame = CreateFrame("Frame")
    if abFrame.RegisterUnitEvent then
        abFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    else
        abFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    end

    abFrame:SetScript("OnEvent", function(self, event, unit, castGUID, castSpellID)
        if unit and unit ~= "player" then return end
        if not castSpellID then return end

        local db = MSWA_GetDB()
        if not db or not db.trackedSpells or not db.spellSettings then return end

        local triggered = false
        for trackedKey, enabled in pairs(db.trackedSpells) do
            if enabled then
                local sid
                if type(trackedKey) == "number" then
                    sid = trackedKey
                elseif MSWA_IsSpellInstanceKey(trackedKey) then
                    sid = MSWA_KeyToSpellID(trackedKey)
                end
                if sid == castSpellID then
                    local s = db.spellSettings[trackedKey] or db.spellSettings[tostring(trackedKey)]
                    if s and s.auraMode == "AUTOBUFF" then
                        MSWA._autoBuff[trackedKey] = {
                            active    = true,
                            startTime = GetTime(),
                        }
                        triggered = true
                    end
                end
            end
        end

        if triggered then
            autoBuffActive = true
            MSWA_ForceUpdateSpells()
        end
    end)
end

-----------------------------------------------------------
-- Auto Buff (Items): cooldown-start detection
--   Items don't fire UNIT_SPELLCAST_SUCCEEDED reliably,
--   so we detect when GetItemCooldown transitions from
--   idle â†’ active for tracked AUTOBUFF items.
-----------------------------------------------------------
do
    local itemCDFrame = CreateFrame("Frame")
    itemCDFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
    itemCDFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")

    local lastItemCDStart = {}

    itemCDFrame:SetScript("OnEvent", function()
        if not GetItemCooldown then return end
        local db = MSWA_GetDB()
        if not db or not db.trackedItems or not db.spellSettings then return end

        local triggered = false
        for itemID, enabled in pairs(db.trackedItems) do
            if enabled then
                local key = ("item:%d"):format(itemID)
                local s = db.spellSettings[key] or db.spellSettings[tostring(key)]
                if s and s.auraMode == "AUTOBUFF" then
                    local start, duration = GetItemCooldown(itemID)
                    local prevStart = lastItemCDStart[key] or 0

                    -- Fresh cooldown: start changed AND duration > 1.5s (skip GCD)
                    if start and start > 0 and duration and duration > 1.5
                       and start ~= prevStart then
                        local ab = MSWA._autoBuff[key]
                        if not ab or not ab.active then
                            MSWA._autoBuff[key] = {
                                active    = true,
                                startTime = GetTime(),
                            }
                            triggered = true
                        end
                    end

                    if start and start > 0 and duration and duration > 1.5 then
                        lastItemCDStart[key] = start
                    else
                        lastItemCDStart[key] = 0
                    end
                end
            end
        end

        if triggered then
            autoBuffActive = true
            MSWA_ForceUpdateSpells()
        end
    end)
end
