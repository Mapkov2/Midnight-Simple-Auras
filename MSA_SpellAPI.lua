-- ########################################################
-- MSA_SpellAPI.lua
-- Spell, Aura, Cooldown API wrappers (Midnight/Beta safe)
-- ########################################################

local pcall, type, tostring, tonumber = pcall, type, tostring, tonumber
local GetItemCooldown = GetItemCooldown
local GetItemCount    = GetItemCount
local GetTime         = GetTime

-----------------------------------------------------------
-- Spell helpers (12.0 API - C_Spell)
-----------------------------------------------------------

function MSWA_GetSpellInfo(spellID)
    if not spellID or not C_Spell or not C_Spell.GetSpellInfo then
        return nil
    end
    return C_Spell.GetSpellInfo(spellID)
end

function MSWA_GetSpellName(spellID)
    local info = MSWA_GetSpellInfo(spellID)
    return info and info.name or nil
end

function MSWA_GetSpellIcon(spellID)
    local info = MSWA_GetSpellInfo(spellID)
    return info and info.iconID or nil
end

function MSWA_GetSpellCooldown(spellID)
    if not spellID or not C_Spell or not C_Spell.GetSpellCooldown then
        return nil
    end
    return C_Spell.GetSpellCooldown(spellID)
end

-----------------------------------------------------------
-- Aura/Charges helpers (Midnight/Beta safe)
-----------------------------------------------------------

function MSWA_GetPlayerAuraDataBySpellID(spellID)
    if not spellID or not C_UnitAuras then return nil end

    if C_UnitAuras.GetAuraDataBySpellID then
        local ok, data = pcall(C_UnitAuras.GetAuraDataBySpellID, "player", spellID)
        if ok and type(data) == "table" then return data end
    end

    if C_UnitAuras.GetCooldownAuraBySpellID then
        local ok, data = pcall(C_UnitAuras.GetCooldownAuraBySpellID, spellID)
        if ok and type(data) == "table" then return data end
    end

    return nil
end

function MSWA_GetAuraStackText(auraData, minCount)
    if not auraData then return nil end

    if C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then
        local ok, s = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, auraData, minCount or 2)
        if ok and type(s) == "string" then return s end
    end

    return nil
end

function MSWA_GetSpellChargesText(spellID)
    if not spellID or not C_Spell or not C_Spell.GetSpellCharges then return nil end

    local ok, info = pcall(C_Spell.GetSpellCharges, spellID)
    if not ok or type(info) ~= "table" then return nil end

    local cur = info.currentCharges
    if type(cur) == "nil" then cur = info.charges end

    if C_StringUtil and C_StringUtil.TruncateWhenZero then
        local okS, s = pcall(C_StringUtil.TruncateWhenZero, cur)
        if okS and type(s) == "string" then return s end
    end

    local okT, s = pcall(tostring, cur)
    if okT and type(s) == "string" then return s end

    return nil
end

-----------------------------------------------------------
-- Cooldown frame helpers
-----------------------------------------------------------

function MSWA_ClearCooldownFrame(cd)
    if not cd then return end
    cd.__mswaSet = false
    if cd.Clear then
        cd:Clear()
    elseif CooldownFrame_Clear then
        CooldownFrame_Clear(cd)
    elseif cd.SetCooldown then
        pcall(cd.SetCooldown, cd, 0, 0)
    end
end

function MSWA_ClearCooldown(btn)
    if not btn or not btn.cooldown then return end
    MSWA_ClearCooldownFrame(btn.cooldown)
end

function MSWA_TryComputeExpirationTime(startTime, duration)
    if startTime == nil or duration == nil then return nil end
    local ok, exp = pcall(function() return startTime + duration end)
    if ok then return exp end
    return nil
end

function MSWA_TryComputeExpirationFromRemaining(remaining)
    local okNow, now = pcall(GetTime)
    if not okNow then return nil end
    local okExp, exp = pcall(function() return now + remaining end)
    if okExp then return exp end
    return nil
end

-- Secret-safe: compute glow remaining from cdInfo without comparing secret values
function MSWA_TryComputeGlowRemaining(cdInfo)
    if not cdInfo then return 0, false end
    -- Try via startTime + duration - GetTime()
    local ok, gr = pcall(function()
        return (cdInfo.startTime + cdInfo.duration) - GetTime()
    end)
    if ok and type(gr) == "number" then
        if gr > 0 then return gr, true end
        return 0, false
    end
    return 0, false
end

-- Secret-safe: compute glow remaining from item cooldown values
function MSWA_TryComputeItemGlowRemaining(start, duration)
    if not start or not duration then return 0, false end
    local ok, gr = pcall(function()
        if start <= 0 or duration <= 1.5 then return nil end
        return (start + duration) - GetTime()
    end)
    if ok and type(gr) == "number" then
        if gr > 0 then return gr, true end
        return 0, false
    end
    return 0, false
end

function MSWA_ApplyCooldownFrame(cd, startTime, duration, modRate, expirationTime, durationObj)
    if not cd then return end

    if durationObj and cd.SetCooldownFromDurationObject then
        local ok = pcall(cd.SetCooldownFromDurationObject, cd, durationObj, true)
        if ok then cd.__mswaSet = true; return end
    end

    if expirationTime ~= nil and duration ~= nil and cd.SetCooldownFromExpirationTime then
        local ok = pcall(cd.SetCooldownFromExpirationTime, cd, expirationTime, duration, modRate)
        if ok then cd.__mswaSet = true; return end
    end

    if startTime ~= nil and duration ~= nil and cd.SetCooldown then
        local ok = pcall(cd.SetCooldown, cd, startTime, duration, modRate)
        if ok then cd.__mswaSet = true; return end
    end

    MSWA_ClearCooldownFrame(cd)
end

-----------------------------------------------------------
-- Grayscale on cooldown
-----------------------------------------------------------

function MSWA_IsCooldownFrameActive(cd)
    if not cd then return false end
    if cd.__mswaSet and cd.IsShown and cd:IsShown() then return true end

    local function NonZeroDuration(v)
        if v == nil then return false end
        local okNum, isPos = pcall(function() return type(v) == "number" and v > 0 end)
        if okNum then return isPos end
        local okStr, s = pcall(tostring, v)
        if okStr and type(s) == "string" then
            local okCmp, nonZero = pcall(function()
                return s ~= "0" and s ~= "0.0" and s ~= "0.00" and s ~= "0.000" and s ~= "0.0000" and s ~= "0.00000" and s ~= "0.000000"
            end)
            if okCmp then return nonZero end
        end
        return false
    end

    if cd.GetCooldownTimes then
        local ok, _, dur = pcall(cd.GetCooldownTimes, cd)
        if ok and NonZeroDuration(dur) then return true end
    end
    if cd.GetCooldownDuration then
        local ok, dur = pcall(cd.GetCooldownDuration, cd)
        if ok and NonZeroDuration(dur) then return true end
    end
    if cd.GetDuration then
        local ok, dur = pcall(cd.GetDuration, cd)
        if ok and NonZeroDuration(dur) then return true end
    end

    return false
end

function MSWA_ShouldGrayOnCooldown(key)
    if not key then return false end
    local db = MSWA_GetDB()
    local s = select(1, MSWA_GetSpellSettings(db, key))
    return (s and s.grayOnCooldown) and true or false
end

function MSWA_ApplyGrayscaleOnCooldownToButton(btn, key)
    if not btn or not btn.icon then return end
    if not MSWA_ShouldGrayOnCooldown(key) then
        btn.icon:SetDesaturated(false)
        return
    end
    if MSWA_IsCooldownFrameActive(btn.cooldown) then
        btn.icon:SetDesaturated(true)
    else
        btn.icon:SetDesaturated(false)
    end
end

-----------------------------------------------------------
-- Buff / visual helper
-----------------------------------------------------------

function MSWA_UpdateItemCount(btn, itemID)
    -- Items: show inventory count (bags only, no bank)
    if not btn or not itemID then return end
    local target = btn.stackText or btn.count
    if not target then return end
    if not GetItemCount then
        target:SetText(""); target:Hide()
        return
    end
    local ok, count = pcall(GetItemCount, itemID, false, false)
    if ok and type(count) == "number" then
        target:SetText(tostring(count))
        target:Show()
    else
        target:SetText(""); target:Hide()
    end
end

function MSWA_UpdateBuffVisual(btn, key)
    if not btn then return end

    -- Use stackText if available, fallback to btn.count
    local target = btn.stackText or btn.count
    if not target then return end

    -- Also keep btn.count hidden when using stackText
    if btn.stackText and btn.count and btn.stackText ~= btn.count then
        btn.count:SetText("")
        btn.count:Hide()
    end

    local showMode = MSWA_GetStackShowMode and MSWA_GetStackShowMode(key) or "auto"

    -- Force hide: always hide stacks
    if showMode == "hide" then
        target:SetText("")
        target:Hide()
        return
    end

    -- Items: show inventory count
    if MSWA_IsItemKey(key) then
        local itemID = MSWA_KeyToItemID(key)
        if itemID then
            MSWA_UpdateItemCount(btn, itemID)
        else
            target:SetText("")
            target:Hide()
        end
        return
    end

    -- Spells: aura stacks or charges
    local spellID = MSWA_KeyToSpellID(key)
    if spellID then
        local auraData = MSWA_GetPlayerAuraDataBySpellID(spellID)
        local minCount = (showMode == "show") and 0 or 1
        local stackText = MSWA_GetAuraStackText(auraData, minCount)
        if not stackText then stackText = MSWA_GetSpellChargesText(spellID) end
        if stackText then
            target:SetText(stackText)
            target:Show()
        else
            target:SetText("")
            target:Hide()
        end
        return
    end

    target:SetText("")
    target:Hide()
end

-----------------------------------------------------------
-- Conditional text color (2nd color based on timer)
-----------------------------------------------------------

local function FindCooldownText(cd)
    if not cd then return nil end
    -- Try common methods to get the cooldown frame's countdown FontString
    if cd.GetRegions then
        local regions = { cd:GetRegions() }
        for _, region in ipairs(regions) do
            if region and region.IsObjectType and region:IsObjectType("FontString") then
                return region
            end
        end
    end
    -- Check named children
    if cd.GetChildren then
        local children = { cd:GetChildren() }
        for _, child in ipairs(children) do
            if child and child.GetRegions then
                local regions = { child:GetRegions() }
                for _, region in ipairs(regions) do
                    if region and region.IsObjectType and region:IsObjectType("FontString") then
                        return region
                    end
                end
            end
        end
    end
    return nil
end

function MSWA_ApplyConditionalTextColor(btn, key, remaining, isOnCooldown)
    if not btn then return end

    local db = MSWA_GetDB()
    local s = (key ~= nil) and select(1, MSWA_GetSpellSettings(db, key)) or nil

    -- Get base text color (same logic as MSWA_GetTextStyleForKey)
    local baseTC = (s and s.textColor) or db.textColor or { r = 1, g = 1, b = 1 }
    local br = tonumber(baseTC.r) or 1
    local bg = tonumber(baseTC.g) or 1
    local bb = tonumber(baseTC.b) or 1

    -- Determine final color: base or conditional 2nd color
    local fr, fg, fb = br, bg, bb
    local condActive = false

    if s and s.textColor2Enabled and s.textColor2 then
        local cond = s.textColor2Cond or "TIMER_BELOW"
        local val  = tonumber(s.textColor2Value) or 5
        remaining  = remaining or 0
        isOnCooldown = isOnCooldown or false

        if cond == "TIMER_BELOW" then
            condActive = isOnCooldown and remaining <= val and remaining > 0
        elseif cond == "TIMER_ABOVE" then
            condActive = isOnCooldown and remaining >= val
        end

        if condActive then
            fr = tonumber(s.textColor2.r) or 1
            fg = tonumber(s.textColor2.g) or 0
            fb = tonumber(s.textColor2.b) or 0
        end
    end

    -- Apply to btn.count (legacy Masque compat)
    if btn.count and btn.count.SetTextColor then
        btn.count:SetTextColor(fr, fg, fb, 1)
    end

    -- Note: btn.stackText uses its own color via MSWA_ApplyStackStyleToButton

    -- Apply to Blizzard cooldown countdown text
    if btn.cooldown then
        local cdText = btn._mswaCDText
        if cdText == nil then
            cdText = FindCooldownText(btn.cooldown)
            -- Cache result: false means "not found", avoids repeated region scans
            btn._mswaCDText = cdText or false
        elseif cdText == false then
            cdText = nil
        end
        if cdText and cdText.SetTextColor then
            cdText:SetTextColor(fr, fg, fb, 1)
        end
    end
end

-----------------------------------------------------------
-- Swipe darkens on loss (per-aura cooldown swipe toggle)
-----------------------------------------------------------

function MSWA_ApplySwipeDarken(btn, key)
    if not btn or not btn.cooldown then return end
    local cd = btn.cooldown

    local db = MSWA_GetDB()
    local s = (key ~= nil) and select(1, MSWA_GetSpellSettings(db, key)) or nil
    local darken = s and s.swipeDarken

    if darken then
        -- Dark swipe visible (standard WoW look)
        if cd.SetSwipeColor then cd:SetSwipeColor(0, 0, 0, 0.8) end
        if cd.SetDrawSwipe then cd:SetDrawSwipe(true) end
    else
        -- No dark overlay â€“ swipe is transparent
        if cd.SetSwipeColor then cd:SetSwipeColor(0, 0, 0, 0) end
    end
end
