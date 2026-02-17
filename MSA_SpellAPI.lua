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
    local okExp, exp = pcall(SafeAdd, now, remaining)
    if okExp then return exp end
    return nil
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
    -- Items/trinkets: never show stack count
    if not btn or not btn.count then return end
    btn.count:SetText("")
    btn.count:Hide()
end

function MSWA_UpdateBuffVisual(btn, key)
    if not btn or not btn.count then return end

    if MSWA_IsItemKey(key) then
        -- Items: no stack count, keep clean
        btn.count:SetText("")
        btn.count:Hide()
        return
    end

    local spellID = MSWA_KeyToSpellID(key)
    if spellID then
        local auraData = MSWA_GetPlayerAuraDataBySpellID(spellID)
        local stackText = MSWA_GetAuraStackText(auraData, 1)
        if not stackText then stackText = MSWA_GetSpellChargesText(spellID) end
        if stackText then
            btn.count:SetText(stackText)
            btn.count:Show()
        else
            btn.count:SetText("")
            btn.count:Hide()
        end
        return
    end

    btn.count:SetText("")
    btn.count:Hide()
end
