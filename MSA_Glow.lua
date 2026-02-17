-- ########################################################
-- MSA_Glow.lua
-- LibCustomGlow integration – conditional glow per aura
-- ########################################################

local pairs, type, tonumber = pairs, type, tonumber
local GetTime = GetTime

-----------------------------------------------------------
-- Library reference
-----------------------------------------------------------

local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
MSWA.LCG = LCG

if not LCG then
    -- Graceful degradation: stub out all glow functions
    function MSWA_UpdateGlow() end
    function MSWA_StopGlow() end
    function MSWA_StopAllGlows() end
    function MSWA_IsGlowAvailable() return false end
    return
end

function MSWA_IsGlowAvailable() return true end

-----------------------------------------------------------
-- Constants
-----------------------------------------------------------

local GLOW_KEY = "MSA"

local GLOW_TYPES = {
    PIXEL    = "Pixel Glow",
    AUTOCAST = "AutoCast Glow",
    BUTTON   = "Button Glow",
    PROC     = "Proc Glow",
}
MSWA.GLOW_TYPES = GLOW_TYPES

local GLOW_TYPE_ORDER = { "PIXEL", "AUTOCAST", "BUTTON", "PROC" }
MSWA.GLOW_TYPE_ORDER = GLOW_TYPE_ORDER

local GLOW_CONDITIONS = {
    ALWAYS       = "Always",
    READY        = "Ready (off CD)",
    ON_COOLDOWN  = "On Cooldown",
    TIMER_BELOW  = "Timer ≤ X sec",
    TIMER_ABOVE  = "Timer ≥ X sec",
}
MSWA.GLOW_CONDITIONS = GLOW_CONDITIONS

local GLOW_COND_ORDER = { "ALWAYS", "READY", "ON_COOLDOWN", "TIMER_BELOW", "TIMER_ABOVE" }
MSWA.GLOW_COND_ORDER = GLOW_COND_ORDER

-----------------------------------------------------------
-- Defaults
-----------------------------------------------------------

local GLOW_DEFAULTS = {
    enabled        = false,
    glowType       = "PIXEL",
    color          = { r = 0.95, g = 0.95, b = 0.32, a = 1 },
    condition      = "ALWAYS",
    conditionValue = 5,
    lines          = 8,
    frequency      = 0.25,
    thickness      = 2,
    scale          = 1,
    duration       = 1,
}
MSWA.GLOW_DEFAULTS = GLOW_DEFAULTS

-----------------------------------------------------------
-- Helper: get glow settings with defaults
-----------------------------------------------------------

function MSWA_GetGlowSettings(spellSettings)
    if not spellSettings or not spellSettings.glow then return nil end
    return spellSettings.glow
end

function MSWA_GetOrCreateGlowSettings(spellSettings)
    if not spellSettings then return nil end
    if not spellSettings.glow then
        spellSettings.glow = {}
        for k, v in pairs(GLOW_DEFAULTS) do
            if type(v) == "table" then
                spellSettings.glow[k] = {}
                for kk, vv in pairs(v) do spellSettings.glow[k][kk] = vv end
            else
                spellSettings.glow[k] = v
            end
        end
    end
    return spellSettings.glow
end

-----------------------------------------------------------
-- Condition evaluation
-----------------------------------------------------------

local function ShouldGlow(gs, remaining, isOnCooldown)
    if not gs or not gs.enabled then return false end

    local cond = gs.condition or "ALWAYS"

    if cond == "ALWAYS" then
        return true
    elseif cond == "READY" then
        return not isOnCooldown
    elseif cond == "ON_COOLDOWN" then
        return isOnCooldown
    elseif cond == "TIMER_BELOW" then
        local val = tonumber(gs.conditionValue) or 5
        return isOnCooldown and remaining <= val and remaining > 0
    elseif cond == "TIMER_ABOVE" then
        local val = tonumber(gs.conditionValue) or 5
        return isOnCooldown and remaining >= val
    end

    return false
end

-----------------------------------------------------------
-- Apply glow to a button
-----------------------------------------------------------

local function ApplyGlow(btn, gs)
    local glowType = gs.glowType or "PIXEL"
    local gc = gs.color or GLOW_DEFAULTS.color
    local c = {
        tonumber(gc.r) or 0.95,
        tonumber(gc.g) or 0.95,
        tonumber(gc.b) or 0.32,
        tonumber(gc.a) or 1,
    }

    if glowType == "PIXEL" then
        local lines     = tonumber(gs.lines)     or GLOW_DEFAULTS.lines
        local freq      = tonumber(gs.frequency)  or GLOW_DEFAULTS.frequency
        local thickness = tonumber(gs.thickness)  or GLOW_DEFAULTS.thickness
        LCG.PixelGlow_Start(btn, c, lines, freq, nil, thickness, 0, 0, false, GLOW_KEY)

    elseif glowType == "AUTOCAST" then
        local particles = tonumber(gs.lines) or 4
        local freq      = tonumber(gs.frequency) or 0.125
        local scale     = tonumber(gs.scale)     or GLOW_DEFAULTS.scale
        LCG.AutoCastGlow_Start(btn, c, particles, freq, scale, 0, 0, GLOW_KEY)

    elseif glowType == "BUTTON" then
        local freq = tonumber(gs.frequency) or 0.125
        LCG.ButtonGlow_Start(btn, c, freq)

    elseif glowType == "PROC" then
        local dur = tonumber(gs.duration) or GLOW_DEFAULTS.duration
        LCG.ProcGlow_Start(btn, { color = c, duration = dur, key = GLOW_KEY })
    end
end

-----------------------------------------------------------
-- Stop glow on a button
-----------------------------------------------------------

local function StopGlowOnButton(btn)
    if not btn then return end
    local gt = btn._msaGlowType
    if not gt then return end

    if gt == "PIXEL" then
        LCG.PixelGlow_Stop(btn, GLOW_KEY)
    elseif gt == "AUTOCAST" then
        LCG.AutoCastGlow_Stop(btn, GLOW_KEY)
    elseif gt == "BUTTON" then
        LCG.ButtonGlow_Stop(btn)
    elseif gt == "PROC" then
        LCG.ProcGlow_Stop(btn, GLOW_KEY)
    end
    btn._msaGlowType = nil
    btn._msaGlowActive = false
end

-----------------------------------------------------------
-- Public API: Update glow on a button
-----------------------------------------------------------
-- Called from MSA_UpdateEngine after each icon is set up
--   btn          = the icon button frame
--   key          = aura key
--   remaining    = seconds remaining on cooldown/buff (0 if ready)
--   isOnCooldown = true if spell/item is currently on cooldown

function MSWA_UpdateGlow(btn, key, remaining, isOnCooldown)
    if not LCG or not btn then return end

    local db = MSWA_GetDB()
    local s = db.spellSettings and (db.spellSettings[key] or db.spellSettings[tostring(key)])
    local gs = s and s.glow

    if ShouldGlow(gs, remaining or 0, isOnCooldown or false) then
        local newType = gs.glowType or "PIXEL"

        -- If glow type changed, stop old one first
        if btn._msaGlowActive and btn._msaGlowType ~= newType then
            StopGlowOnButton(btn)
        end

        -- Apply (LCG handles re-application gracefully)
        ApplyGlow(btn, gs)
        btn._msaGlowType = newType
        btn._msaGlowActive = true
    else
        if btn._msaGlowActive then
            StopGlowOnButton(btn)
        end
    end
end

-----------------------------------------------------------
-- Public API: Stop glow on a button
-----------------------------------------------------------

function MSWA_StopGlow(btn)
    if not LCG or not btn then return end
    StopGlowOnButton(btn)
end

-----------------------------------------------------------
-- Public API: Stop all glows (cleanup)
-----------------------------------------------------------

function MSWA_StopAllGlows()
    if not LCG then return end
    if not MSWA.icons then return end
    for i = 1, MSWA.MAX_ICONS do
        local btn = MSWA.icons[i]
        if btn then StopGlowOnButton(btn) end
    end
end
