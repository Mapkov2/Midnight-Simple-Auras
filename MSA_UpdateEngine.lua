-- ########################################################
-- MSA_UpdateEngine.lua  (v4 â€“ zero waste)
--
-- Perf fixes vs v3:
--   â€¢ Combat/encounter state cached once, not per icon
--   â€¢ Icon texture cached per button (skip GetSpellInfo)
--   â€¢ Masque ReSkin ONLY when icon count changes
--   â€¢ Event registration ONLY when icon count changes
--   â€¢ Glow settings passed directly (zero DB lookup)
--   â€¢ MSWA_GetDB() returns cached table (no migration checks)
-- ########################################################

local pairs, type, pcall, tonumber, tostring = pairs, type, pcall, tonumber, tostring
local GetTime         = GetTime
local GetItemCooldown = GetItemCooldown
local GetItemIcon     = GetItemIcon

-----------------------------------------------------------
-- Constants
-----------------------------------------------------------

local THROTTLE_INTERVAL = 0.100   -- 10 Hz

-----------------------------------------------------------
-- Engine frame (hidden = zero CPU)
-----------------------------------------------------------

local engineFrame = CreateFrame("Frame", "MSWA_EngineFrame", UIParent)
engineFrame:Hide()

local dirty              = false
local autoBuffActive     = false
local anyCooldownActive  = false
local lastFullUpdate     = 0
local forceImmediate     = false
local lastActiveCount    = 0

-----------------------------------------------------------
-- Forward-declared
-----------------------------------------------------------

local MSWA_UpdateEventRegistration

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
-- Item key cache (avoid string.format in hot loop)
-----------------------------------------------------------

local itemKeyCache = {}

local function GetItemKey(itemID)
    local k = itemKeyCache[itemID]
    if not k then
        k = ("item:%d"):format(itemID)
        itemKeyCache[itemID] = k
    end
    return k
end

-----------------------------------------------------------
-- PositionButton (top-level, zero closure allocation)
-----------------------------------------------------------

local function PositionButton(btn, s, key, idx, frame, ICON_SIZE, ICON_SPACE, db)
    local gid = MSWA_GetAuraGroup(key)
    local group = gid and db.groups and db.groups[gid] or nil
    if group then
        local gx = group.x or 0
        local gy = group.y or 0
        btn:SetPoint("CENTER", frame, "CENTER", (s and s.x or 0) + gx, (s and s.y or 0) + gy)
        local size = group.size or ICON_SIZE
        btn:SetSize((s and s.width) or size, (s and s.height) or size)
    else
        local anchorFrame = MSWA_GetAnchorFrame(s or {})
        local lx = s and s.x or 0
        local ly = s and s.y or 0
        if s and s.anchorFrame then
            btn:SetPoint("CENTER", anchorFrame, "CENTER", lx, ly)
        elseif s and s.x and s.y then
            btn:SetPoint("CENTER", frame, "CENTER", lx, ly)
        else
            btn:SetPoint("LEFT", frame, "LEFT", (idx - 1) * (ICON_SIZE + ICON_SPACE), 0)
        end
        if s and s.width and s.height then
            btn:SetSize(s.width, s.height)
        else
            btn:SetSize(ICON_SIZE, ICON_SIZE)
        end
    end
end

-----------------------------------------------------------
-- Inline helpers
-----------------------------------------------------------

local function ClearStackAndCount(btn)
    if btn.count then btn.count:SetText(""); btn.count:Hide() end
    if btn.stackText then btn.stackText:SetText(""); btn.stackText:Hide() end
end

local function HideButton(btn)
    btn:Hide()
    btn.icon:SetTexture(nil)
    btn._msaCachedKey = nil
    MSWA_ClearCooldownFrame(btn.cooldown)
    MSWA_StopGlow(btn)
    btn.spellID = nil
end

-----------------------------------------------------------
-- SetIconTexture with cache (skip GetSpellInfo if same key)
-----------------------------------------------------------

local function SetIconTexture(btn, key)
    if btn._msaCachedKey == key then return end
    btn._msaCachedKey = key
    btn.icon:SetTexture(MSWA_GetIconForKey(key))
end

-----------------------------------------------------------
-- Alpha computation: cdAlpha, oocAlpha, combatAlpha
-----------------------------------------------------------

local function ComputeAlpha(s, isOnCD, inCombat)
    local alpha = 1.0
    if inCombat then
        local ca = s and tonumber(s.combatAlpha)
        if ca then alpha = alpha * ca end
    else
        local oa = s and tonumber(s.oocAlpha)
        if oa then alpha = alpha * oa end
    end
    if isOnCD then
        local cda = s and tonumber(s.cdAlpha)
        if cda then alpha = alpha * cda end
    end
    return alpha
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
    local icons         = MSWA.icons

    -- Selected-aura preview: when options are open and an aura is selected,
    -- always show that aura so the user can see what they're editing.
    local optFrame      = MSWA.optionsFrame
    local selectedKey   = (optFrame and optFrame:IsShown() and MSWA.selectedSpellID) or nil

    -- Cache API availability once
    local hasGetCD          = C_Spell and C_Spell.GetSpellCooldown
    local hasGetCDRemaining = C_Spell and C_Spell.GetSpellCooldownRemaining

    -- Cache combat/encounter state ONCE (not per icon!)
    local inCombat    = InCombatLockdown and InCombatLockdown() and true or false
    local inEncounter = IsEncounterInProgress and IsEncounterInProgress() and true or false

    -----------------------------------------------------------
    -- 1) Spells
    -----------------------------------------------------------
    if hasGetCD then
        for trackedKey, enabled in pairs(tracked) do
            if index > MAX_ICONS then break end
            if enabled then
                local spellID
                if type(trackedKey) == "number" then
                    spellID = trackedKey
                elseif MSWA_IsSpellInstanceKey(trackedKey) then
                    spellID = MSWA_KeyToSpellID(trackedKey)
                end

                if spellID then
                    local key = trackedKey
                    local s   = settingsTable[key] or settingsTable[tostring(key)]
                    local shouldLoad = MSWA_ShouldLoadAura(s, inCombat, inEncounter)

                    if shouldLoad or previewMode or key == selectedKey then
                        local btn = icons[index]

                        SetIconTexture(btn, key)
                        btn:Show()
                        btn.spellID = key
                        btn:ClearAllPoints()

                        MSWA_ApplyTextStyle(btn, db, s)
                        MSWA_ApplyStackStyle(btn, s)

                        if s and s.auraMode == "AUTOBUFF" then
                            -- ========== SPELL AUTO BUFF MODE ==========
                            local ab = autoBuff[key]
                            local buffDur = tonumber(s.autoBuffDuration) or 10
                            if buffDur < 0.1 then buffDur = 0.1 end

                            local showBuff = false
                            if ab and ab.active then
                                local elapsed = GetTime() - ab.startTime
                                if elapsed < buffDur then
                                    showBuff = true
                                else
                                    ab.active = false
                                end
                            end

                            if showBuff then
                                PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db)
                                MSWA_ApplyCooldownFrame(btn.cooldown, ab.startTime, buffDur, 1)
                                btn.icon:SetDesaturated(false)
                                btn:SetAlpha(ComputeAlpha(s, true, inCombat))
                                ClearStackAndCount(btn)

                                local glowRem = buffDur - (GetTime() - ab.startTime)
                                if glowRem < 0 then glowRem = 0 end
                                local gs = s and s.glow
                                if gs and gs.enabled then
                                    MSWA_UpdateGlow_Fast(btn, gs, glowRem, glowRem > 0)
                                elseif btn._msaGlowActive then
                                    MSWA_StopGlow(btn)
                                end
                                MSWA_ApplyConditionalTextColor_Fast(btn, s, db, glowRem, glowRem > 0)
                                MSWA_ApplySwipeDarken_Fast(btn, s)
                                index = index + 1

                            elseif previewMode or key == selectedKey then
                                PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db)
                                MSWA_ClearCooldownFrame(btn.cooldown)
                                btn.icon:SetDesaturated(false)
                                btn:SetAlpha(ComputeAlpha(s, false, inCombat))
                                ClearStackAndCount(btn)
                                MSWA_StopGlow(btn)
                                index = index + 1
                            else
                                HideButton(btn)
                            end

                        else
                            -- ========== NORMAL SPELL MODE ==========
                            PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db)

                            local cdInfo = C_Spell.GetSpellCooldown(spellID)
                            if cdInfo then
                                local exp = cdInfo.expirationTime
                                if hasGetCDRemaining then
                                    local rem = C_Spell.GetSpellCooldownRemaining(spellID)
                                    if type(rem) == "number" then
                                        exp = GetTime() + rem
                                    end
                                end
                                MSWA_ApplyCooldownFrame(btn.cooldown, cdInfo.startTime, cdInfo.duration, cdInfo.modRate, exp)
                            else
                                MSWA_ClearCooldownFrame(btn.cooldown)
                            end

                            MSWA_UpdateBuffVisual_Fast(btn, s, spellID, false, nil)

                            -- Grayscale
                            if s and s.grayOnCooldown then
                                btn.icon:SetDesaturated(MSWA_IsCooldownActive(btn))
                            else
                                btn.icon:SetDesaturated(false)
                            end

                            -- Glow/conditional: IsCooldownActive is taint-safe (frame state),
                            -- remaining from API via pcall (may be 0 if tainted)
                            local glowOnCD = MSWA_IsCooldownActive(btn)
                            local glowRem  = MSWA_GetSpellGlowRemaining(spellID)

                            -- Alpha: combat state + cooldown
                            btn:SetAlpha(ComputeAlpha(s, glowOnCD, inCombat))

                            -- Glow (pass settings directly, zero DB lookup)
                            local gs = s and s.glow
                            if gs and gs.enabled then
                                MSWA_UpdateGlow_Fast(btn, gs, glowRem, glowOnCD)
                            elseif btn._msaGlowActive then
                                MSWA_StopGlow(btn)
                            end
                            MSWA_ApplyConditionalTextColor_Fast(btn, s, db, glowRem, glowOnCD)
                            MSWA_ApplySwipeDarken_Fast(btn, s)

                            index = index + 1
                        end
                    end -- shouldLoad or previewMode or selectedKey
                end -- spellID
            end -- enabled
        end
    end

    -----------------------------------------------------------
    -- 2) Items
    -----------------------------------------------------------
    if GetItemCooldown and GetItemIcon then
        for itemID, enabled in pairs(trackedItems) do
            if index > MAX_ICONS then break end
            if enabled then
                local key = GetItemKey(itemID)
                local tex = MSWA_GetIconForKey(key)
                if tex then
                    local s = settingsTable[key] or settingsTable[tostring(key)]
                    local shouldLoad = MSWA_ShouldLoadAura(s, inCombat, inEncounter)

                    if shouldLoad or previewMode or key == selectedKey then
                        local btn = icons[index]

                        SetIconTexture(btn, key)
                        btn:Show()
                        btn.spellID = key
                        btn:ClearAllPoints()

                        MSWA_ApplyTextStyle(btn, db, s)
                        MSWA_ApplyStackStyle(btn, s)

                        if s and s.auraMode == "AUTOBUFF" then
                            -- ========== ITEM AUTO BUFF MODE ==========
                            local ab = autoBuff[key]
                            local buffDur = tonumber(s and s.autoBuffDuration) or 10
                            if buffDur < 0.1 then buffDur = 0.1 end

                            local showBuff = false
                            if ab and ab.active then
                                local elapsed = GetTime() - ab.startTime
                                if elapsed < buffDur then
                                    showBuff = true
                                else
                                    ab.active = false
                                end
                            end

                            if showBuff then
                                PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db)
                                MSWA_ApplyCooldownFrame(btn.cooldown, ab.startTime, buffDur, 1)
                                btn.icon:SetDesaturated(false)
                                btn:SetAlpha(ComputeAlpha(s, true, inCombat))
                                ClearStackAndCount(btn)

                                local glowRem = buffDur - (GetTime() - ab.startTime)
                                if glowRem < 0 then glowRem = 0 end
                                local gs = s and s.glow
                                if gs and gs.enabled then
                                    MSWA_UpdateGlow_Fast(btn, gs, glowRem, glowRem > 0)
                                elseif btn._msaGlowActive then
                                    MSWA_StopGlow(btn)
                                end
                                MSWA_ApplyConditionalTextColor_Fast(btn, s, db, glowRem, glowRem > 0)
                                MSWA_ApplySwipeDarken_Fast(btn, s)
                                index = index + 1

                            elseif previewMode or key == selectedKey then
                                PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db)
                                MSWA_ClearCooldownFrame(btn.cooldown)
                                btn.icon:SetDesaturated(false)
                                btn:SetAlpha(ComputeAlpha(s, false, inCombat))
                                ClearStackAndCount(btn)
                                MSWA_StopGlow(btn)
                                index = index + 1
                            else
                                HideButton(btn)
                            end

                        else
                            -- ========== NORMAL ITEM MODE ==========
                            PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db)

                            local start, duration, enable, modRate = GetItemCooldown(itemID)
                            MSWA_ApplyCooldownFrame(btn.cooldown, start, duration, modRate)

                            MSWA_UpdateBuffVisual_Fast(btn, s, nil, true, itemID)

                            if s and s.grayOnCooldown then
                                btn.icon:SetDesaturated(MSWA_IsCooldownActive(btn))
                            else
                                btn.icon:SetDesaturated(false)
                            end

                            local glowOnCD = MSWA_IsCooldownActive(btn)
                            local glowRem  = MSWA_GetItemGlowRemaining(start, duration)

                            -- Alpha: combat state + cooldown
                            btn:SetAlpha(ComputeAlpha(s, glowOnCD, inCombat))

                            local gs = s and s.glow
                            if gs and gs.enabled then
                                MSWA_UpdateGlow_Fast(btn, gs, glowRem, glowOnCD)
                            elseif btn._msaGlowActive then
                                MSWA_StopGlow(btn)
                            end
                            MSWA_ApplyConditionalTextColor_Fast(btn, s, db, glowRem, glowOnCD)
                            MSWA_ApplySwipeDarken_Fast(btn, s)

                            index = index + 1
                        end
                    end -- shouldLoad or previewMode or selectedKey
                end -- tex
            end -- enabled
        end
    end

    -----------------------------------------------------------
    -- 3) Hide remaining buttons
    -----------------------------------------------------------
    local activeCount = index - 1
    for i = index, MAX_ICONS do
        local btn = icons[i]
        if btn.spellID ~= nil or btn:IsShown() then
            btn:Hide()
            btn.icon:SetTexture(nil)
            btn._msaCachedKey = nil
            MSWA_ClearCooldownFrame(btn.cooldown)
            MSWA_StopGlow(btn)
            btn.spellID = nil
            ClearStackAndCount(btn)
        end
    end

    -----------------------------------------------------------
    -- 4) Masque + events: ONLY when count changes
    -----------------------------------------------------------
    if activeCount ~= lastActiveCount then
        MSWA.activeIconCount = activeCount
        MSWA_ReskinMasque(activeCount)
        MSWA_UpdateEventRegistration()
        lastActiveCount = activeCount
    end

    -----------------------------------------------------------
    -- 5) Check if any auto-buff is still active
    -----------------------------------------------------------
    autoBuffActive = false
    local now = GetTime()
    for key, ab in pairs(autoBuff) do
        if ab and ab.active then
            local s2 = settingsTable[key] or settingsTable[tostring(key)]
            local dur = tonumber(s2 and s2.autoBuffDuration) or 10
            if (now - ab.startTime) < dur then
                autoBuffActive = true
                break
            end
        end
    end

    -----------------------------------------------------------
    -- 6) Check if any icon is on cooldown (keeps engine ticking
    --    for timer-based glow, text color, and alpha conditions)
    -----------------------------------------------------------
    anyCooldownActive = false
    for i = 1, activeCount do
        if MSWA_IsCooldownActive(icons[i]) then
            anyCooldownActive = true
            break
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
    local now = GetTime()
    local anyLeft = false
    local anyExpired = false
    for key, ab in pairs(MSWA._autoBuff) do
        if ab and ab.active then
            local s2 = settingsTable[key] or settingsTable[tostring(key)]
            local dur = tonumber(s2 and s2.autoBuffDuration) or 10
            if (now - ab.startTime) < dur then
                anyLeft = true
            else
                ab.active = false
                anyExpired = true
            end
        end
    end
    autoBuffActive = anyLeft
    if anyExpired then dirty = true end
end

-----------------------------------------------------------
-- OnUpdate: 10 Hz throttled + lightweight autobuff tick
-----------------------------------------------------------

engineFrame:SetScript("OnUpdate", function(self)
    local now = GetTime()

    if autoBuffActive then
        AutoBuffTick(MSWA_GetDB().spellSettings or {})
    end

    -- Active cooldowns need continuous updates for timer-based
    -- glow conditions, text color conditions, and alpha
    if anyCooldownActive and not dirty then
        dirty = true
    end

    if dirty then
        if forceImmediate or (now - lastFullUpdate) >= THROTTLE_INTERVAL then
            dirty = false
            forceImmediate = false
            lastFullUpdate = now
            MSWA_UpdateSpells()
        end
    end

    if not dirty and not autoBuffActive and not anyCooldownActive then
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
    -- Clear texture caches on all buttons
    if MSWA.icons then
        for i = 1, MSWA.MAX_ICONS do
            local btn = MSWA.icons[i]
            if btn then btn._msaCachedKey = nil end
        end
    end
    lastActiveCount = -1   -- Force Masque reskin + event re-reg
    MSWA_ForceUpdateSpells()
end

-----------------------------------------------------------
-- Event registration (ONLY called when count changes)
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

mainFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        MSWA_UpdatePositionFromDB()
        MSWA_RefreshPlayerIdentity()
        WipeIconCache()
        lastActiveCount = -1
        MSWA_ForceUpdateSpells()
        MSWA_ApplyUIFont()
    elseif event == "UNIT_AURA" then
        if arg1 ~= "player" then return end
        MSWA_RequestUpdateSpells()
    elseif event == "UNIT_INVENTORY_CHANGED" then
        if arg1 ~= "player" then return end
        MSWA_RequestUpdateSpells()
    else
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
        if MSWA_RefreshOptionsList and MSWA.optionsFrame and MSWA.optionsFrame:IsShown() then
            MSWA_RefreshOptionsList()
        end
    end)
end

-----------------------------------------------------------
-- Auto Buff (Spells): cast detection
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
        if not db.trackedSpells or not db.spellSettings then return end

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
                        MSWA._autoBuff[trackedKey] = { active = true, startTime = GetTime() }
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
-----------------------------------------------------------
do
    local itemCDFrame = CreateFrame("Frame")
    itemCDFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
    itemCDFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")

    local lastItemCDStart = {}

    itemCDFrame:SetScript("OnEvent", function()
        if not GetItemCooldown then return end
        local db = MSWA_GetDB()
        if not db.trackedItems or not db.spellSettings then return end

        local triggered = false
        for itemID, enabled in pairs(db.trackedItems) do
            if enabled then
                local key = GetItemKey(itemID)
                local s = db.spellSettings[key] or db.spellSettings[tostring(key)]
                if s and s.auraMode == "AUTOBUFF" then
                    local start, duration = GetItemCooldown(itemID)
                    local prevStart = lastItemCDStart[key] or 0

                    local isFreshCD = false
                    local isActiveCD = false
                    pcall(function()
                        if start and start > 0 and duration and duration > 1.5 then
                            isActiveCD = true
                            if start ~= prevStart then isFreshCD = true end
                        end
                    end)

                    if isFreshCD then
                        local ab = MSWA._autoBuff[key]
                        if not ab or not ab.active then
                            MSWA._autoBuff[key] = { active = true, startTime = GetTime() }
                            triggered = true
                        end
                    end

                    lastItemCDStart[key] = isActiveCD and start or 0
                end
            end
        end

        if triggered then
            autoBuffActive = true
            MSWA_ForceUpdateSpells()
        end
    end)
end
