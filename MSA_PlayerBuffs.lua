local ADDON_NAME, ns = ...

-- Player-buff tracking helpers (Midnight/Beta secret-safe)
-- pcall only where Midnight secret values require it

local PB = ns.PlayerBuffs or {}
ns.PlayerBuffs = PB

local pcall, type = pcall, type

local function ClearCooldown(cd)
    if not cd then return end
    cd.__mswaSet = false
    if cd.Clear then
        cd:Clear()
    elseif CooldownFrame_Clear then
        CooldownFrame_Clear(cd)
    elseif cd.SetCooldown then
        cd:SetCooldown(0, 0)
    end
end

local function ApplyCooldownFromAura(cd, aura)
    if not cd or not aura then return end

    local exp = aura.expirationTime
    local dur = aura.duration
    local mod = aura.timeMod or 1

    -- Secret values: pass straight through to Blizzard API via pcall
    if cd.SetCooldownFromExpirationTime and exp ~= nil and dur ~= nil then
        local ok = pcall(cd.SetCooldownFromExpirationTime, cd, exp, dur, mod)
        if ok then cd.__mswaSet = true; return end
    end

    if cd.SetCooldown and exp ~= nil and dur ~= nil then
        local ok, startTime = pcall(function() return exp - dur end)
        if ok then
            local ok2 = pcall(cd.SetCooldown, cd, startTime, dur, mod)
            if ok2 then cd.__mswaSet = true; return end
        end
    end

    ClearCooldown(cd)
end

-- Reuse SpellAPI functions (already pcall-safe)
local function GetPlayerAura(spellID)
    return MSWA_GetPlayerAuraDataBySpellID(spellID)
end

local function GetStackText(aura, minCount)
    return MSWA_GetAuraStackText(aura, minCount)
end

function PB.UpdateIcon(iconFrame, spellID)
    if not iconFrame or not spellID then return end

    local aura = GetPlayerAura(spellID)

    if aura then
        iconFrame.icon:SetDesaturated(false)
        iconFrame.icon:SetVertexColor(1, 1, 1)

        local stackText = GetStackText(aura, 2)
        local target = iconFrame.stackText or iconFrame.count
        if target then
            if type(stackText) == "string" then
                target:SetText(stackText); target:Show()
            else
                target:SetText(""); target:Hide()
            end
        end
        if iconFrame.stackText and iconFrame.count and iconFrame.stackText ~= iconFrame.count then
            iconFrame.count:SetText(""); iconFrame.count:Hide()
        end

        if iconFrame.cooldown then
            ApplyCooldownFromAura(iconFrame.cooldown, aura)
        end
    else
        iconFrame.icon:SetDesaturated(true)
        iconFrame.icon:SetVertexColor(0.35, 0.35, 0.35)

        if iconFrame.count then iconFrame.count:SetText(""); iconFrame.count:Hide() end
        if iconFrame.stackText then iconFrame.stackText:SetText(""); iconFrame.stackText:Hide() end

        if iconFrame.cooldown then
            ClearCooldown(iconFrame.cooldown)
        end
    end
end
