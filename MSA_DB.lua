-- ########################################################
-- MSA_DB.lua
-- SavedVariables access + schema migrations
-- Migration runs ONCE, then GetDB is a single table return.
-- ########################################################

MidnightSimpleAurasDB = MidnightSimpleAurasDB or {}

local dbReady = false

function MSWA_GetDB()
    if dbReady then return MidnightSimpleAurasDB end

    local db = MidnightSimpleAurasDB

    ----------------------------------------------------------------
    -- Schema migrations (run once per session)
    ----------------------------------------------------------------
    if not db.schemaVersion or db.schemaVersion < 2 then
        db.trackedSpells  = {}
        db.trackedItems   = {}
        db.spellSettings  = {}
        db.schemaVersion  = 2
    end

    if db.schemaVersion < 3 then
        db.trackedSpells = db.trackedSpells or {}
        db.trackedItems  = db.trackedItems  or {}
        db.spellSettings = db.spellSettings or {}
        db.trackedSpells["TRINKET13"] = nil
        db.trackedSpells["TRINKET14"] = nil
        db.trackTrinket13 = nil
        db.trackTrinket14 = nil
        db.schemaVersion = 3
    end

    if db.schemaVersion < 4 then
        db.groups        = db.groups or {}
        db.groupOrder    = db.groupOrder or {}
        db.auraGroups    = db.auraGroups or {}
        db._groupCounter = db._groupCounter or 0
        db.schemaVersion = 4
    end

    if db.schemaVersion < 5 then
        db._instanceCounter = db._instanceCounter or 0
        db.schemaVersion = 5
    end

    ----------------------------------------------------------------
    -- Defaults (ensure all fields exist)
    ----------------------------------------------------------------
    if not db.position then db.position = { x = 0, y = -150 } end
    if db.locked == nil then db.locked = false end
    if db.showSpellID == nil then db.showSpellID = false end
    if db.showIconID == nil then db.showIconID = false end

    db.trackedSpells = db.trackedSpells or {}
    db.trackedItems  = db.trackedItems or {}
    db.spellSettings = db.spellSettings or {}
    db.groups        = db.groups or {}
    db.groupOrder    = db.groupOrder or {}
    db.auraGroups    = db.auraGroups or {}
    db.customNames   = db.customNames or {}

    if db.textFontSize == nil then db.textFontSize = 12 end
    if not db.textColor then
        db.textColor = { r = 1, g = 1, b = 1 }
    else
        if db.textColor.r == nil then db.textColor.r = 1 end
        if db.textColor.g == nil then db.textColor.g = 1 end
        if db.textColor.b == nil then db.textColor.b = 1 end
    end
    if not db.textPoint then db.textPoint = "BOTTOMRIGHT" end

    dbReady = true
    return db
end

-- Force re-run of defaults (e.g. after profile import)
function MSWA_ResetDBCache()
    dbReady = false
end

function MSWA_GetTrackedSpells()
    return MSWA_GetDB().trackedSpells
end
