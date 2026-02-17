-- ########################################################
-- MSA_Glow.lua
-- LibCustomGlow integration â€“ conditional glow per aura
-- v3: hot-path accepts gs directly, zero DB lookups
-- ########################################################

local type, tonumber = type, tonumber

-----------------------------------------------------------
-- Library reference
-----------------------------------------------------------

local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
MSWA.LCG = LCG

if not LCG then
    function MSWA_UpdateGlow() end
    function MSWA_UpdateGlow_Fast() end
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
    TIMER_BELOW  = "Timer <= X sec",
    TIMER_ABOVE  = "Timer >= X sec",
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
-- Helper: get/create glow settings (Options UI only)
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
-- Condition evaluation (inlined, no function call overhead)
-----------------------------------------------------------

local function ShouldGlow(gs, remaining, isOnCooldown)
    if not gs or not gs.enabled then return false end
    local cond = gs.condition or "ALWAYS"
    if cond == "ALWAYS" then return true
    elseif cond == "READY" then return not isOnCooldown
    elseif cond == "ON_COOLDOWN" then return isOnCooldown
    elseif cond == "TIMER_BELOW" then
        return isOnCooldown and remaining <= (tonumber(gs.conditionValue) or 5) and remaining > 0
    elseif cond == "TIMER_ABOVE" then
        return isOnCooldown and remaining >= (tonumber(gs.conditionValue) or 5)
    end
    return false
end

-----------------------------------------------------------
-- Apply glow (unchanged)
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
        LCG.PixelGlow_Start(btn, c, tonumber(gs.lines) or 8, tonumber(gs.frequency) or 0.25, nil, tonumber(gs.thickness) or 2, 0, 0, false, GLOW_KEY)
    elseif glowType == "AUTOCAST" then
        LCG.AutoCastGlow_Start(btn, c, tonumber(gs.lines) or 4, tonumber(gs.frequency) or 0.125, tonumber(gs.scale) or 1, 0, 0, GLOW_KEY)
    elseif glowType == "BUTTON" then
        LCG.ButtonGlow_Start(btn, c, tonumber(gs.frequency) or 0.125)
    elseif glowType == "PROC" then
        LCG.ProcGlow_Start(btn, { color = c, duration = tonumber(gs.duration) or 1, key = GLOW_KEY })
    end
end

-----------------------------------------------------------
-- Stop glow
-----------------------------------------------------------

local function StopGlowOnButton(btn)
    if not btn then return end
    local gt = btn._msaGlowType
    if not gt then return end
    if gt == "PIXEL" then LCG.PixelGlow_Stop(btn, GLOW_KEY)
    elseif gt == "AUTOCAST" then LCG.AutoCastGlow_Stop(btn, GLOW_KEY)
    elseif gt == "BUTTON" then LCG.ButtonGlow_Stop(btn)
    elseif gt == "PROC" then LCG.ProcGlow_Stop(btn, GLOW_KEY) end
    btn._msaGlowType = nil
    btn._msaGlowActive = false
end

-----------------------------------------------------------
-- HOT PATH: UpdateGlow_Fast (gs passed in, zero DB lookup)
-----------------------------------------------------------

function MSWA_UpdateGlow_Fast(btn, gs, remaining, isOnCooldown)
    if ShouldGlow(gs, remaining, isOnCooldown) then
        local newType = gs.glowType or "PIXEL"
        if btn._msaGlowActive and btn._msaGlowType == newType then
            -- Already glowing with correct type, don't restart animation
            return
        end
        -- Type changed or glow just became active
        if btn._msaGlowActive then
            StopGlowOnButton(btn)
        end
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
-- Legacy: UpdateGlow (Options/preview, does own DB lookup)
-----------------------------------------------------------

function MSWA_UpdateGlow(btn, key, remaining, isOnCooldown)
    if not LCG or not btn then return end
    local db = MSWA_GetDB()
    local s = db.spellSettings and (db.spellSettings[key] or db.spellSettings[tostring(key)])
    local gs = s and s.glow
    if not gs or not gs.enabled then
        if btn._msaGlowActive then StopGlowOnButton(btn) end
        return
    end
    MSWA_UpdateGlow_Fast(btn, gs, remaining or 0, isOnCooldown or false)
end

-----------------------------------------------------------
-- Public API: Stop glow
-----------------------------------------------------------

function MSWA_StopGlow(btn)
    if not LCG or not btn then return end
    StopGlowOnButton(btn)
end

function MSWA_StopAllGlows()
    if not LCG or not MSWA.icons then return end
    for i = 1, MSWA.MAX_ICONS do
        local btn = MSWA.icons[i]
        if btn then StopGlowOnButton(btn) end
    end
end
