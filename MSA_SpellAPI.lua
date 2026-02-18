-- ########################################################
-- MSA_SpellAPI.lua  (v3 Ã¢â‚¬â€œ max performance rewrite)
--
-- Rules:
--   Ã¢â‚¬Â¢ pcall ONLY for Midnight secret-value APIs
--   Ã¢â‚¬Â¢ Font paths cached Ã¢â‚¬â€œ zero pcall in hot path
--   Ã¢â‚¬Â¢ CD API detected once at load time
--   Ã¢â‚¬Â¢ All hot-path helpers accept (db, s) Ã¢â‚¬â€œ no redundant lookups
-- ########################################################

local type, tostring, tonumber, select = type, tostring, tonumber, select
local pcall     = pcall
local GetTime   = GetTime
local GetItemCooldown = GetItemCooldown
local GetItemCount    = GetItemCount

-----------------------------------------------------------
-- Spell info (non-secret, no pcall needed)
-----------------------------------------------------------

function MSWA_GetSpellInfo(spellID)
    if not spellID then return nil end
    if C_Spell and C_Spell.GetSpellInfo then
        return C_Spell.GetSpellInfo(spellID)
    end
    return nil
end

function MSWA_GetSpellName(spellID)
    local info = MSWA_GetSpellInfo(spellID)
    return info and info.name
end

function MSWA_GetSpellIcon(spellID)
    local info = MSWA_GetSpellInfo(spellID)
    return info and info.iconID
end

function MSWA_GetSpellCooldown(spellID)
    if not spellID then return nil end
    if C_Spell and C_Spell.GetSpellCooldown then
        return C_Spell.GetSpellCooldown(spellID)
    end
    return nil
end

-----------------------------------------------------------
-- Font path cache (zero pcall in hot path)
-----------------------------------------------------------

local fontPathCache = {}
local defaultFontPath

local function GetDefaultFontPath()
    if not defaultFontPath then
        if GameFontNormal and GameFontNormal.GetFont then
            defaultFontPath = select(1, GameFontNormal:GetFont())
        end
        defaultFontPath = defaultFontPath or "Fonts\\FRIZQT__.TTF"
    end
    return defaultFontPath
end

function MSWA_GetFontPathFromKey(fontKey)
    if not fontKey or fontKey == "DEFAULT" then
        return GetDefaultFontPath()
    end

    local cached = fontPathCache[fontKey]
    if cached then return cached end

    -- One-time lookup via SharedMedia (pcall only here, cached forever)
    local LSM = MSWA.LSM
    if LSM and LSM.Fetch then
        local ok, path = pcall(LSM.Fetch, LSM, "font", fontKey)
        if ok and path then
            fontPathCache[fontKey] = path
            return path
        end
    end

    local def = GetDefaultFontPath()
    fontPathCache[fontKey] = def
    return def
end

function MSWA_InvalidateFontCache()
    for k in pairs(fontPathCache) do fontPathCache[k] = nil end
    defaultFontPath = nil
end

-----------------------------------------------------------
-- Cooldown frame: detect API once, single pcall apply
-----------------------------------------------------------

local cdAPIDetected = false
local cdHasExpTime  = false
local cdHasSetCD    = false

local function DetectCDAPI()
    if cdAPIDetected then return end
    cdAPIDetected = true
    local testCD = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
    cdHasExpTime = testCD.SetCooldownFromExpirationTime ~= nil
    cdHasSetCD   = testCD.SetCooldown ~= nil
    testCD:Hide()
end

function MSWA_ClearCooldownFrame(cd)
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

function MSWA_ClearCooldown(btn)
    if btn and btn.cooldown then
        MSWA_ClearCooldownFrame(btn.cooldown)
    end
end

-- Single pcall per icon. Secret values pass straight through to Blizzard.
function MSWA_ApplyCooldownFrame(cd, startTime, duration, modRate, expirationTime)
    if not cd then return end
    DetectCDAPI()

    if cdHasExpTime and expirationTime ~= nil and duration ~= nil then
        local ok = pcall(cd.SetCooldownFromExpirationTime, cd, expirationTime, duration, modRate)
        if ok then cd.__mswaSet = true; return end
    end

    if cdHasSetCD and startTime ~= nil and duration ~= nil then
        local ok = pcall(cd.SetCooldown, cd, startTime, duration, modRate)
        if ok then cd.__mswaSet = true; return end
    end

    MSWA_ClearCooldownFrame(cd)
end

-----------------------------------------------------------
-- Aura / Charges (Midnight needs pcall for secret aura data)
-----------------------------------------------------------

local hasGetAuraData   = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellID
local hasGetCDAura     = C_UnitAuras and C_UnitAuras.GetCooldownAuraBySpellID
local hasGetAuraCount  = C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount
local hasGetCharges    = C_Spell and C_Spell.GetSpellCharges
local hasTruncZero     = C_StringUtil and C_StringUtil.TruncateWhenZero

function MSWA_GetPlayerAuraDataBySpellID(spellID)
    if not spellID then return nil end
    if hasGetAuraData then
        local ok, data = pcall(C_UnitAuras.GetAuraDataBySpellID, "player", spellID)
        if ok and type(data) == "table" then return data end
    end
    if hasGetCDAura then
        local ok, data = pcall(C_UnitAuras.GetCooldownAuraBySpellID, spellID)
        if ok and type(data) == "table" then return data end
    end
    return nil
end

function MSWA_GetAuraStackText(auraData, minCount)
    if not auraData or not hasGetAuraCount then return nil end
    local ok, s = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, auraData, minCount or 2)
    if ok and type(s) == "string" then return s end
    return nil
end

function MSWA_GetSpellChargesText(spellID)
    if not spellID or not hasGetCharges then return nil end
    local ok, info = pcall(C_Spell.GetSpellCharges, spellID)
    if not ok or type(info) ~= "table" then return nil end
    local cur = info.currentCharges or info.charges
    if hasTruncZero then
        local ok2, s = pcall(C_StringUtil.TruncateWhenZero, cur)
        if ok2 and type(s) == "string" then return s end
    end
    if cur ~= nil then return tostring(cur) end
    return nil
end

-----------------------------------------------------------
-- Glow remaining: ZERO pcall for spells
-----------------------------------------------------------

local hasGetRemaining = C_Spell and C_Spell.GetSpellCooldownRemaining

-- Spell cooldown values are tainted in Midnight â€” pcall required for comparisons.
-- Returns (remaining, isOnCooldown).
-- If tainted, remaining=0 but isOnCooldown may still be true (from pcall success on SetCooldown).
function MSWA_GetSpellGlowRemaining(spellID)
    if not spellID then return 0, false end
    if not (C_Spell and C_Spell.GetSpellCooldown) then return 0, false end
    local cdInfo = C_Spell.GetSpellCooldown(spellID)
    if not cdInfo then return 0, false end
    local ok, remaining = pcall(function()
        local st  = cdInfo.startTime
        local dur = cdInfo.duration
        if st <= 0 or dur <= 1.5 then return 0 end
        return (st + dur) - GetTime()
    end)
    if ok and type(remaining) == "number" and remaining > 0 then
        return remaining, true
    elseif ok then
        return 0, false
    end
    -- pcall failed (tainted) â€” remaining unknown, but caller should use
    -- IsCooldownActive(btn) for the boolean instead
    return 0, false
end

-- Item cooldowns â€” also pcall-wrapped for safety
function MSWA_GetItemGlowRemaining(start, duration)
    if not start or not duration then return 0, false end
    local ok, remaining = pcall(function()
        if start <= 0 or duration <= 1.5 then return 0 end
        return (start + duration) - GetTime()
    end)
    if ok and type(remaining) == "number" and remaining > 0 then
        return remaining, true
    end
    return 0, false
end

-----------------------------------------------------------
-- Grayscale: __mswaSet flag, ZERO pcall
-----------------------------------------------------------

function MSWA_IsCooldownActive(btn)
    if not btn or not btn.cooldown then return false end
    local cd = btn.cooldown
    return cd.__mswaSet and cd:IsShown()
end

-----------------------------------------------------------
-- Hot-path style helpers (accept db + s, no internal lookups)
-----------------------------------------------------------

local TEXT_POINT_OFFSETS = {
    TOPLEFT     = { 1, -1 },
    TOPRIGHT    = { -1, -1 },
    BOTTOMLEFT  = { 1, 1 },
    BOTTOMRIGHT = { -1, 1 },
    CENTER      = { 0, 0 },
}
MSWA_TEXT_POINT_OFFSETS = TEXT_POINT_OFFSETS

MSWA_TEXT_POS_LABELS = {
    TOPLEFT     = "Top Left",
    TOPRIGHT    = "Top Right",
    BOTTOMLEFT  = "Bottom Left",
    BOTTOMRIGHT = "Bottom Right",
    CENTER      = "Center",
}

function MSWA_GetTextPosLabel(point)
    return MSWA_TEXT_POS_LABELS[point] or MSWA_TEXT_POS_LABELS.BOTTOMRIGHT
end

-- Inline text style: no MSWA_GetDB, no MSWA_GetSpellSettings
function MSWA_ApplyTextStyle(btn, db, s)
    -- IMPORTANT:
    -- The built-in Cooldown widget numbers are NOT styleable reliably.
    -- We use a dedicated FontString (btn.cooldownText) for cooldown text.
    -- Fallback to btn.count for legacy/compat.
    local count = (btn and (btn.cooldownText or btn.count))
    if not count then return end
    -- Font key resolution: per-aura override -> global -> DEFAULT
    local fontKey = (s and s.textFontKey) or (db and db.fontKey) or "DEFAULT"
    local path = MSWA_GetFontPathFromKey(fontKey)
    -- Robust fallback: if for any reason Fetch/GetFontPath fails, reuse current font path
    if not path and count.GetFont then path = select(1, count:GetFont()) end
    local size = tonumber((s and s.textFontSize) or (db and db.textFontSize) or 12) or 12
    if size < 6 then size = 6 elseif size > 48 then size = 48 end
    local tc = (s and s.textColor) or (db and db.textColor)
    local r, g, b = 1, 1, 1
    if tc then r = tonumber(tc.r) or 1; g = tonumber(tc.g) or 1; b = tonumber(tc.b) or 1 end
    local point = (s and s.textPoint) or (db and db.textPoint) or "BOTTOMRIGHT"
    local off = TEXT_POINT_OFFSETS[point] or TEXT_POINT_OFFSETS.BOTTOMRIGHT
    if path then count:SetFont(path, size, "OUTLINE") end
    count:SetTextColor(r, g, b, 1)
    count:ClearAllPoints()
    count:SetPoint(point, btn, point, off[1], off[2])
end

-----------------------------------------------------------
-- Cooldown text (custom FontString) â€” lightweight + live
-----------------------------------------------------------

local function _MSWA_FormatCooldownShort(sec, showDecimal)
    -- Keep formatting secret-safe: comparisons guarded.
    if sec == nil then return nil end

    local ok, isNum = pcall(function() return type(sec) == "number" end)
    if not ok or not isNum then
        local ok2, s = pcall(tostring, sec)
        if ok2 and type(s) == "string" then return s end
        return nil
    end

    if sec < 0 then sec = 0 end

    if sec >= 3600 then
        local h = math.floor(sec / 3600 + 0.5)
        return tostring(h) .. "h"
    end
    if sec >= 60 then
        local m = math.floor(sec / 60 + 0.5)
        return tostring(m) .. "m"
    end
    if sec >= 10 then
        return tostring(math.floor(sec + 0.5))
    end
    -- < 10s: show 1 decimal only if enabled
    if showDecimal then
        local v = math.floor(sec * 10 + 0.5) / 10
        return tostring(v)
    end
    return tostring(math.floor(sec + 0.5))
end

function MSWA_UpdateCooldownText(btn, remaining, showDecimal)
    if not btn then return end
    local fs = btn.cooldownText or btn.count
    if not fs then return end

    local txt = nil
    if remaining ~= nil then
        local ok, shouldShow = pcall(function() return remaining > 0 end)
        if ok and shouldShow then
            txt = _MSWA_FormatCooldownShort(remaining, showDecimal)
        end
    end

    if txt and txt ~= "" then
        if btn._mswaLastCDText ~= txt then
            btn._mswaLastCDText = txt
            fs:SetText(txt)
        end
        fs:Show()
    else
        if btn._mswaLastCDText ~= "" then
            btn._mswaLastCDText = ""
            fs:SetText("")
        end
        fs:Hide()
    end
end

-- Inline stack style: no MSWA_GetDB, no MSWA_GetSpellSettings
function MSWA_ApplyStackStyle(btn, s)
    local target = btn.stackText
    if not target then return end
    local db = MSWA_GetDB()
    -- Font key resolution: per-aura override -> global stack -> global -> DEFAULT
    local fontKey = (s and s.stackFontKey) or (db and db.stackFontKey) or (db and db.fontKey) or "DEFAULT"
    local path = MSWA_GetFontPathFromKey(fontKey)
    if not path and target.GetFont then path = select(1, target:GetFont()) end
    local size = tonumber((s and s.stackFontSize) or (db and db.stackFontSize) or 12) or 12
    if size < 6 then size = 6 elseif size > 48 then size = 48 end
    local tc = (s and s.stackColor) or (db and db.stackColor)
    local r, g, b = 1, 1, 1
    if tc then r = tonumber(tc.r) or 1; g = tonumber(tc.g) or 1; b = tonumber(tc.b) or 1 end
    local point = (s and s.stackPoint) or (db and db.stackPoint) or "BOTTOMRIGHT"
    local baseOff = TEXT_POINT_OFFSETS[point] or TEXT_POINT_OFFSETS.BOTTOMRIGHT
    local ox = tonumber((s and s.stackOffsetX) or (db and db.stackOffsetX) or 0) or 0
    local oy = tonumber((s and s.stackOffsetY) or (db and db.stackOffsetY) or 0) or 0
    if path then target:SetFont(path, size, "OUTLINE") end
    target:SetTextColor(r, g, b, 1)
    target:ClearAllPoints()
    target:SetPoint(point, btn, point, baseOff[1] + ox, baseOff[2] + oy)
end

-----------------------------------------------------------
-- Buff visual (stacks/charges) Ã¢â‚¬â€œ accepts db + s
-----------------------------------------------------------

function MSWA_UpdateBuffVisual_Fast(btn, s, spellID, isItem, itemID)
    local target = btn.stackText or btn.count
    if not target then return end
    if btn.stackText and btn.count and btn.stackText ~= btn.count then
        btn.count:SetText(""); btn.count:Hide()
    end
    local showMode = (s and s.stackShowMode) or "auto"
    if showMode == "hide" then target:SetText(""); target:Hide(); return end
    if isItem then
        if itemID and GetItemCount then
            local cnt = GetItemCount(itemID, false, false)
            if type(cnt) == "number" then target:SetText(tostring(cnt)); target:Show()
            else target:SetText(""); target:Hide() end
        else target:SetText(""); target:Hide() end
        return
    end
    if spellID then
        local auraData = MSWA_GetPlayerAuraDataBySpellID(spellID)
        local minCount = (showMode == "show") and 0 or 1
        local stackText = MSWA_GetAuraStackText(auraData, minCount)
        if not stackText then stackText = MSWA_GetSpellChargesText(spellID) end
        if stackText then target:SetText(stackText); target:Show()
        else target:SetText(""); target:Hide() end
        return
    end
    target:SetText(""); target:Hide()
end

-----------------------------------------------------------
-- Conditional text color Ã¢â‚¬â€œ accepts s directly
-----------------------------------------------------------

local function FindCooldownText(cd)
    if not cd or not cd.GetRegions then return nil end
    for _, region in pairs({cd:GetRegions()}) do
        if region and region.IsObjectType and region:IsObjectType("FontString") then return region end
    end
    if cd.GetChildren then
        for _, child in pairs({cd:GetChildren()}) do
            if child and child.GetRegions then
                for _, region in pairs({child:GetRegions()}) do
                    if region and region.IsObjectType and region:IsObjectType("FontString") then return region end
                end
            end
        end
    end
    return nil
end

function MSWA_ApplyConditionalTextColor_Fast(btn, s, db, remaining, isOnCooldown)
    local baseTC = (s and s.textColor) or (db and db.textColor)
    local fr, fg, fb = 1, 1, 1
    if baseTC then fr = tonumber(baseTC.r) or 1; fg = tonumber(baseTC.g) or 1; fb = tonumber(baseTC.b) or 1 end
    if s and s.textColor2Enabled and s.textColor2 then
        local cond = s.textColor2Cond or "TIMER_BELOW"
        local val  = tonumber(s.textColor2Value) or 5
        remaining  = remaining or 0
        local condActive = false
        if cond == "TIMER_BELOW" then
            condActive = isOnCooldown and remaining <= val and remaining > 0
        elseif cond == "TIMER_ABOVE" then
            condActive = isOnCooldown and remaining >= val
        end
        if condActive then
            fr = tonumber(s.textColor2.r) or 1; fg = tonumber(s.textColor2.g) or 0; fb = tonumber(s.textColor2.b) or 0
        end
    end
    if btn.cooldown then
        local cdText = btn._mswaCDText
        if cdText == nil then
            cdText = FindCooldownText(btn.cooldown)
            btn._mswaCDText = cdText or false
        elseif cdText == false then
            cdText = nil
        end
        if cdText then cdText:SetTextColor(fr, fg, fb, 1) end
    end
end

-----------------------------------------------------------
-- Swipe darken Ã¢â‚¬â€œ accepts s directly
-----------------------------------------------------------

function MSWA_ApplySwipeDarken_Fast(btn, s)
    local cd = btn and btn.cooldown
    if not cd then return end

    -- We always show a Blizzard-style radial swipe by default.
    -- The Options toggle "Swipe darkens on loss" controls *direction* (reverse),
    -- NOT whether the swipe exists.
    --
    -- Standard Blizzard cooldown swipe: remaining time is dark, elapsed is bright.
    -- "Darkens on loss": elapsed becomes dark (reverse swipe), like a draining aura.
    local reverse = (s and s.swipeDarken) and true or false

    -- IMPORTANT (12.0/Midnight): Cooldown setters/clears may reset flags.
    -- Re-apply every time to guarantee the swipe stays correct.
    cd.__mswaSwipeState = reverse and 2 or 1

    if cd.SetDrawEdge then cd:SetDrawEdge(false) end
    if cd.SetDrawSwipe then cd:SetDrawSwipe(true) end
    if cd.SetSwipeColor then cd:SetSwipeColor(0, 0, 0, 0.8) end
    if cd.SetReverse then
        cd:SetReverse(reverse)
    else
        -- Fallback for older cooldown implementations
        cd.reverse = reverse
    end
end

-----------------------------------------------------------
-- Legacy compat shims (Options UI calls these by name)
-----------------------------------------------------------

function MSWA_GetTextStyleForKey(key)
    local db = MSWA_GetDB()
    local s = key and select(1, MSWA_GetSpellSettings(db, key))
    local size = tonumber((s and s.textFontSize) or (db and db.textFontSize) or 12) or 12
    if size < 6 then size = 6 elseif size > 48 then size = 48 end
    local tc = (s and s.textColor) or (db and db.textColor) or {r=1,g=1,b=1}
    local point = (s and s.textPoint) or (db and db.textPoint) or "BOTTOMRIGHT"
    local off = TEXT_POINT_OFFSETS[point] or TEXT_POINT_OFFSETS.BOTTOMRIGHT
    return size, tonumber(tc.r) or 1, tonumber(tc.g) or 1, tonumber(tc.b) or 1, point, off[1], off[2]
end

function MSWA_GetStackStyleForKey(key)
    local db = MSWA_GetDB()
    local s = key and select(1, MSWA_GetSpellSettings(db, key))
    local size = tonumber((s and s.stackFontSize) or (db and db.stackFontSize) or 12) or 12
    if size < 6 then size = 6 elseif size > 48 then size = 48 end
    local tc = (s and s.stackColor) or (db and db.stackColor) or {r=1,g=1,b=1}
    local point = (s and s.stackPoint) or (db and db.stackPoint) or "BOTTOMRIGHT"
    return size, tonumber(tc.r) or 1, tonumber(tc.g) or 1, tonumber(tc.b) or 1, point, tonumber((s and s.stackOffsetX) or (db and db.stackOffsetX) or 0) or 0, tonumber((s and s.stackOffsetY) or (db and db.stackOffsetY) or 0) or 0
end

function MSWA_GetStackShowMode(key)
    if not key then return "auto" end
    local s = select(1, MSWA_GetSpellSettings(MSWA_GetDB(), key))
    return (s and s.stackShowMode) or "auto"
end

function MSWA_ApplyTextStyleToButton(btn, key)
    local db = MSWA_GetDB()
    MSWA_ApplyTextStyle(btn, db, key and select(1, MSWA_GetSpellSettings(db, key)))
end

function MSWA_ApplyStackStyleToButton(btn, key)
    MSWA_ApplyStackStyle(btn, key and select(1, MSWA_GetSpellSettings(MSWA_GetDB(), key)))
end

function MSWA_ApplyGrayscaleOnCooldownToButton(btn, key)
    if not btn or not btn.icon then return end
    local s = key and select(1, MSWA_GetSpellSettings(MSWA_GetDB(), key))
    btn.icon:SetDesaturated(s and s.grayOnCooldown and MSWA_IsCooldownActive(btn) or false)
end

function MSWA_UpdateBuffVisual(btn, key)
    local s = key and select(1, MSWA_GetSpellSettings(MSWA_GetDB(), key))
    local isItem = MSWA_IsItemKey(key)
    MSWA_UpdateBuffVisual_Fast(btn, s, not isItem and MSWA_KeyToSpellID(key), isItem, isItem and MSWA_KeyToItemID(key))
end

function MSWA_ApplyConditionalTextColor(btn, key, remaining, isOnCooldown)
    local db = MSWA_GetDB()
    MSWA_ApplyConditionalTextColor_Fast(btn, key and select(1, MSWA_GetSpellSettings(db, key)), db, remaining, isOnCooldown)
end

function MSWA_ApplySwipeDarken(btn, key)
    MSWA_ApplySwipeDarken_Fast(btn, key and select(1, MSWA_GetSpellSettings(MSWA_GetDB(), key)))
end

function MSWA_ShouldGrayOnCooldown(key)
    if not key then return false end
    local s = select(1, MSWA_GetSpellSettings(MSWA_GetDB(), key))
    return (s and s.grayOnCooldown) and true or false
end

function MSWA_IsCooldownFrameActive(cd)
    if not cd then return false end
    return cd.__mswaSet and cd:IsShown()
end

function MSWA_UpdateItemCount(btn, itemID)
    local target = btn and (btn.stackText or btn.count)
    if not target or not itemID or not GetItemCount then
        if target then target:SetText(""); target:Hide() end; return
    end
    local cnt = GetItemCount(itemID, false, false)
    if type(cnt) == "number" then target:SetText(tostring(cnt)); target:Show()
    else target:SetText(""); target:Hide() end
end
