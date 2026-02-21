-- ########################################################
-- MSA_UpdateEngine.lua  (v5 – maximum performance)
--
-- Perf fixes vs v4:
--   • pcall closures eliminated – use pcall(f, a, b) directly
--   • GetTime() cached once per OnUpdate frame
--   • anyCooldownActive tracked inline (no post-loop iteration)
--   • AutoBuffTick throttled to 10 Hz (was 60 Hz)
--   • Sections 5+6 folded into main loop
--   • Text/Stack style dirty-flagged via _msaStyleKey
--   • Glow remaining calc shares cached now-time
--   • db fetched once, passed through everywhere
-- ########################################################

local pairs, type, pcall, tonumber, tostring = pairs, type, pcall, tonumber, tostring
local GetTime         = GetTime
local GetItemCooldown = GetItemCooldown
local GetItemIcon     = GetItemIcon
local wipe            = wipe or table.wipe

-----------------------------------------------------------
-- Constants
-----------------------------------------------------------

local THROTTLE_INTERVAL = 0.100   -- 10 Hz

-----------------------------------------------------------
-- Haste-scaled Auto Buff duration helper
-----------------------------------------------------------

local UnitSpellHaste = UnitSpellHaste

local function GetEffectiveBuffDuration(s)
    local dur = tonumber(s and s.autoBuffDuration) or 10
    if dur < 0.1 then dur = 0.1 end
    if s and s.hasteScaling and UnitSpellHaste then
        local h = tonumber(UnitSpellHaste("player")) or 0
        if h > 0 then
            dur = dur / (1 + h / 100)
        end
    end
    return dur
end

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

local function PositionButton(btn, s, key, idx, frame, ICON_SIZE, ICON_SPACE, db, groupCtx)
    local gid = MSWA_GetAuraGroup and MSWA_GetAuraGroup(key) or (_G.GetAuraGroup and _G.GetAuraGroup(key) or nil)
    local group = gid and db.groups and db.groups[gid] or nil

    if group then
        local gf = nil

        if groupCtx then
            groupCtx.used[gid] = true
            if not groupCtx.applied[gid] and type(MSWA_ApplyGroupAnchorFrame) == "function" then
                gf = MSWA_ApplyGroupAnchorFrame(gid, group)
                groupCtx.frames[gid] = gf
                groupCtx.applied[gid] = true
            else
                gf = groupCtx.frames[gid]
                if not gf and type(MSWA_GetOrCreateGroupAnchorFrame) == "function" then
                    gf = MSWA_GetOrCreateGroupAnchorFrame(gid)
                    groupCtx.frames[gid] = gf
                end
            end
        elseif type(MSWA_ApplyGroupAnchorFrame) == "function" then
            gf = MSWA_ApplyGroupAnchorFrame(gid, group)
        end

        if not gf then gf = frame end

        btn:SetPoint("CENTER", gf, "CENTER", (s and s.x or 0), (s and s.y or 0))

        local size = group.size or ICON_SIZE
        local w = (s and s.width) or size
        local h = (s and s.height) or size
        btn:SetSize(w, h)

        if groupCtx then
            local b = groupCtx.bounds[gid]
            if not b then
                b = { init = false, minL = 0, maxR = 0, minB = 0, maxT = 0 }
                groupCtx.bounds[gid] = b
            end
            local x = (s and s.x) or 0
            local y = (s and s.y) or 0
            local halfW = w * 0.5
            local halfH = h * 0.5
            local left  = x - halfW
            local right = x + halfW
            local bot   = y - halfH
            local top   = y + halfH
            if not b.init then
                b.init = true
                b.minL = left; b.maxR = right
                b.minB = bot;  b.maxT = top
            else
                if left  < b.minL then b.minL = left end
                if right > b.maxR then b.maxR = right end
                if bot   < b.minB then b.minB = bot end
                if top   > b.maxT then b.maxT = top end
            end
        end
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
    btn._msaStyleKey  = nil
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
-- Text/Stack style with dirty-flag (skip when key matches)
-- v5: Avoids redundant SetFont/SetTextColor/ClearAllPoints
-- per icon per frame when settings haven't changed.
-----------------------------------------------------------

local function ApplyStylesIfDirty(btn, db, s, key)
    if btn._msaStyleKey == key then return end
    btn._msaStyleKey = key
    MSWA_ApplyTextStyle(btn, db, s)
    MSWA_ApplyStackStyle_Fast(btn, s, db)
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
-- pcall helpers for secret-value comparison (no closure!)
-- v5: Named functions instead of pcall(function() ... end)
-----------------------------------------------------------

local function _itemCDCheck(start, duration)
    if start and start > 0 and duration and duration > 1.5 then
        return true
    end
    return false
end

local function _itemCDRemaining(start, duration, now)
    if start and start > 0 and duration and duration > 1.5 then
        local r = (start + duration) - now
        return r > 0 and r or 0
    end
    return 0
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

    -- v5: cache GetTime once for entire update
    local now = GetTime()

    -- Group anchors – reuse tables to avoid churn
    local groupCtx = MSWA._groupLayoutCtx
    if not groupCtx then
        groupCtx = { applied = {}, frames = {}, bounds = {}, used = {} }
        MSWA._groupLayoutCtx = groupCtx
    end
    wipe(groupCtx.applied)
    wipe(groupCtx.bounds)
    wipe(groupCtx.used)

    local optFrame      = MSWA.optionsFrame
    local selectedKey   = (optFrame and optFrame:IsShown() and MSWA.selectedSpellID) or nil

    -- Cache API availability once
    local hasGetCD          = C_Spell and C_Spell.GetSpellCooldown
    local hasGetCDRemaining = C_Spell and C_Spell.GetSpellCooldownRemaining

    -- Cache combat/encounter state ONCE
    local inCombat    = InCombatLockdown and InCombatLockdown() and true or false
    local inEncounter = IsEncounterInProgress and IsEncounterInProgress() and true or false

    -- v5: track inline (eliminates post-loop iterations from sections 5+6)
    local foundCooldownActive = false
    local foundAutoBuffActive = false

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

                        ApplyStylesIfDirty(btn, db, s, key)

                        if s and s.auraMode == "AUTOBUFF" then
                            -- ========== SPELL AUTO BUFF MODE ==========
                            local ab = autoBuff[key]
                            local buffDur = GetEffectiveBuffDuration(s)
                            local buffDelay = tonumber(s.autoBuffDelay) or 0
                            local timerStart = ab and (ab.startTime + buffDelay) or 0

                            local showBuff = false
                            if ab and ab.active then
                                local totalWindow = buffDelay + buffDur
                                if (now - ab.startTime) < totalWindow then
                                    showBuff = true
                                    foundAutoBuffActive = true
                                else
                                    ab.active = false
                                end
                            end

                            if showBuff then
                                PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db, groupCtx)
                                MSWA_ApplyCooldownFrame(btn.cooldown, timerStart, buffDur, 1)
                                btn.icon:SetDesaturated(false)
                                btn:SetAlpha(ComputeAlpha(s, true, inCombat))
                                ClearStackAndCount(btn)
                                MSWA_UpdateBuffVisual_Fast(btn, s, spellID, false, nil)

                                local glowRem = buffDur - (now - timerStart)
                                if glowRem < 0 then glowRem = 0 end
                                local gs = s and s.glow
                                if gs and gs.enabled then
                                    MSWA_UpdateGlow_Fast(btn, gs, glowRem, glowRem > 0)
                                elseif btn._msaGlowActive then
                                    MSWA_StopGlow(btn)
                                end
                                MSWA_ApplyConditionalTextColor_Fast(btn, s, db, glowRem, glowRem > 0)
                                MSWA_ApplySwipeDarken_Fast(btn, s)
                                foundCooldownActive = true
                                index = index + 1

                            elseif previewMode or key == selectedKey then
                                PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db, groupCtx)
                                MSWA_ClearCooldownFrame(btn.cooldown)
                                btn.icon:SetDesaturated(false)
                                btn:SetAlpha(ComputeAlpha(s, false, inCombat))
                                ClearStackAndCount(btn)
                                MSWA_UpdateBuffVisual_Fast(btn, s, spellID, false, nil)
                                MSWA_StopGlow(btn)
                                index = index + 1
                            else
                                HideButton(btn)
                            end

                        else
                            -- ========== NORMAL SPELL MODE ==========
                            PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db, groupCtx)

                            local cdInfo = C_Spell.GetSpellCooldown(spellID)
                            if cdInfo then
                                local exp = cdInfo.expirationTime
                                if hasGetCDRemaining then
                                    local rem = C_Spell.GetSpellCooldownRemaining(spellID)
                                    if type(rem) == "number" then
                                        exp = now + rem
                                    end
                                end
                                MSWA_ApplyCooldownFrame(btn.cooldown, cdInfo.startTime, cdInfo.duration, cdInfo.modRate, exp)
                            else
                                MSWA_ClearCooldownFrame(btn.cooldown)
                            end

                            MSWA_UpdateBuffVisual_Fast(btn, s, spellID, false, nil)

                            local onCD = MSWA_IsCooldownActive(btn)
                            if onCD then foundCooldownActive = true end

                            if s and s.grayOnCooldown then
                                btn.icon:SetDesaturated(onCD)
                            else
                                btn.icon:SetDesaturated(false)
                            end

                            local rem = 0
                            if onCD and s then
                                local gs2 = s.glow
                                if (gs2 and gs2.enabled) or s.textColor2Enabled then
                                    local r = select(1, MSWA_GetSpellGlowRemaining(spellID))
                                    if type(r) == "number" and r > 0 then
                                        rem = r
                                    end
                                end
                            end

                            btn:SetAlpha(ComputeAlpha(s, onCD, inCombat))

                            local gs = s and s.glow
                            if gs and gs.enabled then
                                MSWA_UpdateGlow_Fast(btn, gs, rem, onCD)
                            elseif btn._msaGlowActive then
                                MSWA_StopGlow(btn)
                            end
                            MSWA_ApplyConditionalTextColor_Fast(btn, s, db, rem, onCD)
                            MSWA_ApplySwipeDarken_Fast(btn, s)

                            index = index + 1
                        end
                    end

                elseif (previewMode or trackedKey == selectedKey) and MSWA_IsDraftKey(trackedKey) then
                    local btn = icons[index]
                    local s   = settingsTable[trackedKey] or settingsTable[tostring(trackedKey)]
                    SetIconTexture(btn, trackedKey)
                    btn:Show()
                    btn.spellID = trackedKey
                    btn:ClearAllPoints()
                    PositionButton(btn, s, trackedKey, index, frame, ICON_SIZE, ICON_SPACE, db, groupCtx)
                    MSWA_ClearCooldownFrame(btn.cooldown)
                    ApplyStylesIfDirty(btn, db, s, trackedKey)
                    btn.icon:SetDesaturated(false)
                    btn:SetAlpha(0.6)
                    ClearStackAndCount(btn)
                    MSWA_StopGlow(btn)
                    index = index + 1
                end
            end
        end
    end

    -----------------------------------------------------------
    -- 2) Items
    -----------------------------------------------------------
    for itemID, enabled in pairs(trackedItems) do
        if index > MAX_ICONS then break end
        if enabled then
            local key = GetItemKey(itemID)
            local s   = settingsTable[key] or settingsTable[tostring(key)]
            local shouldLoad = MSWA_ShouldLoadAura(s, inCombat, inEncounter)

            if shouldLoad or previewMode or key == selectedKey then
                local btn = icons[index]
                SetIconTexture(btn, key)
                btn:Show()
                btn.spellID = key
                btn:ClearAllPoints()

                ApplyStylesIfDirty(btn, db, s, key)

                if s and s.auraMode == "AUTOBUFF" then
                    -- ========== ITEM AUTO BUFF MODE ==========
                    local ab = autoBuff[key]
                    local buffDur = GetEffectiveBuffDuration(s)
                    local buffDelay = tonumber(s.autoBuffDelay) or 0
                    local timerStart = ab and (ab.startTime + buffDelay) or 0

                    local showBuff = false
                    if ab and ab.active then
                        local totalWindow = buffDelay + buffDur
                        if (now - ab.startTime) < totalWindow then
                            showBuff = true
                            foundAutoBuffActive = true
                        else
                            ab.active = false
                        end
                    end

                    if showBuff then
                        PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db, groupCtx)
                        MSWA_ApplyCooldownFrame(btn.cooldown, timerStart, buffDur, 1)
                        btn.icon:SetDesaturated(false)
                        btn:SetAlpha(ComputeAlpha(s, true, inCombat))
                        ClearStackAndCount(btn)
                        MSWA_UpdateBuffVisual_Fast(btn, s, nil, true, itemID)

                        local glowRem = buffDur - (now - timerStart)
                        if glowRem < 0 then glowRem = 0 end
                        local gs = s and s.glow
                        if gs and gs.enabled then
                            MSWA_UpdateGlow_Fast(btn, gs, glowRem, glowRem > 0)
                        elseif btn._msaGlowActive then
                            MSWA_StopGlow(btn)
                        end
                        MSWA_ApplyConditionalTextColor_Fast(btn, s, db, glowRem, glowRem > 0)
                        MSWA_ApplySwipeDarken_Fast(btn, s)
                        foundCooldownActive = true
                        index = index + 1

                    elseif previewMode or key == selectedKey then
                        PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db, groupCtx)
                        MSWA_ClearCooldownFrame(btn.cooldown)
                        btn.icon:SetDesaturated(false)
                        btn:SetAlpha(ComputeAlpha(s, false, inCombat))
                        ClearStackAndCount(btn)
                        MSWA_UpdateBuffVisual_Fast(btn, s, nil, true, itemID)
                        MSWA_StopGlow(btn)
                        index = index + 1
                    else
                        HideButton(btn)
                    end

                else
                    -- ========== NORMAL ITEM COOLDOWN MODE ==========
                    PositionButton(btn, s, key, index, frame, ICON_SIZE, ICON_SPACE, db, groupCtx)

                    if GetItemCooldown then
                        local iStart, iDuration = GetItemCooldown(itemID)
                        -- v5: no closure – pcall on named function
                        local ok, onCD = pcall(_itemCDCheck, iStart, iDuration)
                        if ok and onCD then
                            MSWA_ApplyCooldownFrame(btn.cooldown, iStart, iDuration, 1)
                        else
                            MSWA_ClearCooldownFrame(btn.cooldown)
                        end
                    else
                        MSWA_ClearCooldownFrame(btn.cooldown)
                    end

                    MSWA_UpdateBuffVisual_Fast(btn, s, nil, true, itemID)

                    local onCD = MSWA_IsCooldownActive(btn)
                    if onCD then foundCooldownActive = true end

                    if s and s.grayOnCooldown then
                        btn.icon:SetDesaturated(onCD)
                    else
                        btn.icon:SetDesaturated(false)
                    end

                    btn:SetAlpha(ComputeAlpha(s, onCD, inCombat))

                    local rem = 0
                    if onCD and s then
                        local need = (s.glow and s.glow.enabled) or s.textColor2Enabled
                        if need and GetItemCooldown then
                            -- v5: no closure – pcall on named function
                            local st, dur = GetItemCooldown(itemID)
                            local ok2, r = pcall(_itemCDRemaining, st, dur, now)
                            if ok2 and type(r) == "number" then
                                rem = r
                            end
                        end
                    end

                    local gs = s and s.glow
                    if gs and gs.enabled then
                        MSWA_UpdateGlow_Fast(btn, gs, rem, onCD)
                    elseif btn._msaGlowActive then
                        MSWA_StopGlow(btn)
                    end
                    MSWA_ApplyConditionalTextColor_Fast(btn, s, db, rem, onCD)
                    MSWA_ApplySwipeDarken_Fast(btn, s)

                    index = index + 1
                end
            end
        end
    end

    -----------------------------------------------------------
    -- 2.5) Finalize group anchor footprints
    -----------------------------------------------------------
    if groupCtx and next(groupCtx.used) ~= nil then
        for gid, b in pairs(groupCtx.bounds) do
            if b and b.init then
                local gf = groupCtx.frames[gid]
                if gf then
                    local w = b.maxR - b.minL
                    local h = b.maxT - b.minB
                    if w < 1 then w = 1 end
                    if h < 1 then h = 1 end
                    gf:SetSize(w, h)
                end
            end
        end
    end

    if type(MSWA_HideUnusedGroupAnchorFrames) == "function" then
        MSWA_HideUnusedGroupAnchorFrames(groupCtx and groupCtx.used)
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
            btn._msaStyleKey  = nil
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
    -- 5+6) v5: already tracked inline – just assign
    -----------------------------------------------------------
    autoBuffActive    = foundAutoBuffActive
    anyCooldownActive = foundCooldownActive
end

-- Export globally
MSWA.UpdateSpells    = MSWA_UpdateSpells
_G.MSWA_UpdateSpells = MSWA_UpdateSpells

-----------------------------------------------------------
-- Lightweight autobuff tick (only checks for expiry)
-- v5: throttled to 10 Hz alongside main update
-----------------------------------------------------------

local function AutoBuffTick(settingsTable, now)
    local anyLeft = false
    local anyExpired = false
    for key, ab in pairs(MSWA._autoBuff) do
        if ab and ab.active then
            local s2 = settingsTable[key] or settingsTable[tostring(key)]
            local dur = GetEffectiveBuffDuration(s2)
            local delay = tonumber(s2 and s2.autoBuffDelay) or 0
            if (now - ab.startTime) < (delay + dur) then
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
-- OnUpdate: 10 Hz throttled
-- v5: AutoBuffTick now throttled to 10 Hz (was 60 Hz)
-----------------------------------------------------------

engineFrame:SetScript("OnUpdate", function(self)
    local now = GetTime()

    -- Active cooldowns need continuous updates for timer-based
    -- glow conditions, text color conditions, and alpha
    if anyCooldownActive and not dirty then
        dirty = true
    end

    if dirty or autoBuffActive then
        if forceImmediate or (now - lastFullUpdate) >= THROTTLE_INTERVAL then
            -- v5: AutoBuffTick runs at same 10 Hz rate, not every frame
            if autoBuffActive then
                AutoBuffTick(MSWA_GetDB().spellSettings or {}, now)
            end
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
    -- Clear texture + style caches on all buttons
    if MSWA.icons then
        for i = 1, MSWA.MAX_ICONS do
            local btn = MSWA.icons[i]
            if btn then
                btn._msaCachedKey = nil
                btn._msaStyleKey  = nil
            end
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

                    -- v5: no closure – pcall on named function
                    local ok, isActiveCD = pcall(_itemCDCheck, start, duration)
                    local isFreshCD = ok and isActiveCD and (start ~= prevStart)

                    if isFreshCD then
                        local ab = MSWA._autoBuff[key]
                        if not ab or not ab.active then
                            MSWA._autoBuff[key] = { active = true, startTime = GetTime() }
                            triggered = true
                        end
                    end

                    lastItemCDStart[key] = (ok and isActiveCD) and start or 0
                end
            end
        end

        if triggered then
            autoBuffActive = true
            MSWA_ForceUpdateSpells()
        end
    end)
end
