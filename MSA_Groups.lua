-- ########################################################
-- MSA_Groups.lua
-- Group CRUD, aura group assignment, context menus
-- ########################################################

local tinsert = table.insert
local pairs, tostring = pairs, tostring

-----------------------------------------------------------
-- Group helpers (WA-like)
-----------------------------------------------------------

function MSWA_NewGroupID()
    local db = MSWA_GetDB()
    db._groupCounter = (db._groupCounter or 0) + 1
    return ("GROUP:%d"):format(db._groupCounter)
end

function MSWA_CreateGroup(name)
    local db = MSWA_GetDB()
    db.groups = db.groups or {}
    db.groupOrder = db.groupOrder or {}

    local gid = MSWA_NewGroupID()
    db.groups[gid] = {
        name = name or ("Group %d"):format(db._groupCounter or 0),
        x    = 0,
        y    = 0,
        size = MSWA.ICON_SIZE,
    }
    tinsert(db.groupOrder, gid)
    return gid
end

function MSWA_DeleteGroup(gid)
    local db = MSWA_GetDB()
    if not (db.groups and db.groups[gid]) then return end

    if db.auraGroups then
        for key, g in pairs(db.auraGroups) do
            if g == gid then db.auraGroups[key] = nil end
        end
    end

    db.groups[gid] = nil

    if db.groupOrder then
        for i = #db.groupOrder, 1, -1 do
            if db.groupOrder[i] == gid then
                table.remove(db.groupOrder, i)
            end
        end
    end

    if MSWA.selectedGroupID == gid then
        MSWA.selectedGroupID = nil
    end
end

-----------------------------------------------------------
-- Aura → Group assignment
-----------------------------------------------------------

function MSWA_GetAuraGroup(key)
    local db = MSWA_GetDB()
    if db.auraGroups then return db.auraGroups[key] end
    return nil
end

function MSWA_SetAuraGroup(key, gid)
    local db = MSWA_GetDB()
    db.auraGroups = db.auraGroups or {}
    db.spellSettings = db.spellSettings or {}

    local s = db.spellSettings[key] or {}

    if gid and db.groups and db.groups[gid] then
        s.anchorFrame = nil
        local count = 0
        for _, g in pairs(db.auraGroups) do
            if g == gid then count = count + 1 end
        end
        local group = db.groups[gid]
        local size = group.size or MSWA.ICON_SIZE
        s.x = count * (size + MSWA.ICON_SPACE)
        s.y = 0
        s.width  = s.width  or size
        s.height = s.height or size
        db.auraGroups[key] = gid
    else
        local old = db.auraGroups[key]
        local group = old and db.groups and db.groups[old] or nil
        if group then
            s.x = (s.x or 0) + (group.x or 0)
            s.y = (s.y or 0) + (group.y or 0)
        end
        db.auraGroups[key] = nil
    end

    db.spellSettings[key] = s
end

-----------------------------------------------------------
-- Delete / rename helpers
-----------------------------------------------------------

function MSWA_DeleteAuraKey(key)
    if key == nil then return end
    local db = MSWA_GetDB()

    if MSWA_IsItemKey(key) then
        local itemID = MSWA_KeyToItemID(key)
        if itemID and db.trackedItems then db.trackedItems[itemID] = nil end
    else
        if db.trackedSpells then db.trackedSpells[key] = nil end
    end

    if db.spellSettings then db.spellSettings[key] = nil end
    if db.auraGroups    then db.auraGroups[key]    = nil end
    if db.customNames   then db.customNames[key]   = nil end

    if MSWA.selectedSpellID == key then
        MSWA.selectedSpellID = nil
    end
end

function MSWA_RequestFullRefresh()
    if type(MSWA_RefreshOptionsList) == "function" then
        MSWA_RefreshOptionsList()
    elseif type(_G.MSWA_RefreshOptionsList) == "function" then
        _G.MSWA_RefreshOptionsList()
    end
    if type(MSWA_RequestUpdateSpells) == "function" then
        MSWA_RequestUpdateSpells()
    elseif type(MSWA_UpdateSpells) == "function" then
        pcall(MSWA_UpdateSpells)
    elseif type(_G.MSWA_UpdateSpells) == "function" then
        pcall(_G.MSWA_UpdateSpells)
    end
end

-----------------------------------------------------------
-- StaticPopup dialogs (lazy-register once)
-----------------------------------------------------------

function MSWA_EnsureRenamePopups()
    if StaticPopupDialogs and not StaticPopupDialogs.MSWA_RENAME_AURA then
        StaticPopupDialogs.MSWA_RENAME_AURA = {
            text = "Rename Aura",
            button1 = ACCEPT,
            button2 = CANCEL,
            hasEditBox = true,
            maxLetters = 64,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            OnShow = function(self, data)
                local d = data or self.data
                local t = (d and d.defaultText) or ""
                self.editBox:SetText(t)
                self.editBox:HighlightText()
                self.editBox:SetFocus()
            end,
            OnAccept = function(self, data)
                local d = data or self.data
                if not d or d.key == nil then return end
                local db = MSWA_GetDB()
                db.customNames = db.customNames or {}
                local txt = (self.editBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if txt == "" then
                    db.customNames[d.key] = nil
                else
                    db.customNames[d.key] = txt
                end
                MSWA_RequestFullRefresh()
            end,
        }
    end

    if StaticPopupDialogs and not StaticPopupDialogs.MSWA_RENAME_GROUP then
        StaticPopupDialogs.MSWA_RENAME_GROUP = {
            text = "Rename Group",
            button1 = ACCEPT,
            button2 = CANCEL,
            hasEditBox = true,
            maxLetters = 64,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            OnShow = function(self, data)
                local d = data or self.data
                local t = (d and d.defaultText) or ""
                self.editBox:SetText(t)
                self.editBox:HighlightText()
                self.editBox:SetFocus()
            end,
            OnAccept = function(self, data)
                local d = data or self.data
                if not d or not d.groupID then return end
                local db = MSWA_GetDB()
                local g = db.groups and db.groups[d.groupID]
                if g then
                    local txt = (self.editBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if txt ~= "" then g.name = txt end
                end
                MSWA_RequestFullRefresh()
            end,
        }
    end
end

-----------------------------------------------------------
-- Context menu frame
-----------------------------------------------------------

function MSWA_GetContextMenuFrame()
    if not MSWA._contextMenuFrame then
        MSWA._contextMenuFrame = CreateFrame("Frame", "MSWA_ContextMenuFrame", UIParent, "UIDropDownMenuTemplate")
    end
    return MSWA._contextMenuFrame
end
