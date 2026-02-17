local ADDON_NAME, ns = ...

-- Player-buff tracking helpers (Midnight/Beta secret-safe)
--
-- Goals:
-- 1) Do NOT enumerate all auras in combat (some enumeration calls can be protected/tainted).
-- 2) Do NOT compare secret values.
-- 3) Use the spellID-targeted aura APIs when available.

local PB = ns.PlayerBuffs or {}
ns.PlayerBuffs = PB

local function ClearCooldown(cd)
  if not cd then return end
  if cd.Clear then
    cd:Clear()
  elseif CooldownFrame_Clear then
    CooldownFrame_Clear(cd)
  elseif cd.SetCooldown then
    pcall(cd.SetCooldown, cd, 0, 0)
  end
end

local function ApplyCooldownFromAura(cd, aura)
  if not cd or not aura then return end

  local expirationTime = aura.expirationTime
  local duration = aura.duration
  local modRate = aura.timeMod or 1

  if cd.SetCooldownFromExpirationTime and expirationTime ~= nil and duration ~= nil then
    pcall(cd.SetCooldownFromExpirationTime, cd, expirationTime, duration, modRate)
    return
  end

  -- Fallback: some builds may still support SetCooldown(start, duration)
  if cd.SetCooldown and expirationTime ~= nil and duration ~= nil then
    -- best-effort: compute startTime = expirationTime - duration (arithmetic can be secret; protect it)
    local ok, startTime = pcall(function() return expirationTime - duration end)
    if ok then
      pcall(cd.SetCooldown, cd, startTime, duration, modRate)
      return
    end
  end

  ClearCooldown(cd)
end

local function GetPlayerAuraBySpellID(spellID)
  if not C_UnitAuras or not spellID then return nil end

  -- Preferred API (targeted, no enumeration)
  if C_UnitAuras.GetAuraDataBySpellID then
    local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellID, "player", spellID)
    if ok and type(aura) == "table" then
      return aura
    end
  end

  -- Fallback: cooldown-aura lookup (also targeted)
  if C_UnitAuras.GetCooldownAuraBySpellID then
    local ok, aura = pcall(C_UnitAuras.GetCooldownAuraBySpellID, spellID)
    if ok and type(aura) == "table" then
      return aura
    end
  end

  return nil
end

local function GetAuraStackText(aura, minCount)
  if not aura then return nil end

  if C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then
    local ok, s = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, aura, minCount or 2)
    if ok and type(s) == "string" then
      return s
    end
  end

  return nil
end

function PB.UpdateIcon(iconFrame, spellID)
  if not iconFrame or not spellID then return end

  local aura = GetPlayerAuraBySpellID(spellID)

  if aura then
    iconFrame.icon:SetDesaturated(false)
    iconFrame.icon:SetVertexColor(1, 1, 1)

    -- Stacks (display count API returns "" below minCount; we set whatever we get without comparing)
    local stackText = GetAuraStackText(aura, 2)
    if iconFrame.count then
      if type(stackText) == "string" then
        iconFrame.count:SetText(stackText)
        iconFrame.count:Show()
      else
        iconFrame.count:SetText("")
        iconFrame.count:Hide()
      end
    end

    if iconFrame.cooldown then
      ApplyCooldownFromAura(iconFrame.cooldown, aura)
    end
  else
    iconFrame.icon:SetDesaturated(true)
    iconFrame.icon:SetVertexColor(0.35, 0.35, 0.35)

    if iconFrame.count then
      iconFrame.count:SetText("")
      iconFrame.count:Hide()
    end

    if iconFrame.cooldown then
      ClearCooldown(iconFrame.cooldown)
    end
  end
end

