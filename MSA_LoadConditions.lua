-- ########################################################
-- MSA_LoadConditions.lua
-- Centralized load-condition evaluation + class/spec data
--
-- v3: ShouldLoadAura accepts (s, inCombat, inEncounter) to
--     avoid calling InCombatLockdown/IsEncounterInProgress
--     per icon. Caller caches once per update frame.
-- ########################################################

local type, tostring, tonumber = type, tostring, tonumber
local pcall = pcall

-----------------------------------------------------------
-- Player identity cache  (computed once, never changes)
-----------------------------------------------------------

local playerName
local playerRealm
local playerFullName
local playerClassToken
local playerSpecIndex

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

    local _, classToken = UnitClass("player")
    playerClassToken = classToken or "UNKNOWN"

    if GetSpecialization then
        playerSpecIndex = GetSpecialization() or 0
    else
        playerSpecIndex = 0
    end
end

function MSWA_GetPlayerFullName()   return playerFullName   end
function MSWA_GetPlayerRealm()      return playerRealm      end
function MSWA_GetPlayerName()       return playerName        end
function MSWA_GetPlayerClassToken() return playerClassToken  end
function MSWA_GetPlayerSpecIndex()  return playerSpecIndex   end

-----------------------------------------------------------
-- Class / Spec data (unchanged)
-----------------------------------------------------------

MSWA_CLASS_LIST = {
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

MSWA_CLASS_INFO = {}
for _, c in ipairs(MSWA_CLASS_LIST) do
    MSWA_CLASS_INFO[c.token] = c
end

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

function MSWA_GetSpecName(classToken, specIdx)
    local specs = classToken and MSWA_SPEC_DATA[classToken]
    if specs and specIdx and specIdx >= 1 and specIdx <= #specs then
        return specs[specIdx]
    end
    return nil
end

-----------------------------------------------------------
-- NormalizeCharName (local, called rarely)
-----------------------------------------------------------

local function NormalizeCharName(raw)
    if type(raw) ~= "string" then return nil end
    local s = raw:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s", "")
    if s == "" then return nil end
    if not s:find("%-") then
        if playerRealm and playerRealm ~= "" then
            s = s .. "-" .. playerRealm
        end
    end
    return s:lower()
end

-----------------------------------------------------------
-- MSWA_ShouldLoadAura(settings, inCombat, inEncounter)
--
-- inCombat / inEncounter: OPTIONAL. If nil, calls API.
-- Hot path should pass cached values to avoid per-icon API calls.
-----------------------------------------------------------

function MSWA_ShouldLoadAura(s, inCombat, inEncounter)
    if not s then return true end

    -- Never
    if s.loadNever == true or s.loadMode == "NEVER" then
        return false
    end

    -- Character filter
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

    -- Combat filter (use cached value if provided)
    if inCombat == nil then
        inCombat = InCombatLockdown and InCombatLockdown() and true or false
    end
    local cm = s.loadCombatMode
    if cm == "IN" then
        if not inCombat then return false end
    elseif cm == "OUT" then
        if inCombat then return false end
    end
    if not cm then
        if s.loadMode == "IN_COMBAT" and not inCombat then return false end
        if s.loadMode == "OUT_OF_COMBAT" and inCombat then return false end
    end

    -- Encounter filter (use cached value if provided)
    if inEncounter == nil then
        inEncounter = IsEncounterInProgress and IsEncounterInProgress() and true or false
    end
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

if identityFrame.RegisterEvent then
    pcall(identityFrame.RegisterEvent, identityFrame, "ACTIVE_TALENT_GROUP_CHANGED")
    pcall(identityFrame.RegisterEvent, identityFrame, "PLAYER_SPECIALIZATION_CHANGED")
    pcall(identityFrame.RegisterEvent, identityFrame, "PLAYER_TALENT_UPDATE")
end

identityFrame:SetScript("OnEvent", function(self, event)
    MSWA_RefreshPlayerIdentity()
    if event == "ACTIVE_TALENT_GROUP_CHANGED"
    or event == "PLAYER_SPECIALIZATION_CHANGED"
    or event == "PLAYER_TALENT_UPDATE" then
        if MSWA_RequestUpdateSpells then MSWA_RequestUpdateSpells() end
        if MSWA_RefreshOptionsList and MSWA and MSWA.optionsFrame
           and MSWA.optionsFrame:IsShown() then
            MSWA_RefreshOptionsList()
        end
    end
end)
