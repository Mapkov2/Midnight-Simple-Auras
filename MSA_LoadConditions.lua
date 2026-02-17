-- ########################################################
-- MSA_LoadConditions.lua
-- Centralized load-condition evaluation + class/spec data
--
-- Single source of truth: MSWA_ShouldLoadAura(settings)
-- Used by UpdateEngine (hot path) AND Options list filtering.
-- ########################################################

local type, tostring, tonumber = type, tostring, tonumber
local pcall = pcall

-----------------------------------------------------------
-- Player identity cache  (computed once, never changes)
-----------------------------------------------------------

local playerName       -- "Charname"
local playerRealm      -- "Realmname" (no spaces)
local playerFullName   -- "Charname-Realmname" (canonical, lowercased)
local playerClassToken -- "ROGUE", "WARRIOR", etc.
local playerSpecIndex  -- 1-4  (0 or nil = unknown)

-- Rebuild identity.  Called once on PLAYER_LOGIN and on
-- ACTIVE_TALENT_GROUP_CHANGED / PLAYER_SPECIALIZATION_CHANGED.
function MSWA_RefreshPlayerIdentity()
    playerName  = UnitName("player") or ""
    playerRealm = ""
    if GetNormalizedRealmName then
        playerRealm = GetNormalizedRealmName() or ""
    elseif GetRealmName then
        playerRealm = (GetRealmName() or ""):gsub("%s+", "")
    end
    playerRealm = tostring(playerRealm):gsub("%s+", "")

    if playerRealm ~= "" then
        playerFullName = (playerName .. "-" .. playerRealm):lower()
    else
        playerFullName = playerName:lower()
    end

    -- Class (never changes, but grab it here for one-stop init)
    local _, classToken = UnitClass("player")
    playerClassToken = classToken or "UNKNOWN"

    -- Spec
    if GetSpecialization then
        playerSpecIndex = GetSpecialization() or 0
    else
        playerSpecIndex = 0
    end
end

-- Accessors
function MSWA_GetPlayerFullName()   return playerFullName   end
function MSWA_GetPlayerRealm()      return playerRealm      end
function MSWA_GetPlayerName()       return playerName        end
function MSWA_GetPlayerClassToken() return playerClassToken  end
function MSWA_GetPlayerSpecIndex()  return playerSpecIndex   end

-----------------------------------------------------------
-- Class data  (fileToken → display info)
-----------------------------------------------------------

MSWA_CLASS_LIST = {
    -- order matches WoW class IDs for consistency
    { token = "WARRIOR",      name = "Warrior",       color = "C69B6D" },
    { token = "PALADIN",      name = "Paladin",       color = "F48CBA" },
    { token = "HUNTER",       name = "Hunter",        color = "AAD372" },
    { token = "ROGUE",        name = "Rogue",         color = "FFF468" },
    { token = "PRIEST",       name = "Priest",        color = "FFFFFF" },
    { token = "DEATHKNIGHT",  name = "Death Knight",  color = "C41E3A" },
    { token = "SHAMAN",       name = "Shaman",        color = "0070DD" },
    { token = "MAGE",         name = "Mage",          color = "3FC7EB" },
    { token = "WARLOCK",      name = "Warlock",       color = "8788EE" },
    { token = "MONK",         name = "Monk",          color = "00FF98" },
    { token = "DRUID",        name = "Druid",         color = "FF7C0A" },
    { token = "DEMONHUNTER",  name = "Demon Hunter",  color = "A330C9" },
    { token = "EVOKER",       name = "Evoker",        color = "33937F" },
}

-- Lookup table:  token → { name, color }
MSWA_CLASS_INFO = {}
for _, c in ipairs(MSWA_CLASS_LIST) do
    MSWA_CLASS_INFO[c.token] = c
end

-----------------------------------------------------------
-- Spec data  (fileToken → ordered list of spec names)
-- Indices match GetSpecialization() return values (1-based).
-----------------------------------------------------------

MSWA_SPEC_DATA = {
    WARRIOR     = { "Arms",          "Fury",          "Protection"   },
    PALADIN     = { "Holy",          "Protection",    "Retribution"  },
    HUNTER      = { "Beast Mastery", "Marksmanship",  "Survival"     },
    ROGUE       = { "Assassination", "Outlaw",        "Subtlety"     },
    PRIEST      = { "Discipline",    "Holy",          "Shadow"       },
    DEATHKNIGHT = { "Blood",         "Frost",         "Unholy"       },
    SHAMAN      = { "Elemental",     "Enhancement",   "Restoration"  },
    MAGE        = { "Arcane",        "Fire",          "Frost"        },
    WARLOCK     = { "Affliction",    "Demonology",    "Destruction"  },
    MONK        = { "Brewmaster",    "Mistweaver",    "Windwalker"   },
    DRUID       = { "Balance",       "Feral",         "Guardian",     "Restoration" },
    DEMONHUNTER = { "Havoc",         "Vengeance"      },
    EVOKER      = { "Devastation",   "Preservation",  "Augmentation" },
}

-----------------------------------------------------------
-- Helper: get spec name for a class + specIndex
-----------------------------------------------------------

function MSWA_GetSpecName(classToken, specIdx)
    local specs = classToken and MSWA_SPEC_DATA[classToken]
    if specs and specIdx and specIdx >= 1 and specIdx <= #specs then
        return specs[specIdx]
    end
    return nil
end

-----------------------------------------------------------
-- Normalize a character name for comparison.
--   "Mapko"  →  "mapko-realm"   (auto-append current realm)
--   "Mapko-Antonidas" →  "mapko-antonidas"
--   nil / "" → nil  (means "any")
-----------------------------------------------------------

local function NormalizeCharName(raw)
    if type(raw) ~= "string" then return nil end
    local s = raw:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s", "")
    if s == "" then return nil end

    -- Auto-append current realm if no dash present
    if not s:find("%-") then
        if playerRealm and playerRealm ~= "" then
            s = s .. "-" .. playerRealm
        end
    end
    return s:lower()
end

-----------------------------------------------------------
-- MSWA_ShouldLoadAura(settings)
--
-- Returns true if the aura should be shown right now.
-- `settings` is the per-aura spellSettings table (may be nil).
--
-- This is the ONE function both engine and UI call.
-----------------------------------------------------------

function MSWA_ShouldLoadAura(s)
    if not s then return true end

    -- Never
    if s.loadNever == true or s.loadMode == "NEVER" then
        return false
    end

    -- Character filter (Name-Realm)
    local wantChar = s.loadCharName or s.loadChar
    if wantChar and wantChar ~= "" then
        if not playerFullName then MSWA_RefreshPlayerIdentity() end
        local normalized = NormalizeCharName(wantChar)
        if normalized and normalized ~= playerFullName then
            return false
        end
    end

    -- Class filter
    local wantClass = s.loadClass
    if wantClass and wantClass ~= "" then
        if not playerClassToken then MSWA_RefreshPlayerIdentity() end
        if wantClass ~= playerClassToken then
            return false
        end
    end

    -- Spec filter
    local wantSpec = s.loadSpec
    if wantSpec then
        wantSpec = tonumber(wantSpec)
        if wantSpec and wantSpec > 0 then
            if not playerSpecIndex then MSWA_RefreshPlayerIdentity() end
            if wantSpec ~= playerSpecIndex then
                return false
            end
        end
    end

    -- Combat filter
    local inCombat = InCombatLockdown and InCombatLockdown() and true or false

    local cm = s.loadCombatMode
    if cm == "IN" then
        if not inCombat then return false end
    elseif cm == "OUT" then
        if inCombat then return false end
    end

    -- Legacy loadMode fallback
    if not cm then
        if s.loadMode == "IN_COMBAT" and not inCombat then return false end
        if s.loadMode == "OUT_OF_COMBAT" and inCombat then return false end
    end

    -- Encounter filter
    local inEncounter = IsEncounterInProgress and IsEncounterInProgress() and true or false

    local em = s.loadEncounterMode
    if em == "IN" then
        if not inEncounter then return false end
    elseif em == "OUT" then
        if inEncounter then return false end
    end

    return true
end

-----------------------------------------------------------
-- Event frame: refresh identity on login + spec change
-----------------------------------------------------------

local identityFrame = CreateFrame("Frame")
identityFrame:RegisterEvent("PLAYER_LOGIN")
identityFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

-- Spec change events (name varies by expansion)
if identityFrame.RegisterEvent then
    pcall(identityFrame.RegisterEvent, identityFrame, "ACTIVE_TALENT_GROUP_CHANGED")
    pcall(identityFrame.RegisterEvent, identityFrame, "PLAYER_SPECIALIZATION_CHANGED")
    pcall(identityFrame.RegisterEvent, identityFrame, "PLAYER_TALENT_UPDATE")
end

identityFrame:SetScript("OnEvent", function(self, event, ...)
    MSWA_RefreshPlayerIdentity()

    -- Spec/talent change → re-evaluate load conditions
    if event == "ACTIVE_TALENT_GROUP_CHANGED"
    or event == "PLAYER_SPECIALIZATION_CHANGED"
    or event == "PLAYER_TALENT_UPDATE" then
        if MSWA_RequestUpdateSpells then
            MSWA_RequestUpdateSpells()
        end
        if MSWA_RefreshOptionsList and MSWA and MSWA.optionsFrame
           and MSWA.optionsFrame:IsShown() then
            MSWA_RefreshOptionsList()
        end
    end
end)
