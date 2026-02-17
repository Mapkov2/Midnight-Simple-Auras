-- ########################################################
-- MSA_KeyHelpers.lua
-- Key type helpers, display name, icon lookup
-- ########################################################

local tonumber, tostring, type = tonumber, tostring, type
local GetItemInfo = GetItemInfo
local GetItemIcon = GetItemIcon

local DRAFT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-----------------------------------------------------------
-- Key type checks
-----------------------------------------------------------

function MSWA_IsItemKey(key)
    return type(key) == "string" and key:match("^item:%d+$") ~= nil
end

function MSWA_KeyToItemID(key)
    if not MSWA_IsItemKey(key) then return nil end
    local id = key:match("^item:(%d+)$")
    return id and tonumber(id) or nil
end

function MSWA_IsDraftKey(key)
    return type(key) == "string" and key:match("^DRAFT:%d+$") ~= nil
end

function MSWA_NewDraftKey()
    local db = MSWA_GetDB()
    db._draftCounter = (db._draftCounter or 0) + 1
    return ("DRAFT:%d"):format(db._draftCounter)
end

function MSWA_IsSpellInstanceKey(key)
    return type(key) == "string" and key:match("^spell:%d+:%d+$") ~= nil
end

function MSWA_KeyToSpellID(key)
    if type(key) == "number" then return key end
    if type(key) == "string" then
        local id = key:match("^spell:(%d+):%d+$")
        if id then return tonumber(id) end
    end
    return nil
end

function MSWA_NewSpellInstanceKey(spellID)
    local db = MSWA_GetDB()
    db._instanceCounter = (db._instanceCounter or 0) + 1
    return ("spell:%d:%d"):format(spellID, db._instanceCounter)
end

function MSWA_IsSpellKey(key)
    return type(key) == "number" or MSWA_IsSpellInstanceKey(key)
end

-----------------------------------------------------------
-- Auto Buff check
-----------------------------------------------------------

function MSWA_IsAutoBuff(key)
    if key == nil then return false end
    local db = MSWA_GetDB()
    if not db or not db.spellSettings then return false end
    local s = db.spellSettings[key] or db.spellSettings[tostring(key)]
    return s and s.auraMode == "AUTOBUFF"
end

-----------------------------------------------------------
-- Display name / icon
-----------------------------------------------------------

function MSWA_GetDisplayNameForKey(key)
    local db = MSWA_GetDB()
    if db.customNames and db.customNames[key] and db.customNames[key] ~= "" then
        return db.customNames[key]
    end
    if MSWA_IsDraftKey(key) then
        return "???"
    elseif MSWA_IsItemKey(key) then
        local itemID = MSWA_KeyToItemID(key)
        if itemID and GetItemInfo then
            local name = GetItemInfo(itemID)
            if name then return name end
        end
        return ("Item %d"):format(itemID or 0)
    elseif MSWA_IsSpellInstanceKey(key) then
        local spellID = MSWA_KeyToSpellID(key)
        local name = spellID and MSWA_GetSpellName(spellID) or nil
        return (name or "Spell") .. " (copy)"
    else
        local name = (type(key) == "number") and MSWA_GetSpellName(key) or nil
        return name or "Unknown"
    end
end

function MSWA_GetIconForKey(key)
    if MSWA_IsDraftKey(key) then
        return DRAFT_ICON
    elseif MSWA_IsItemKey(key) then
        local itemID = MSWA_KeyToItemID(key)
        if itemID and GetItemIcon then
            local tex = GetItemIcon(itemID)
            if tex then return tex end
        end
        return 136243
    else
        local spellID = MSWA_KeyToSpellID(key)
        if spellID then
            return MSWA_GetSpellIcon(spellID) or 136243
        end
        return 136243
    end
end

-----------------------------------------------------------
-- Settings key resolution (number/string equivalence)
-----------------------------------------------------------

function MSWA_ResolveSpellSettingsKey(db, key)
    if not db then return key end
    db.spellSettings = db.spellSettings or {}
    if key == nil then return nil end

    if db.spellSettings[key] ~= nil then
        return key
    end

    local t = type(key)
    if t == "number" then
        local sk = tostring(key)
        if db.spellSettings[sk] ~= nil then return sk end
    elseif t == "string" then
        local nk = tonumber(key)
        if nk and db.spellSettings[nk] ~= nil then return nk end
    end

    return key
end

function MSWA_GetSpellSettings(db, key)
    if not db or key == nil then return nil, key end
    local resolved = MSWA_ResolveSpellSettingsKey(db, key)
    return (db.spellSettings or {})[resolved], resolved
end

function MSWA_GetOrCreateSpellSettings(db, key)
    if not db or key == nil then return nil, key end
    db.spellSettings = db.spellSettings or {}
    local resolved = MSWA_ResolveSpellSettingsKey(db, key)
    local s = db.spellSettings[resolved]
    if not s then
        s = {}
        db.spellSettings[resolved] = s
    end
    return s, resolved
end

function MSWA_KeyEquals(a, b)
    if a == b then return true end
    local na, nb = tonumber(a), tonumber(b)
    if na and nb and na == nb then return true end
    return tostring(a) == tostring(b)
end

-- Globals for cross-file access
_G.MSWA_GetSpellSettings = MSWA_GetSpellSettings
_G.MSWA_GetOrCreateSpellSettings = MSWA_GetOrCreateSpellSettings
_G.MSWA_ResolveSpellSettingsKey = MSWA_ResolveSpellSettingsKey
