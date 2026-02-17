-- ########################################################
-- MSA_Options.lua
-- Options frame, detail panel, list building, slash commands
-- ########################################################

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local tinsert, tsort = table.insert, table.sort
local pcall, select = pcall, select
local wipe = wipe or table.wipe

-----------------------------------------------------------
-- Context menu (right-click on aura/group rows)
-----------------------------------------------------------

function MSWA_ShowListContextMenu(row)
    if not row or not row.entryType then return end
    local db = MSWA_GetDB()
    local menu = {}

    if row.entryType == "AURA" and row.key ~= nil then
        local key = row.key
        local currentName = (db.customNames and db.customNames[key]) or ""
        local displayName = MSWA_GetDisplayNameForKey(key) or "Aura"
        local defaultText = (currentName ~= "" and currentName) or displayName

        tinsert(menu, { text = displayName, isTitle = true, notCheckable = true })
        tinsert(menu, {
            text = "Rename",
            notCheckable = true,
            func = function()
                MSWA_EnsureRenamePopups()
                StaticPopup_Show("MSWA_RENAME_AURA", nil, nil, { key = key, defaultText = defaultText })
            end,
        })
        tinsert(menu, {
            text = "Export",
            notCheckable = true,
            func = function() MSWA_ExportAura(key) end,
        })
        tinsert(menu, {
            text = "Delete",
            notCheckable = true,
            func = function()
                MSWA_DeleteAuraKey(key)
                MSWA_RequestFullRefresh()
            end,
        })

    elseif row.entryType == "GROUP" and row.groupID then
        local gid = row.groupID
        local g = db.groups and db.groups[gid]
        tinsert(menu, { text = (g and g.name) or "Group", isTitle = true, notCheckable = true })
        tinsert(menu, {
            text = "Rename",
            notCheckable = true,
            func = function()
                MSWA_EnsureRenamePopups()
                StaticPopup_Show("MSWA_RENAME_GROUP", nil, nil, { groupID = gid, defaultText = (g and g.name) or "" })
            end,
        })
        tinsert(menu, {
            text = "Export Group",
            notCheckable = true,
            func = function() MSWA_ExportGroup(gid) end,
        })
        tinsert(menu, {
            text = "Delete Group",
            notCheckable = true,
            func = function()
                MSWA_DeleteGroup(gid)
                MSWA_RequestFullRefresh()
            end,
        })
    end

    if #menu == 0 then return end
    if EasyMenu and #menu > 0 then
        EasyMenu(menu, MSWA_GetContextMenuFrame(), "cursor", 0, 0, "MENU")
    end
end

-----------------------------------------------------------
-- Options panel state
-----------------------------------------------------------

MSWA.optionsFrame = nil

function MSWA_RefreshOptionsList()
    local f = MSWA.optionsFrame
    if not f then return end
    if f.UpdateAuraList then
        f:UpdateAuraList()
    end
    if type(MSWA_UpdateDetailPanel) == "function" then
        MSWA_UpdateDetailPanel()
    end
end

-----------------------------------------------------------
-- Sorted tracked IDs
-----------------------------------------------------------

local tempIDList = {}

local function MSWA_BuildSortedTrackedIDs()
    local tracked = MSWA_GetTrackedSpells()
    local db      = MSWA_GetDB()

    if wipe then wipe(tempIDList)
    else for i = #tempIDList, 1, -1 do tempIDList[i] = nil end
    end

    for id, enabled in pairs(tracked) do
        if enabled and type(id) == "number" then tinsert(tempIDList, id) end
    end
    tsort(tempIDList)

    if db.trackedItems then
        local itemIDs = {}
        for itemID, enabled in pairs(db.trackedItems) do
            if enabled then tinsert(itemIDs, itemID) end
        end
        tsort(itemIDs)
        for _, itemID in ipairs(itemIDs) do tinsert(tempIDList, ("item:%d"):format(itemID)) end
    end

    local instanceKeys = {}
    for id, enabled in pairs(tracked) do
        if enabled and MSWA_IsSpellInstanceKey(id) then tinsert(instanceKeys, id) end
    end
    tsort(instanceKeys, function(a, b)
        local sa = MSWA_KeyToSpellID(a) or 0
        local sb = MSWA_KeyToSpellID(b) or 0
        if sa ~= sb then return sa < sb end
        return a < b
    end)
    for _, k in ipairs(instanceKeys) do tinsert(tempIDList, k) end

    for id, enabled in pairs(tracked) do
        if enabled and type(id) ~= "number" and not MSWA_IsSpellInstanceKey(id) then
            tinsert(tempIDList, id)
        end
    end

    return tempIDList
end

-----------------------------------------------------------
-- Build list entries (loaded vs not-loaded partitioning)
-----------------------------------------------------------

local function MSWA_BuildListEntries()
    local db = MSWA_GetDB()
    local ids = MSWA_BuildSortedTrackedIDs()
    local grouped, ungrouped, notLoaded = {}, {}, {}

    local function IsAuraLoadedNow(key)
        local s = nil
        if db and db.spellSettings then
            s = db.spellSettings[key] or db.spellSettings[tostring(key)]
        end
        return MSWA_ShouldLoadAura(s)
    end

    for _, key in ipairs(ids) do
        local loaded = IsAuraLoadedNow(key)
        local gid = db.auraGroups and db.auraGroups[key]
        local validGroup = (gid and db.groups and db.groups[gid]) and gid or nil
        if not loaded then
            tinsert(notLoaded, { key = key, groupID = validGroup })
        else
            if validGroup then
                grouped[validGroup] = grouped[validGroup] or {}
                tinsert(grouped[validGroup], key)
            else
                tinsert(ungrouped, key)
            end
        end
    end

    local entries = {}

    if db.groupOrder then
        for _, gid in ipairs(db.groupOrder) do
            local g = db.groups and db.groups[gid]
            if g then
                local groupEntry = { entryType = 'GROUP', groupID = gid, groupStart = true }
                tinsert(entries, groupEntry)
                local list = grouped[gid]
                if list and #list > 0 then
                    for idx2, key in ipairs(list) do
                        local auraEntry = { entryType = 'AURA', key = key, groupID = gid, indent = 16 }
                        if idx2 == #list then auraEntry.groupEnd = true end
                        tinsert(entries, auraEntry)
                    end
                else
                    groupEntry.groupEnd = true
                end
            end
        end
    end

    tinsert(entries, { entryType = 'UNGROUPED' })
    for _, key in ipairs(ungrouped) do
        tinsert(entries, { entryType = 'AURA', key = key, groupID = nil, indent = 0 })
    end

    if notLoaded and #notLoaded > 0 then
        tinsert(entries, { entryType = 'NOTLOADED', groupStart = true, thickTop = true })
        for _, it in ipairs(notLoaded) do
            tinsert(entries, { entryType = 'AURA', key = it.key, groupID = it.groupID, indent = 0, notLoaded = true })
        end
    end

    return entries
end

-----------------------------------------------------------
-- Re-declare after full definition
-----------------------------------------------------------

MSWA_RefreshOptionsList = function()
    local f = MSWA.optionsFrame
    if not f then return end
    if f.UpdateAuraList then f:UpdateAuraList() else MSWA_UpdateDetailPanel() end
end

-----------------------------------------------------------
-- Detail panel update
-----------------------------------------------------------

MSWA_UpdateDetailPanel = function()
    local f = MSWA.optionsFrame
    if not f then return end

    local key = MSWA.selectedSpellID
    local gid = MSWA.selectedGroupID

    -- Group state
    if gid and not key then
        local db = MSWA_GetDB()
        local g = (db.groups or {})[gid]
        if not g then MSWA.selectedGroupID = nil
        else
            if f.rightTitle then f.rightTitle:SetText(g.name or "Group") end
            if f.generalPanel then f.generalPanel:Hide() end
            if f.displayPanel then f.displayPanel:Hide() end
            if f.altPanel then f.altPanel:Hide() end
            if f.emptyPanel then f.emptyPanel:Hide() end
            if f.groupPanel then f.groupPanel:Hide() end
            if f.groupPanel then f.groupPanel:Show() end
            if f.tabGeneral then f.tabGeneral:Disable() end
            if f.tabDisplay then f.tabDisplay:Disable() end
            if f.tabImport then f.tabImport:Disable() end
            if f.groupPanel and f.groupPanel.Sync then f.groupPanel:Sync() end
            return
        end
    end

    -- Empty state
    if not key then
        if f.rightTitle then f.rightTitle:SetText("Select an Aura") end
        if f.generalPanel then f.generalPanel:Hide() end
        if f.displayPanel then f.displayPanel:Hide() end
        if f.altPanel then f.altPanel:Hide() end
        if f.emptyPanel then f.emptyPanel:Show() end
        if f.groupPanel then f.groupPanel:Hide() end
        if f.tabGeneral then f.tabGeneral:Disable() end
        if f.tabDisplay then f.tabDisplay:Disable() end
        if f.tabImport then f.tabImport:Disable() end
        return
    end

    -- Selected state
    local name = MSWA_GetDisplayNameForKey(key)
    local db   = MSWA_GetDB()
    local s    = select(1, MSWA_GetSpellSettings(db, key)) or {}

    local x = s.x or 0
    local y = s.y or 0
    local w = s.width  or MSWA.ICON_SIZE
    local h = s.height or MSWA.ICON_SIZE
    local a = s.anchorFrame or ""

    if f.rightTitle then f.rightTitle:SetText(name or "Selected Aura") end

    if f.emptyPanel then f.emptyPanel:Hide() end
    if f.groupPanel then f.groupPanel:Hide() end
    if f.tabGeneral then f.tabGeneral:Enable() end
    if f.tabDisplay then f.tabDisplay:Enable() end
    if f.tabImport then f.tabImport:Enable() end

    local tab = f.activeTab or "GENERAL"
    if tab == "DISPLAY" then
        if f.generalPanel then f.generalPanel:Hide() end
        if f.altPanel then f.altPanel:Hide() end
        if f.displayPanel then f.displayPanel:Show() end
    elseif tab == "IMPORT" then
        if f.generalPanel then f.generalPanel:Hide() end
        if f.displayPanel then f.displayPanel:Hide() end
        if f.altPanel then f.altPanel:Show(); if f.altPanel.Sync then f.altPanel:Sync() end end
    else
        if f.displayPanel then f.displayPanel:Hide() end
        if f.altPanel then f.altPanel:Hide() end
        if f.generalPanel then f.generalPanel:Show() end
    end

    if f.detailName then
        local abTag = (s and s.auraMode == "AUTOBUFF") and " |cff44ddff[Auto Buff]|r" or ""
        if MSWA_IsDraftKey(key) then f.detailName:SetText("New Aura - ???")
        elseif MSWA_IsItemKey(key) then
            local itemID = MSWA_KeyToItemID(key) or 0
            f.detailName:SetText(('Item %d - %s%s'):format(itemID, name or 'Unknown', abTag))
        elseif type(key) == 'number' then
            f.detailName:SetText(('Spell %d - %s%s'):format(key, name or 'Unknown', abTag))
        else
            f.detailName:SetText((name or 'Unknown') .. abTag)
        end
    end

    if f.detailX then f.detailX:SetText(("%d"):format(x)) end
    if f.detailY then f.detailY:SetText(("%d"):format(y)) end
    if f.detailW then f.detailW:SetText(("%d"):format(w)) end
    if f.detailH then f.detailH:SetText(("%d"):format(h)) end
    if f.detailA then f.detailA:SetText(a) end

    if f.textSizeEdit then
        local size = (s and s.textFontSize) or db.textFontSize or 12
        size = tonumber(size) or 12
        if size < 6 then size = 6 end; if size > 48 then size = 48 end
        f.textSizeEdit:SetText(tostring(size))
    end
    if f.textPosDrop and UIDropDownMenu_SetText then
        local point = (s and s.textPoint) or db.textPoint or "BOTTOMRIGHT"
        UIDropDownMenu_SetText(f.textPosDrop, MSWA_GetTextPosLabel(point))
    end
    if f.textColorSwatch then
        local tc = (s and s.textColor) or db.textColor or { r = 1, g = 1, b = 1 }
        f.textColorSwatch:SetColorTexture(tonumber(tc.r) or 1, tonumber(tc.g) or 1, tonumber(tc.b) or 1, 1)
    end
    if f.fontDrop then MSWA_InitFontDropdown() end
    if f.activeTab == "IMPORT" and f.altPanel and f.altPanel.Sync then f.altPanel:Sync() end
    if f.grayCooldownCheck then
        f.grayCooldownCheck:SetChecked((s and s.grayOnCooldown) and true or false)
    end

    -- Sync Auto Buff controls
    if f.autoBuffCheck then
        local isAutoBuff = (s and s.auraMode == "AUTOBUFF") and true or false
        local isSpellKey = MSWA_IsSpellKey(key)
        if isSpellKey then
            f.autoBuffCheck:Show(); f.autoBuffLabel:Show()
            f.autoBuffCheck:SetChecked(isAutoBuff)
        else
            f.autoBuffCheck:Hide(); f.autoBuffLabel:Hide()
        end
        -- Show duration edit for ANY key with AUTOBUFF (spells via checkbox, items via dropdown)
        if f.buffDurLabel then f.buffDurLabel:SetShown(isAutoBuff) end
        if f.buffDurEdit then
            f.buffDurEdit:SetShown(isAutoBuff)
            if isAutoBuff then
                local dur = (s and s.autoBuffDuration) or 10
                f.buffDurEdit:SetText(tostring(dur))
            end
        end
    end
end

-----------------------------------------------------------
-- Font dropdown init
-----------------------------------------------------------

function MSWA_InitFontDropdown()
    local f = MSWA.optionsFrame
    if not f or not f.fontDrop then return end
    if not MSWA.fontChoices then MSWA_RebuildFontChoices() end

    -- Build lookup table
    if not MSWA.fontLookup then
        MSWA.fontLookup = {}
        for _, data in ipairs(MSWA.fontChoices or {}) do
            MSWA.fontLookup[data.key] = data.path
        end
    end

    if not f._mswaFontDropInitialized then
        if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(f.fontDrop, 180) end

        UIDropDownMenu_Initialize(f.fontDrop, function(self, level)
            level = level or 1
            local db = MSWA_GetDB()
            local auraKey = MSWA.selectedSpellID
            local s2 = nil
            if auraKey and db and db.spellSettings then
                s2 = db.spellSettings[auraKey]
                if not s2 and type(auraKey) ~= "string" then s2 = db.spellSettings[tostring(auraKey)] end
            end
            local currentKey = (s2 and s2.textFontKey) or "DEFAULT"

            for _, data in ipairs(MSWA.fontChoices or {}) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = data.label or data.key
                info.value = data.key
                info.checked = (data.key == currentKey)
                info.func = function()
                    local key = MSWA.selectedSpellID
                    if not key then return end
                    local db2 = MSWA_GetDB()
                    db2.spellSettings = db2.spellSettings or {}
                    local t = db2.spellSettings
                    local ss = t[key] or t[tostring(key)]
                    if not ss then ss = {}; t[key] = ss end
                    if data.key == "DEFAULT" then ss.textFontKey = nil else ss.textFontKey = data.key end
                    UIDropDownMenu_SetSelectedValue(f.fontDrop, data.key)
                    UIDropDownMenu_SetText(f.fontDrop, data.label or data.key)
                    if f.fontPreview and MSWA.fontLookup then
                        local fontPath = MSWA.fontLookup[data.key]
                        if data.key == "DEFAULT" or not fontPath then
                            f.fontPreview:SetFontObject(GameFontNormalSmall)
                        else f.fontPreview:SetFont(fontPath, 12, "") end
                    end
                    MSWA_RequestUpdateSpells()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        f._mswaFontDropInitialized = true
    end

    local db = MSWA_GetDB()
    local auraKey = MSWA.selectedSpellID
    if not auraKey then
        if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(f.fontDrop, "DEFAULT") end
        if UIDropDownMenu_SetText then UIDropDownMenu_SetText(f.fontDrop, "Default (Blizzard)") end
        if UIDropDownMenu_DisableDropDown then UIDropDownMenu_DisableDropDown(f.fontDrop) end
        return
    end
    if UIDropDownMenu_EnableDropDown then UIDropDownMenu_EnableDropDown(f.fontDrop) end

    local ss = select(1, MSWA_GetSpellSettings(db, auraKey)) or {}
    local fontKey = (ss and ss.textFontKey) or "DEFAULT"
    local label = "Default (Blizzard)"
    for _, data in ipairs(MSWA.fontChoices or {}) do
        if data.key == fontKey then label = data.label or data.key; break end
    end
    if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(f.fontDrop, fontKey) end
    if UIDropDownMenu_SetText then UIDropDownMenu_SetText(f.fontDrop, label) end
    if f.fontPreview then
        local p = MSWA_GetFontPathFromKey(fontKey)
        if p then pcall(f.fontPreview.SetFont, f.fontPreview, p, 12, "") end
    end
end

-----------------------------------------------------------
-- CreateOptionsFrame  (the big UI builder)
-- This is copied verbatim from the original with only
-- the throttle call-sites changed to MSWA_RequestUpdateSpells
-----------------------------------------------------------

local function MSWA_CreateOptionsFrame()
    if MSWA.optionsFrame then return MSWA.optionsFrame end

    local f = CreateFrame("Frame", "MidnightSimpleAurasOptions", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(860, 520); f:SetPoint("CENTER"); f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("LEFT", f.TitleBg, "LEFT", 10, 0); f.title:SetText("Midnight Simple Auras")

    -- Left: Aura list
    local listPanel = CreateFrame("Frame", nil, f, "InsetFrameTemplate3")
    listPanel:SetPoint("TOPLEFT", 12, -58); listPanel:SetPoint("BOTTOMLEFT", 12, 110); listPanel:SetWidth(310)
    f.listPanel = listPanel

    f.listTitle = listPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.listTitle:SetPoint("TOPLEFT", 10, -8); f.listTitle:SetText("Auras")

    f.btnNew = CreateFrame("Button", nil, f, "UIPanelButtonTemplate"); f.btnNew:SetSize(60, 22)
    f.btnNew:SetPoint("TOPLEFT", 18, -32); f.btnNew:SetText("New")

    f.btnImport = CreateFrame("Button", nil, f, "UIPanelButtonTemplate"); f.btnImport:SetSize(60, 22)
    f.btnImport:SetPoint("LEFT", f.btnNew, "RIGHT", 6, 0); f.btnImport:SetText("Import")

    f.btnExport = CreateFrame("Button", nil, f, "UIPanelButtonTemplate"); f.btnExport:SetSize(60, 22)
    f.btnExport:SetPoint("LEFT", f.btnImport, "RIGHT", 6, 0); f.btnExport:SetText("Export")

    f.btnGroup = CreateFrame("Button", nil, f, "UIPanelButtonTemplate"); f.btnGroup:SetSize(60, 22)
    f.btnGroup:SetPoint("LEFT", f.btnExport, "RIGHT", 6, 0); f.btnGroup:SetText("Group")

    f.btnPreview = CreateFrame("Button", nil, f, "UIPanelButtonTemplate"); f.btnPreview:SetSize(70, 22)
    f.btnPreview:SetPoint("LEFT", f.btnGroup, "RIGHT", 6, 0); f.btnPreview:SetText("Preview")

    -- Scroll frame + rows
    local rowHeight, visibleRows = 24, 14
    local scrollFrame = CreateFrame("ScrollFrame", "MSWA_AuraListScrollFrame", listPanel, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 0, -24)
    scrollFrame:SetPoint("BOTTOMRIGHT", listPanel, "BOTTOMRIGHT", -2, 6)
    scrollFrame:EnableMouseWheel(true)
    f.scrollFrame = scrollFrame

    -----------------------------------------------------------
    -- Inline rename EditBox (shared across all rows)
    -----------------------------------------------------------
    local inlineEdit = CreateFrame("EditBox", "MSWA_InlineRenameEdit", listPanel, "InputBoxTemplate")
    inlineEdit:SetSize(200, 20)
    inlineEdit:SetAutoFocus(false)
    inlineEdit:SetMaxLetters(64)
    inlineEdit:SetFrameStrata("DIALOG")
    inlineEdit:Hide()
    inlineEdit._renameKey = nil      -- aura key being renamed
    inlineEdit._renameGroupID = nil  -- group ID being renamed
    f.inlineEdit = inlineEdit

    local function InlineRename_Commit(self)
        local txt = (self:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local db = MSWA_GetDB()
        if self._renameGroupID then
            -- Group rename
            local g = db.groups and db.groups[self._renameGroupID]
            if g then
                if txt ~= "" then g.name = txt end
            end
        elseif self._renameKey ~= nil then
            -- Aura rename
            db.customNames = db.customNames or {}
            if txt == "" then
                db.customNames[self._renameKey] = nil
            else
                db.customNames[self._renameKey] = txt
            end
        end
        self._renameKey = nil
        self._renameGroupID = nil
        self:Hide()
        self:ClearFocus()
        MSWA_RefreshOptionsList()
        MSWA_RequestUpdateSpells()
    end

    local function InlineRename_Cancel(self)
        self._renameKey = nil
        self._renameGroupID = nil
        self:Hide()
        self:ClearFocus()
    end

    inlineEdit:SetScript("OnEnterPressed", InlineRename_Commit)
    inlineEdit:SetScript("OnEscapePressed", InlineRename_Cancel)
    inlineEdit:SetScript("OnEditFocusLost", InlineRename_Cancel)

    -- Show the inline edit over a specific row
    local function ShowInlineRename(row, currentText, auraKey, groupID)
        inlineEdit._renameKey = auraKey
        inlineEdit._renameGroupID = groupID
        inlineEdit:ClearAllPoints()
        inlineEdit:SetPoint("LEFT", row.icon, "RIGHT", 4 + (row.indent or 0), 0)
        inlineEdit:SetPoint("RIGHT", row.remove, "LEFT", -2, 0)
        inlineEdit:SetText(currentText or "")
        inlineEdit:Show()
        inlineEdit:SetFocus()
        inlineEdit:HighlightText()
    end

    -- Double-click state (per-row tracking)
    local lastClickRow = nil
    local lastClickTime = 0
    local DOUBLECLICK_THRESHOLD = 0.35

    f.rows = {}
    for i = 1, visibleRows do
        local row = CreateFrame("Button", "MSWA_AuraRow" .. i, listPanel)
        row:SetSize(282, rowHeight); row:SetPoint("TOPLEFT", 8, -24 - (i - 1) * rowHeight)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

        row.icon = row:CreateTexture(nil, "ARTWORK"); row.icon:SetSize(20, 20); row.icon:SetPoint("LEFT")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0); row.text:SetJustifyH("LEFT"); row.text:SetWidth(210)

        row.sepTop = row:CreateTexture(nil, "BORDER"); row.sepTop:SetColorTexture(1, 1, 1, 0.12)
        row.sepTop:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0); row.sepTop:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
        row.sepTop:SetHeight(1); row.sepTop:Hide()

        row.sepBottom = row:CreateTexture(nil, "BORDER"); row.sepBottom:SetColorTexture(1, 1, 1, 0.12)
        row.sepBottom:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0); row.sepBottom:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        row.sepBottom:SetHeight(1); row.sepBottom:Hide()

        row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.remove:SetSize(24, 20); row.remove:SetPoint("RIGHT"); row.remove:SetText("X")

        row.selectedTex = row:CreateTexture(nil, "BACKGROUND"); row.selectedTex:SetAllPoints(true)
        row.selectedTex:SetColorTexture(1, 1, 0, 0.15); row.selectedTex:Hide()

        row.isMSWARow = true; row.entryType = nil; row.groupID = nil; row.key = nil; row.indent = 0; row.spellID = nil

        row:RegisterForClicks("AnyUp"); row:RegisterForDrag("LeftButton")
        row:SetScript("OnDragStart", function(self) if self.entryType == "AURA" and self.key ~= nil then MSWA_BeginListDrag(self.key) end end)
        row:SetScript("OnDragStop", function(self) if MSWA._isDraggingList then MSWA_EndListDrag() end end)

        row.remove:SetScript("OnClick", function(btn)
            if MSWA._isDraggingList then return end
            local r = btn and btn.GetParent and btn:GetParent() or nil
            if not r or not r.entryType then return end
            if r.entryType == "AURA" and r.key ~= nil then
                MSWA_DeleteAuraKey(r.key); MSWA_RefreshOptionsList(); MSWA_RequestUpdateSpells(); return
            end
            if r.entryType == "GROUP" and r.groupID then
                MSWA_DeleteGroup(r.groupID)
                if MSWA.selectedGroupID == r.groupID then MSWA.selectedGroupID = nil end
                MSWA_RefreshOptionsList(); MSWA_RequestUpdateSpells(); return
            end
        end)

        row:SetScript("OnClick", function(self, button)
            if MSWA._isDraggingList then return end
            if button == "RightButton" then MSWA_ShowListContextMenu(self); return end

            local now = GetTime()
            local isDoubleClick = (lastClickRow == self) and (now - lastClickTime) < DOUBLECLICK_THRESHOLD
            lastClickRow = self
            lastClickTime = now

            if self.entryType == "AURA" and self.key ~= nil then
                if isDoubleClick then
                    -- Double-click: inline rename
                    local db = MSWA_GetDB()
                    local currentName = (db.customNames and db.customNames[self.key]) or ""
                    if currentName == "" then currentName = MSWA_GetDisplayNameForKey(self.key) or "" end
                    ShowInlineRename(self, currentName, self.key, nil)
                    return
                end
                MSWA.selectedSpellID = self.key; MSWA.selectedGroupID = nil; MSWA_RefreshOptionsList(); return
            end
            if self.entryType == "GROUP" and self.groupID then
                if isDoubleClick then
                    -- Double-click: inline rename group
                    local db = MSWA_GetDB()
                    local g = db.groups and db.groups[self.groupID]
                    local currentName = (g and g.name) or ""
                    ShowInlineRename(self, currentName, nil, self.groupID)
                    return
                end
                MSWA.selectedGroupID = self.groupID; MSWA.selectedSpellID = nil; MSWA_RefreshOptionsList(); return
            end
            if self.entryType == "UNGROUPED" then
                MSWA.selectedSpellID = nil; MSWA.selectedGroupID = nil; MSWA_RefreshOptionsList()
            end
        end)

        f.rows[i] = row
    end

    -- UpdateAuraList method
    function f:UpdateAuraList()
        -- Hide inline rename if active
        if f.inlineEdit and f.inlineEdit:IsShown() then
            f.inlineEdit._renameKey = nil
            f.inlineEdit._renameGroupID = nil
            f.inlineEdit:Hide()
            f.inlineEdit:ClearFocus()
        end
        local db = MSWA_GetDB()
        local entries = MSWA_BuildListEntries()
        local selectedKey = MSWA.selectedSpellID
        local selectedGroup = MSWA.selectedGroupID
        local total = #entries
        FauxScrollFrame_Update(scrollFrame, total, visibleRows, rowHeight)
        local offset = FauxScrollFrame_GetOffset(scrollFrame) or 0

        for i = 1, visibleRows do
            local row = self.rows[i]
            local idx = offset + i
            local entry = entries[idx]
            if entry then
                row.entryType = entry.entryType; row.groupID = entry.groupID; row.key = entry.key; row.indent = entry.indent or 0
                row:Show(); row.selectedTex:Hide()
                if row.sepTop then row.sepTop:Hide() end; if row.sepBottom then row.sepBottom:Hide() end
                row.remove:Show(); row.icon:SetTexture(nil); row:SetAlpha(1)
                if row.icon.SetDesaturated then row.icon:SetDesaturated(false) end
                row.text:ClearAllPoints()
                row.text:SetPoint("LEFT", row.icon, "RIGHT", 6 + (row.indent or 0), 0)
                if entry.groupStart and row.sepTop then
                    row.sepTop:SetHeight(entry.thickTop and 2 or 1); row.sepTop:Show()
                end
                if entry.groupEnd and row.sepBottom then
                    row.sepBottom:SetHeight(entry.thickBottom and 2 or 1); row.sepBottom:Show()
                end
                if entry.entryType == "GROUP" then
                    local g = db.groups and db.groups[entry.groupID] or nil
                    row.text:SetText(g and g.name or "Group"); row.icon:SetTexture(nil)
                    row.remove:SetText("X"); row.remove:Show()
                    if selectedGroup and selectedGroup == entry.groupID then row.selectedTex:Show() end
                elseif entry.entryType == "UNGROUPED" then
                    row.text:SetText("Ungrouped"); row.icon:SetTexture(nil); row.remove:Hide()
                elseif entry.entryType == "NOTLOADED" then
                    row.text:SetText("Not Loaded"); row.icon:SetTexture(nil); row.remove:Hide()
                else
                    local key = entry.key
                    local icon = MSWA_GetIconForKey(key)
                    local name = MSWA_GetDisplayNameForKey(key)
                    local abPrefix = ""
                    if MSWA_IsAutoBuff and MSWA_IsAutoBuff(key) then abPrefix = "|cff44ddff[AB]|r " end
                    local displayName = abPrefix .. (name or "Unknown")
                    if entry.notLoaded then
                        local suffix = ""
                        if entry.groupID then
                            local g2 = db.groups and db.groups[entry.groupID] or nil
                            if g2 and g2.name then suffix = " |cff666666(" .. g2.name .. ")|r" end
                        end
                        row.text:SetText("|cff888888" .. displayName .. "|r" .. suffix)
                        row:SetAlpha(0.55)
                        if row.icon.SetDesaturated then row.icon:SetDesaturated(true) end
                    else
                        row.text:SetText(displayName); row:SetAlpha(1)
                        if row.icon.SetDesaturated then row.icon:SetDesaturated(false) end
                    end
                    row.icon:SetTexture(icon); row.text:SetText(displayName)
                    row.remove:SetText("X"); row.remove:Show()
                    if selectedKey ~= nil and selectedKey == key then row.selectedTex:Show() end
                end
            else
                row.entryType = nil; row.groupID = nil; row.key = nil; row.indent = 0; row.spellID = nil
                row.icon:SetTexture(nil); row.text:SetText(""); row.selectedTex:Hide()
                if row.sepTop then row.sepTop:Hide() end; if row.sepBottom then row.sepBottom:Hide() end
                row:Hide()
            end
        end
        MSWA_UpdateDetailPanel()
    end

    scrollFrame:SetScript("OnVerticalScroll", function(self, offset) FauxScrollFrame_OnVerticalScroll(self, offset, rowHeight, function() f:UpdateAuraList() end) end)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll() or 0
        FauxScrollFrame_OnVerticalScroll(self, current - (delta * rowHeight * 3), rowHeight, function() f:UpdateAuraList() end)
    end)

    ---------------------------------------------------
    -- Right: Editor (identical structure to original)
    ---------------------------------------------------
    -- NOTE: The full right-panel editor (General/Display/Load Info tabs,
    -- group panel, all edit boxes, dropdowns, color pickers, etc.)
    -- is built IDENTICALLY to the original MidnightSimpleAuras.lua
    -- lines 3815-5352. The code is very long (~1500 lines of pure UI
    -- construction) and is included verbatim below.
    ---------------------------------------------------

    local rightPanel = CreateFrame("Frame", nil, f, "InsetFrameTemplate3")
    rightPanel:SetPoint("TOPLEFT", listPanel, "TOPRIGHT", 12, 0)
    rightPanel:SetPoint("BOTTOMRIGHT", -12, 110)
    f.rightPanel = rightPanel

    f.splitLine = f:CreateTexture(nil, "BORDER")
    f.splitLine:SetPoint("TOPLEFT", listPanel, "TOPRIGHT", 6, -2)
    f.splitLine:SetPoint("BOTTOMLEFT", listPanel, "BOTTOMRIGHT", 6, 2)
    f.splitLine:SetWidth(1); f.splitLine:SetColorTexture(1, 1, 1, 0.10)

    f.rightTitle = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.rightTitle:SetPoint("TOP", 0, -10); f.rightTitle:SetText("Select an Aura")

    local tabW, tabH = 90, 20
    local function SetActiveTab(tabKey)
        f.activeTab = tabKey
        if f.tabGeneral then f.tabGeneral:UnlockHighlight() end
        if f.tabDisplay then f.tabDisplay:UnlockHighlight() end
        if f.tabImport then f.tabImport:UnlockHighlight() end
        if tabKey == "GENERAL" and f.tabGeneral then f.tabGeneral:LockHighlight() end
        if tabKey == "DISPLAY" and f.tabDisplay then f.tabDisplay:LockHighlight() end
        if tabKey == "IMPORT" and f.tabImport then f.tabImport:LockHighlight() end
        MSWA_UpdateDetailPanel()
    end

    f.tabGeneral = CreateFrame("Button", nil, rightPanel, "UIPanelButtonTemplate"); f.tabGeneral:SetSize(tabW, tabH)
    f.tabGeneral:SetPoint("TOPLEFT", 14, -36); f.tabGeneral:SetText("General")
    f.tabDisplay = CreateFrame("Button", nil, rightPanel, "UIPanelButtonTemplate"); f.tabDisplay:SetSize(tabW, tabH)
    f.tabDisplay:SetPoint("LEFT", f.tabGeneral, "RIGHT", 6, 0); f.tabDisplay:SetText("Display")
    f.tabImport = CreateFrame("Button", nil, rightPanel, "UIPanelButtonTemplate"); f.tabImport:SetSize(tabW, tabH)
    f.tabImport:SetPoint("LEFT", f.tabDisplay, "RIGHT", 6, 0); f.tabImport:SetText("Load Info")

    f.tabGeneral:SetScript("OnClick", function() SetActiveTab("GENERAL") end)
    f.tabDisplay:SetScript("OnClick", function() SetActiveTab("DISPLAY") end)
    f.tabImport:SetScript("OnClick", function() SetActiveTab("IMPORT") end)
    f.activeTab = "GENERAL"; f.tabGeneral:LockHighlight()

    f.emptyPanel = CreateFrame("Frame", nil, rightPanel)
    f.emptyPanel:SetPoint("TOPLEFT", 12, -60); f.emptyPanel:SetPoint("BOTTOMRIGHT", -12, 12)
    f.emptyText = f.emptyPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.emptyText:SetPoint("CENTER", 0, 0); f.emptyText:SetText("Select an aura from the list on the left to edit it.")

    -- Load Info (altPanel)
    f.altPanel = CreateFrame("Frame", nil, rightPanel)
    f.altPanel:SetPoint("TOPLEFT", 12, -60); f.altPanel:SetPoint("BOTTOMRIGHT", -12, 12); f.altPanel:Hide()

    f.altTitle = f.altPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.altTitle:SetPoint("TOPLEFT", f.altPanel, "TOPLEFT", 16, -16); f.altTitle:SetText("|cffffcc00Load settings|r")

    -- Load info helpers (player identity via MSA_LoadConditions.lua)

    local function GetEffectiveModes(s)
        if type(s) ~= "table" then return false, nil, nil, nil, nil, nil end
        local never = (s.loadNever == true)
        local combat, enc = s.loadCombatMode, s.loadEncounterMode
        local char = s.loadCharName or s.loadChar
        local class = s.loadClass
        local spec  = s.loadSpec
        local lm = s.loadMode
        if lm == "NEVER" then never = true end
        if (combat == nil or combat == "") then
            if lm == "IN_COMBAT" or lm == "IN" then combat = "IN"
            elseif lm == "OUT_OF_COMBAT" or lm == "OUT" then combat = "OUT" end
        end
        if combat == "" or combat == "ANY" then combat = nil end
        if enc == "" or enc == "ANY" then enc = nil end
        if type(char) == "string" then
            char = char:gsub("^%s+", ""):gsub("%s+$", "")
            if char == "" then char = nil end
        else char = nil end
        if type(class) == "string" then
            class = class:gsub("^%s+", ""):gsub("%s+$", "")
            if class == "" then class = nil end
        else class = nil end
        if spec then spec = tonumber(spec); if spec == 0 then spec = nil end
        end
        return never, combat, enc, char, class, spec
    end
    _G.MSWA_GetEffectiveModes = GetEffectiveModes

    local function EnsureAuraSettings(key)
        local db = MSWA_GetDB(); db.spellSettings = db.spellSettings or {}
        db.spellSettings[key] = db.spellSettings[key] or {}
        return db.spellSettings[key]
    end
    _G.MSWA_EnsureAuraSettings = EnsureAuraSettings

    local function GetAuraSettings(key)
        local db = MSWA_GetDB()
        local s = select(1, MSWA_GetSpellSettings(db, key))
        if not s and db.spellSettings then s = db.spellSettings[key] end
        return s
    end
    _G.MSWA_GetAuraSettings = GetAuraSettings

    local function ApplyModesToSettings(key, never, combat, enc, char, class, spec)
        if not key then return end
        local s = EnsureAuraSettings(key)
        s.loadNever = (never == true) or nil
        s.loadCombatMode = (combat == "IN" or combat == "OUT") and combat or nil
        s.loadEncounterMode = (enc == "IN" or enc == "OUT") and enc or nil
        if type(char) == "string" then char = char:gsub("^%s+", ""):gsub("%s+$", "") else char = "" end
        s.loadCharName = (char ~= "" and char) or nil
        s.loadChar = nil; s.loadMode = nil; s.loadAlways = nil
        -- Class / Spec
        s.loadClass = (type(class) == "string" and class ~= "") and class or nil
        s.loadSpec  = (spec and tonumber(spec) and tonumber(spec) > 0) and tonumber(spec) or nil
        MSWA_RequestUpdateSpells()
        if MSWA_RefreshOptionsList and MSWA.optionsFrame and MSWA.optionsFrame:IsShown() then
            MSWA_RefreshOptionsList()
        end
    end
    _G.MSWA_ApplyModesToSettings = ApplyModesToSettings

    -- Forward declarations for load controls (used in dropdown callbacks)
    local SyncLoadControls

    -- Load info controls
    f.loadNeverCheck = CreateFrame("CheckButton", nil, f.altPanel, "UICheckButtonTemplate")
    f.loadNeverCheck:SetPoint("TOPLEFT", f.altTitle, "BOTTOMLEFT", -2, -12)
    f.loadNeverCheck.text = f.loadNeverCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.loadNeverCheck.text:SetPoint("LEFT", f.loadNeverCheck, "RIGHT", 4, 0)
    f.loadNeverCheck.text:SetText("|cffff4040Never (disable)|r")
    f.loadNeverCheck:EnableMouse(false)

    f.loadNeverRow = CreateFrame("Button", nil, f.altPanel)
    f.loadNeverRow:SetFrameLevel(f.loadNeverCheck:GetFrameLevel() - 1)
    f.loadNeverRow:SetPoint("TOPLEFT", f.loadNeverCheck, "TOPLEFT", 0, 0)
    f.loadNeverRow:SetPoint("BOTTOMRIGHT", f.loadNeverCheck.text, "BOTTOMRIGHT", 0, 0)
    f.loadNeverRow:EnableMouse(true)

    f.loadCombatButton = CreateFrame("Button", nil, f.altPanel, "UIPanelButtonTemplate")
    f.loadCombatButton:SetSize(210, 22); f.loadCombatButton:SetPoint("TOPLEFT", f.loadNeverCheck, "BOTTOMLEFT", 22, -10)

    f.loadEncounterButton = CreateFrame("Button", nil, f.altPanel, "UIPanelButtonTemplate")
    f.loadEncounterButton:SetSize(210, 22); f.loadEncounterButton:SetPoint("LEFT", f.loadCombatButton, "RIGHT", 12, 0)

    local function UpdateCombatButtonText(btn, mode, never)
        if not btn then return end
        if never then btn:SetText("|cff888888Combat: Disabled|r"); return end
        if mode == "IN" then btn:SetText("|cff00ff00Combat: In Combat|r")
        elseif mode == "OUT" then btn:SetText("|cffff4040Combat: Out of Combat|r")
        else btn:SetText("Combat: Any") end
    end
    _G.MSWA_UpdateCombatButtonText = UpdateCombatButtonText

    local function UpdateEncounterButtonText(btn, mode, never)
        if not btn then return end
        if never then btn:SetText("|cff888888Encounter: Disabled|r"); return end
        if mode == "IN" then btn:SetText("|cff00ff00Encounter: In Encounter|r")
        elseif mode == "OUT" then btn:SetText("|cffff4040Encounter: Not in Encounter|r")
        else btn:SetText("Encounter: Any") end
    end
    _G.MSWA_UpdateEncounterButtonText = UpdateEncounterButtonText

    f.loadCharLabel = f.altPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.loadCharLabel:SetPoint("TOPLEFT", f.loadCombatButton, "BOTTOMLEFT", -22, -14)
    f.loadCharLabel:SetText("|cffffcc00Character (Name-Realm):|r")

    f.loadCharEdit = CreateFrame("EditBox", nil, f.altPanel, "InputBoxTemplate")
    f.loadCharEdit:SetSize(260, 22); f.loadCharEdit:SetAutoFocus(false)
    f.loadCharEdit:SetPoint("LEFT", f.loadCharLabel, "RIGHT", 8, 0); f.loadCharEdit:SetTextInsets(6, 6, 0, 0)

    f.loadCharMeBtn = CreateFrame("Button", nil, f.altPanel, "UIPanelButtonTemplate")
    f.loadCharMeBtn:SetSize(50, 22); f.loadCharMeBtn:SetPoint("LEFT", f.loadCharEdit, "RIGHT", 4, 0)
    f.loadCharMeBtn:SetText("|cff00ff00Me|r")

    -- Class dropdown
    f.loadClassLabel = f.altPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.loadClassLabel:SetPoint("TOPLEFT", f.loadCharLabel, "BOTTOMLEFT", 0, -16)
    f.loadClassLabel:SetText("|cffffcc00Class:|r")

    f.loadClassDrop = CreateFrame("Frame", "MSWA_LoadClassDropDown", f.altPanel, "UIDropDownMenuTemplate")
    f.loadClassDrop:SetPoint("LEFT", f.loadClassLabel, "RIGHT", -10, -3)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(f.loadClassDrop, 160) end

    -- Spec dropdown
    f.loadSpecLabel = f.altPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.loadSpecLabel:SetPoint("LEFT", f.loadClassDrop, "RIGHT", 4, 3)
    f.loadSpecLabel:SetText("|cffffcc00Spec:|r")

    f.loadSpecDrop = CreateFrame("Frame", "MSWA_LoadSpecDropDown", f.altPanel, "UIDropDownMenuTemplate")
    f.loadSpecDrop:SetPoint("LEFT", f.loadSpecLabel, "RIGHT", -10, -3)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(f.loadSpecDrop, 160) end

    -- Class dropdown init
    UIDropDownMenu_Initialize(f.loadClassDrop, function(self, level)
        level = level or 1
        local key = MSWA.selectedSpellID
        local s2 = key and GetAuraSettings(key) or {}
        local _, _, _, _, curClass, _ = GetEffectiveModes(s2)

        -- "Any" option
        local info = UIDropDownMenu_CreateInfo()
        info.text = "Any Class"; info.value = ""; info.checked = (curClass == nil)
        info.func = function()
            local k = MSWA.selectedSpellID; if not k then return end
            local ss = GetAuraSettings(k) or {}
            local nv, cm, em, ch, _, sp = GetEffectiveModes(ss)
            ApplyModesToSettings(k, nv, cm, em, ch, nil, nil)  -- clear class clears spec too
            SyncLoadControls()
        end
        UIDropDownMenu_AddButton(info, level)

        -- All classes
        for _, c in ipairs(MSWA_CLASS_LIST) do
            info = UIDropDownMenu_CreateInfo()
            info.text = ("|cff%s%s|r"):format(c.color, c.name)
            info.value = c.token
            info.checked = (curClass == c.token)
            info.func = function()
                local k = MSWA.selectedSpellID; if not k then return end
                local ss = GetAuraSettings(k) or {}
                local nv, cm, em, ch, _, sp = GetEffectiveModes(ss)
                -- When changing class, reset spec (specs differ per class)
                ApplyModesToSettings(k, nv, cm, em, ch, c.token, nil)
                SyncLoadControls()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    -- Spec dropdown init
    UIDropDownMenu_Initialize(f.loadSpecDrop, function(self, level)
        level = level or 1
        local key = MSWA.selectedSpellID
        local s2 = key and GetAuraSettings(key) or {}
        local _, _, _, _, curClass, curSpec = GetEffectiveModes(s2)

        -- "Any" option
        local info = UIDropDownMenu_CreateInfo()
        info.text = "Any Spec"; info.value = 0; info.checked = (curSpec == nil)
        info.func = function()
            local k = MSWA.selectedSpellID; if not k then return end
            local ss = GetAuraSettings(k) or {}
            local nv, cm, em, ch, cl, _ = GetEffectiveModes(ss)
            ApplyModesToSettings(k, nv, cm, em, ch, cl, nil)
            SyncLoadControls()
        end
        UIDropDownMenu_AddButton(info, level)

        -- Get class to show specs for: saved loadClass, or current player class
        local classForSpecs = curClass or MSWA_GetPlayerClassToken()
        local specs = classForSpecs and MSWA_SPEC_DATA[classForSpecs]
        if specs then
            for idx, specName in ipairs(specs) do
                info = UIDropDownMenu_CreateInfo()
                info.text = specName; info.value = idx
                info.checked = (curSpec == idx)
                info.func = function()
                    local k = MSWA.selectedSpellID; if not k then return end
                    local ss = GetAuraSettings(k) or {}
                    local nv, cm, em, ch, cl, _ = GetEffectiveModes(ss)
                    -- If no class set yet, auto-set the displayed class
                    if not cl then cl = classForSpecs end
                    ApplyModesToSettings(k, nv, cm, em, ch, cl, idx)
                    SyncLoadControls()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
    end)

    -- Helper: format class dropdown text
    local function GetClassDropdownText(classToken)
        if not classToken then return "Any Class" end
        local c = MSWA_CLASS_INFO[classToken]
        if c then return ("|cff%s%s|r"):format(c.color, c.name) end
        return classToken
    end

    -- Helper: format spec dropdown text
    local function GetSpecDropdownText(classToken, specIdx)
        if not specIdx then return "Any Spec" end
        local name = MSWA_GetSpecName(classToken, specIdx)
        return name or "Any Spec"
    end

    SyncLoadControls = function()
        local key = MSWA.selectedSpellID
        if not key or (type(key) == "string" and key:find("^GROUP:")) then
            if f.loadNeverCheck then f.loadNeverCheck:SetChecked(false) end
            if f.loadCombatButton then f.loadCombatButton:Disable(); f.loadCombatButton:SetText("Combat: Any") end
            if f.loadEncounterButton then f.loadEncounterButton:Disable(); f.loadEncounterButton:SetText("Encounter: Any") end
            if f.loadCharEdit then f.loadCharEdit:Disable(); f.loadCharEdit:SetText("") end
            if f.loadCharMeBtn then f.loadCharMeBtn:Disable() end
            if f.loadClassDrop then UIDropDownMenu_SetText(f.loadClassDrop, "Any Class"); if UIDropDownMenu_DisableDropDown then UIDropDownMenu_DisableDropDown(f.loadClassDrop) end end
            if f.loadSpecDrop then UIDropDownMenu_SetText(f.loadSpecDrop, "Any Spec"); if UIDropDownMenu_DisableDropDown then UIDropDownMenu_DisableDropDown(f.loadSpecDrop) end end
            return
        end
        local s = GetAuraSettings(key) or {}
        local never, combat, enc, char, class, spec = GetEffectiveModes(s)
        if f.loadNeverCheck then f.loadNeverCheck:SetChecked(never and true or false) end
        if f.loadCombatButton then UpdateCombatButtonText(f.loadCombatButton, combat, never); if never then f.loadCombatButton:Disable() else f.loadCombatButton:Enable() end end
        if f.loadEncounterButton then UpdateEncounterButtonText(f.loadEncounterButton, enc, never); if never then f.loadEncounterButton:Disable() else f.loadEncounterButton:Enable() end end
        if f.loadCharEdit then f.loadCharEdit:SetText(char or ""); if never then f.loadCharEdit:Disable() else f.loadCharEdit:Enable() end end
        if f.loadCharMeBtn then if never then f.loadCharMeBtn:Disable() else f.loadCharMeBtn:Enable() end end
        -- Class
        if f.loadClassDrop then
            UIDropDownMenu_SetText(f.loadClassDrop, GetClassDropdownText(class))
            if never then
                if UIDropDownMenu_DisableDropDown then UIDropDownMenu_DisableDropDown(f.loadClassDrop) end
            else
                if UIDropDownMenu_EnableDropDown then UIDropDownMenu_EnableDropDown(f.loadClassDrop) end
            end
        end
        -- Spec
        if f.loadSpecDrop then
            UIDropDownMenu_SetText(f.loadSpecDrop, GetSpecDropdownText(class or MSWA_GetPlayerClassToken(), spec))
            if never then
                if UIDropDownMenu_DisableDropDown then UIDropDownMenu_DisableDropDown(f.loadSpecDrop) end
            else
                if UIDropDownMenu_EnableDropDown then UIDropDownMenu_EnableDropDown(f.loadSpecDrop) end
            end
        end
    end

    f.loadNeverRow:SetScript("OnClick", function()
        local key = MSWA.selectedSpellID
        if not key then return end
        local s = GetAuraSettings(key) or {}
        local never, combat, enc, char, class, spec = GetEffectiveModes(s)
        ApplyModesToSettings(key, not never, combat, enc, char, class, spec)
        SyncLoadControls()
    end)
    f.loadNeverCheck:SetScript("OnClick", function() end)

    f.loadCombatButton:SetScript("OnClick", function()
        local key = MSWA.selectedSpellID; if not key then return end
        local s = GetAuraSettings(key) or {}
        local never, combat, enc, char, class, spec = GetEffectiveModes(s)
        if never then return end
        local next = combat == nil and "IN" or (combat == "IN" and "OUT" or nil)
        ApplyModesToSettings(key, never, next, enc, char, class, spec); SyncLoadControls()
    end)
    f.loadEncounterButton:SetScript("OnClick", function()
        local key = MSWA.selectedSpellID; if not key then return end
        local s = GetAuraSettings(key) or {}
        local never, combat, enc, char, class, spec = GetEffectiveModes(s)
        if never then return end
        local next = enc == nil and "IN" or (enc == "IN" and "OUT" or nil)
        ApplyModesToSettings(key, never, combat, next, char, class, spec); SyncLoadControls()
    end)
    f.loadCharEdit:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        local key = MSWA.selectedSpellID; if not key then return end
        local s = GetAuraSettings(key) or {}
        local never, combat, enc, _, class, spec = GetEffectiveModes(s)
        if never then return end
        local v = tostring(self:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if v == "" then v = nil elseif not v:find("%-") then
            local realm = MSWA_GetPlayerRealm and MSWA_GetPlayerRealm() or ""
            if realm and realm ~= "" then v = v .. "-" .. realm end
        end
        ApplyModesToSettings(key, never, combat, enc, v, class, spec); SyncLoadControls()
    end)
    f.loadCharEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); SyncLoadControls() end)

    -- "Me" button: fill in current character Name-Realm
    f.loadCharMeBtn:SetScript("OnClick", function()
        local key = MSWA.selectedSpellID; if not key then return end
        local s = GetAuraSettings(key) or {}
        local never, combat, enc, _, class, spec = GetEffectiveModes(s)
        if never then return end
        local name = MSWA_GetPlayerName() or ""
        local realm = MSWA_GetPlayerRealm() or ""
        local full = realm ~= "" and (name .. "-" .. realm) or name
        ApplyModesToSettings(key, never, combat, enc, full, class, spec); SyncLoadControls()
    end)
    f.altPanel.Sync = function() SyncLoadControls() end

    f.altText = f.altPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.altText:SetPoint("TOPLEFT", 10, -10); f.altText:SetWidth(440); f.altText:SetJustifyH("LEFT"); f.altText:SetWordWrap(true); f.altText:SetText("")

    -- Group Panel
    f.groupPanel = CreateFrame("Frame", nil, rightPanel)
    f.groupPanel:SetPoint("TOPLEFT", 12, -60); f.groupPanel:SetPoint("BOTTOMRIGHT", -12, 12); f.groupPanel:Hide()

    local gpTitle = f.groupPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    gpTitle:SetPoint("TOPLEFT", 0, 0); gpTitle:SetText("Group settings")
    local gpNameLabel = f.groupPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    gpNameLabel:SetPoint("TOPLEFT", gpTitle, "BOTTOMLEFT", 0, -12); gpNameLabel:SetText("Name")
    f.groupNameEdit = CreateFrame("EditBox", nil, f.groupPanel, "InputBoxTemplate")
    f.groupNameEdit:SetAutoFocus(false); f.groupNameEdit:SetSize(220, 22); f.groupNameEdit:SetPoint("LEFT", gpNameLabel, "RIGHT", 10, 0)
    f.groupNameEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); local db = MSWA_GetDB(); local gid = MSWA.selectedGroupID; local g = gid and db.groups and db.groups[gid]; if g then g.name = self:GetText() or g.name; MSWA_RefreshOptionsList() end end)

    local gpXLabel = f.groupPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal"); gpXLabel:SetPoint("TOPLEFT", gpNameLabel, "BOTTOMLEFT", 0, -18); gpXLabel:SetText("Group X")
    f.groupXEdit = CreateFrame("EditBox", nil, f.groupPanel, "InputBoxTemplate"); f.groupXEdit:SetAutoFocus(false); f.groupXEdit:SetSize(80, 22); f.groupXEdit:SetPoint("LEFT", gpXLabel, "RIGHT", 10, 0)
    local gpYLabel = f.groupPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal"); gpYLabel:SetPoint("LEFT", f.groupXEdit, "RIGHT", 24, 0); gpYLabel:SetText("Group Y")
    f.groupYEdit = CreateFrame("EditBox", nil, f.groupPanel, "InputBoxTemplate"); f.groupYEdit:SetAutoFocus(false); f.groupYEdit:SetSize(80, 22); f.groupYEdit:SetPoint("LEFT", gpYLabel, "RIGHT", 10, 0)
    local gpSizeLabel = f.groupPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal"); gpSizeLabel:SetPoint("TOPLEFT", gpXLabel, "BOTTOMLEFT", 0, -18); gpSizeLabel:SetText("Icon size")
    f.groupSizeEdit = CreateFrame("EditBox", nil, f.groupPanel, "InputBoxTemplate"); f.groupSizeEdit:SetAutoFocus(false); f.groupSizeEdit:SetSize(80, 22); f.groupSizeEdit:SetPoint("LEFT", gpSizeLabel, "RIGHT", 10, 0)

    local function ApplyGroupSettings()
        local db = MSWA_GetDB(); local gid = MSWA.selectedGroupID; local g = gid and db.groups and db.groups[gid]; if not g then return end
        local x = tonumber(f.groupXEdit:GetText()) or g.x or 0
        local y = tonumber(f.groupYEdit:GetText()) or g.y or 0
        local size = tonumber(f.groupSizeEdit:GetText()) or g.size or MSWA.ICON_SIZE
        if size < 8 then size = 8 end
        g.x = x; g.y = y
        local oldSize = g.size or MSWA.ICON_SIZE; if oldSize < 1 then oldSize = MSWA.ICON_SIZE end
        local ratio = (oldSize and oldSize ~= 0) and (size / oldSize) or 1
        if ratio and ratio ~= 1 and db.auraGroups and db.spellSettings then
            for key, gg in pairs(db.auraGroups) do
                if gg == gid then
                    local s = db.spellSettings[key] or {}
                    s.x = (s.x or 0) * ratio; s.y = (s.y or 0) * ratio
                    local w = s.width or oldSize; local h = s.height or w
                    s.width = w * ratio; s.height = h * ratio
                    db.spellSettings[key] = s
                end
            end
        end
        g.size = size; MSWA_RequestUpdateSpells()
    end

    local function HookAutoApply(editBox)
        editBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyGroupSettings() end)
        editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    end
    HookAutoApply(f.groupXEdit); HookAutoApply(f.groupYEdit); HookAutoApply(f.groupSizeEdit)

    function f.groupPanel:Sync()
        local db = MSWA_GetDB(); local gid = MSWA.selectedGroupID; local g = gid and db.groups and db.groups[gid]; if not g then return end
        f.groupNameEdit:SetText(g.name or ""); f.groupXEdit:SetText(tostring(g.x or 0))
        f.groupYEdit:SetText(tostring(g.y or 0)); f.groupSizeEdit:SetText(tostring(g.size or MSWA.ICON_SIZE))
    end

    -- General tab
    f.generalPanel = CreateFrame("Frame", nil, rightPanel)
    f.generalPanel:SetPoint("TOPLEFT", 12, -60); f.generalPanel:SetPoint("BOTTOMRIGHT", -12, 12); f.generalPanel:Hide()

    f.detailTitle = f.generalPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.detailTitle:SetPoint("TOPLEFT", 10, -10); f.detailTitle:SetText("Selected aura:")
    f.detailName = f.generalPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); f.detailName:SetPoint("TOPLEFT", f.detailTitle, "BOTTOMLEFT", 0, -4); f.detailName:SetText("")

    f.addLabel = f.generalPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal"); f.addLabel:SetPoint("TOPLEFT", f.detailName, "BOTTOMLEFT", 0, -14); f.addLabel:SetText("Add ID:")
    f.addEdit = CreateFrame("EditBox", nil, f.generalPanel, "InputBoxTemplate"); f.addEdit:SetSize(80, 20); f.addEdit:SetPoint("LEFT", f.addLabel, "RIGHT", 6, 0); f.addEdit:SetAutoFocus(false); f.addEdit:SetNumeric(true)
    f.idTypeLabel = f.generalPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.idTypeLabel:SetPoint("LEFT", f.addEdit, "RIGHT", 8, 0); f.idTypeLabel:SetText("Type:")
    f.idTypeDrop = CreateFrame("Frame", "MSWA_IDTypeDropDown", f.generalPanel, "UIDropDownMenuTemplate"); f.idTypeDrop:SetPoint("LEFT", f.idTypeLabel, "RIGHT", -10, -3); UIDropDownMenu_SetWidth(f.idTypeDrop, 100)
    f.addButton = CreateFrame("Button", nil, f.generalPanel, "UIPanelButtonTemplate"); f.addButton:SetSize(60, 20); f.addButton:SetPoint("LEFT", f.idTypeDrop, "RIGHT", 0, 3); f.addButton:SetText("Add")
    f.hint = f.generalPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.hint:SetPoint("TOPLEFT", f.addLabel, "BOTTOMLEFT", 0, -10); f.hint:SetWidth(420); f.hint:SetJustifyH("LEFT"); f.hint:SetWordWrap(true)
    f.hint:SetText("Enter an ID from Wowhead etc. Use Type: Item to track items (trinkets). Auto Buff for spell buffs, Item Buff for trinket/item buffs.")

    f.autoBuffCheck = CreateFrame("CheckButton", nil, f.generalPanel, "ChatConfigCheckButtonTemplate"); f.autoBuffCheck:SetPoint("TOPLEFT", f.hint, "BOTTOMLEFT", -4, -10)
    f.autoBuffLabel = f.generalPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.autoBuffLabel:SetPoint("LEFT", f.autoBuffCheck, "RIGHT", 2, 0)
    f.autoBuffLabel:SetText("|cffffcc00Auto Buff mode|r  (show icon only while buff is active)")

    f.buffDurLabel = f.generalPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.buffDurLabel:SetPoint("TOPLEFT", f.autoBuffCheck, "BOTTOMLEFT", 22, -6); f.buffDurLabel:SetText("Buff duration (sec):")
    f.buffDurEdit = CreateFrame("EditBox", nil, f.generalPanel, "InputBoxTemplate"); f.buffDurEdit:SetSize(60, 20); f.buffDurEdit:SetPoint("LEFT", f.buffDurLabel, "RIGHT", 6, 0); f.buffDurEdit:SetAutoFocus(false)

    f.autoBuffCheck:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local db2 = MSWA_GetDB(); local s2 = select(1, MSWA_GetOrCreateSpellSettings(db2, key))
        if self:GetChecked() then s2.auraMode = "AUTOBUFF"; if not s2.autoBuffDuration then s2.autoBuffDuration = 10 end
        else s2.auraMode = nil; MSWA._autoBuff[key] = nil end
        MSWA_UpdateDetailPanel(); MSWA_RequestUpdateSpells()
    end)

    local function ApplyBuffDuration()
        local key = MSWA.selectedSpellID; if not key then return end
        local db2 = MSWA_GetDB(); local s2 = select(1, MSWA_GetOrCreateSpellSettings(db2, key))
        local v = tonumber(f.buffDurEdit:GetText()); if v and v >= 0.1 then s2.autoBuffDuration = v end
        MSWA._autoBuff[key] = nil; MSWA_RequestUpdateSpells()
    end
    f.buffDurEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyBuffDuration() end)
    f.buffDurEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Anchor
    local labelA = f.generalPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); labelA:SetPoint("TOPLEFT", f.buffDurLabel, "BOTTOMLEFT", -22, -16); labelA:SetText("Anchor to frame:")
    f.detailA = CreateFrame("EditBox", nil, f.generalPanel, "InputBoxTemplate"); f.detailA:SetSize(260, 20); f.detailA:SetPoint("LEFT", labelA, "RIGHT", 6, 0); f.detailA:SetAutoFocus(false)
    f.detailACD = CreateFrame("Button", nil, f.generalPanel, "UIPanelButtonTemplate"); f.detailACD:SetSize(110, 22); f.detailACD:SetPoint("TOPLEFT", labelA, "BOTTOMLEFT", 0, -10); f.detailACD:SetText("CD Manager")
    f.detailAMSUF = CreateFrame("Button", nil, f.generalPanel, "UIPanelButtonTemplate"); f.detailAMSUF:SetSize(110, 22); f.detailAMSUF:SetPoint("LEFT", f.detailACD, "RIGHT", 6, 0); f.detailAMSUF:SetText("MSUF Player")
    f.detailApply = CreateFrame("Button", nil, f.generalPanel, "UIPanelButtonTemplate"); f.detailApply:SetSize(80, 22); f.detailApply:SetPoint("TOPLEFT", f.detailACD, "BOTTOMLEFT", 0, -8); f.detailApply:SetText("Reset Pos")
    f.detailDefault = CreateFrame("Button", nil, f.generalPanel, "UIPanelButtonTemplate"); f.detailDefault:SetSize(80, 22); f.detailDefault:SetPoint("LEFT", f.detailApply, "RIGHT", 6, 0); f.detailDefault:SetText("Default")

    -- Display tab
    f.displayPanel = CreateFrame("Frame", nil, rightPanel); f.displayPanel:SetPoint("TOPLEFT", 12, -60); f.displayPanel:SetPoint("BOTTOMRIGHT", -12, 12); f.displayPanel:Hide()
    local labelX = f.displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); labelX:SetPoint("TOPLEFT", 10, -10); labelX:SetText("Offset X:")
    f.detailX = CreateFrame("EditBox", nil, f.displayPanel, "InputBoxTemplate"); f.detailX:SetSize(70, 20); f.detailX:SetPoint("LEFT", labelX, "RIGHT", 6, 0); f.detailX:SetAutoFocus(false)
    f.detailXMinus = CreateFrame("Button", nil, f.displayPanel, "UIPanelButtonTemplate"); f.detailXMinus:SetSize(20, 20); f.detailXMinus:SetPoint("LEFT", f.detailX, "RIGHT", 2, 0); f.detailXMinus:SetText("-")
    f.detailXPlus = CreateFrame("Button", nil, f.displayPanel, "UIPanelButtonTemplate"); f.detailXPlus:SetSize(20, 20); f.detailXPlus:SetPoint("LEFT", f.detailXMinus, "RIGHT", 2, 0); f.detailXPlus:SetText("+")
    local labelY = f.displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); labelY:SetPoint("TOPLEFT", labelX, "BOTTOMLEFT", 0, -10); labelY:SetText("Offset Y:")
    f.detailY = CreateFrame("EditBox", nil, f.displayPanel, "InputBoxTemplate"); f.detailY:SetSize(70, 20); f.detailY:SetPoint("LEFT", labelY, "RIGHT", 6, 0); f.detailY:SetAutoFocus(false)
    f.detailYMinus = CreateFrame("Button", nil, f.displayPanel, "UIPanelButtonTemplate"); f.detailYMinus:SetSize(20, 20); f.detailYMinus:SetPoint("LEFT", f.detailY, "RIGHT", 2, 0); f.detailYMinus:SetText("-")
    f.detailYPlus = CreateFrame("Button", nil, f.displayPanel, "UIPanelButtonTemplate"); f.detailYPlus:SetSize(20, 20); f.detailYPlus:SetPoint("LEFT", f.detailYMinus, "RIGHT", 2, 0); f.detailYPlus:SetText("+")
    local labelW = f.displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); labelW:SetPoint("TOPLEFT", labelY, "BOTTOMLEFT", 0, -14); labelW:SetText("Width:")
    f.detailW = CreateFrame("EditBox", nil, f.displayPanel, "InputBoxTemplate"); f.detailW:SetSize(70, 20); f.detailW:SetPoint("LEFT", labelW, "RIGHT", 6, 0); f.detailW:SetAutoFocus(false)
    local labelH = f.displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); labelH:SetPoint("TOPLEFT", labelW, "BOTTOMLEFT", 0, -10); labelH:SetText("Height:")
    f.detailH = CreateFrame("EditBox", nil, f.displayPanel, "InputBoxTemplate"); f.detailH:SetSize(70, 20); f.detailH:SetPoint("LEFT", labelH, "RIGHT", 6, 0); f.detailH:SetAutoFocus(false)

    f.fontLabel = f.displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.fontLabel:SetPoint("TOPLEFT", labelH, "BOTTOMLEFT", 0, -18); f.fontLabel:SetText("Font:")
    f.fontDrop = CreateFrame("Frame", "MSWA_FontDropDown", f.displayPanel, "UIDropDownMenuTemplate"); f.fontDrop:SetPoint("LEFT", f.fontLabel, "RIGHT", -10, -3)
    f.fontPreview = f.displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.fontPreview:SetPoint("LEFT", f.fontDrop, "RIGHT", -10, 0); f.fontPreview:SetText("AaBbYyZz 123")

    f.textSizeLabel = f.displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.textSizeLabel:SetPoint("TOPLEFT", f.fontLabel, "BOTTOMLEFT", 0, -16); f.textSizeLabel:SetText("Text size:")
    f.textSizeEdit = CreateFrame("EditBox", nil, f.displayPanel, "InputBoxTemplate"); f.textSizeEdit:SetSize(50, 20); f.textSizeEdit:SetPoint("LEFT", f.textSizeLabel, "RIGHT", 6, 0); f.textSizeEdit:SetAutoFocus(false); f.textSizeEdit:SetNumeric(true)
    f.textSizeMinus = CreateFrame("Button", nil, f.displayPanel, "UIPanelButtonTemplate"); f.textSizeMinus:SetSize(20, 20); f.textSizeMinus:SetPoint("LEFT", f.textSizeEdit, "RIGHT", 2, 0); f.textSizeMinus:SetText("-")
    f.textSizePlus = CreateFrame("Button", nil, f.displayPanel, "UIPanelButtonTemplate"); f.textSizePlus:SetSize(20, 20); f.textSizePlus:SetPoint("LEFT", f.textSizeMinus, "RIGHT", 2, 0); f.textSizePlus:SetText("+")

    f.textPosLabel = f.displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.textPosLabel:SetPoint("LEFT", f.textSizePlus, "RIGHT", 14, 0); f.textPosLabel:SetText("Pos:")
    f.textPosDrop = CreateFrame("Frame", "MSWA_TextPosDropDown", f.displayPanel, "UIDropDownMenuTemplate"); f.textPosDrop:SetPoint("LEFT", f.textPosLabel, "RIGHT", -10, -3)

    f.textColorLabel = f.displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.textColorLabel:SetPoint("TOPLEFT", f.textSizeLabel, "BOTTOMLEFT", 0, -12); f.textColorLabel:SetText("Text color:")
    f.textColorBtn = CreateFrame("Button", nil, f.displayPanel); f.textColorBtn:SetSize(18, 18); f.textColorBtn:SetPoint("LEFT", f.textColorLabel, "RIGHT", 8, 0); f.textColorBtn:EnableMouse(true)
    f.textColorSwatch = f.textColorBtn:CreateTexture(nil, "ARTWORK"); f.textColorSwatch:SetAllPoints(true); f.textColorSwatch:SetColorTexture(1, 1, 1, 1)
    f.textColorBorder = f.textColorBtn:CreateTexture(nil, "BORDER"); f.textColorBorder:SetPoint("TOPLEFT", -1, 1); f.textColorBorder:SetPoint("BOTTOMRIGHT", 1, -1); f.textColorBorder:SetColorTexture(0, 0, 0, 1)

    f.grayCooldownCheck = CreateFrame("CheckButton", nil, f.displayPanel, "ChatConfigCheckButtonTemplate"); f.grayCooldownCheck:SetPoint("TOPLEFT", f.textColorLabel, "BOTTOMLEFT", -4, -14)
    f.grayCooldownLabel = f.displayPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.grayCooldownLabel:SetPoint("LEFT", f.grayCooldownCheck, "RIGHT", 2, 0); f.grayCooldownLabel:SetText("Grayscale on cooldown")
    f.grayCooldownCheck:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local s = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key)); s.grayOnCooldown = self:GetChecked() and true or nil
        MSWA_RequestUpdateSpells()
    end)

    -- Apply logic + hooks (identical to original)
    local function ApplyDisplay() local key = MSWA.selectedSpellID; if not key then return end; local db = MSWA_GetDB(); db.spellSettings = db.spellSettings or {}; local s = db.spellSettings[key] or {}
        local x = tonumber(f.detailX:GetText() or "") or 0; local y = tonumber(f.detailY:GetText() or "") or 0
        local w = tonumber(f.detailW:GetText() or "") or MSWA.ICON_SIZE; local h = tonumber(f.detailH:GetText() or "") or MSWA.ICON_SIZE
        if w < 16 then w = 16 end; if h < 16 then h = 16 end; if w > 128 then w = 128 end; if h > 128 then h = 128 end
        s.x = x; s.y = y; s.width = w; s.height = h; db.spellSettings[key] = s; MSWA_RequestUpdateSpells()
    end
    local function ApplyAnchor() local key = MSWA.selectedSpellID; if not key then return end; local db = MSWA_GetDB(); db.spellSettings = db.spellSettings or {}; local s = db.spellSettings[key] or {}
        local a = f.detailA:GetText(); if a == "" then a = nil end; s.anchorFrame = a; db.spellSettings[key] = s; MSWA_RequestUpdateSpells(); MSWA_UpdateDetailPanel()
    end
    local function HookBox(box, applyFunc) if not box then return end; box:SetScript("OnEnterPressed", function(self) self:ClearFocus(); applyFunc() end); box:SetScript("OnEditFocusLost", function() applyFunc() end) end
    HookBox(f.detailX, ApplyDisplay); HookBox(f.detailY, ApplyDisplay); HookBox(f.detailW, ApplyDisplay); HookBox(f.detailH, ApplyDisplay); HookBox(f.detailA, ApplyAnchor)

    -- Text size +/-
    local function ClampTextSize(v) v = tonumber(v) or 12; if v < 6 then v = 6 end; if v > 48 then v = 48 end; return v end
    local function ApplyTextSize() local db = MSWA_GetDB(); local key = MSWA.selectedSpellID; local s = key and select(1, MSWA_GetOrCreateSpellSettings(db, key)) or nil
        local cur = (s and s.textFontSize) or db.textFontSize; local v = ClampTextSize(f.textSizeEdit and f.textSizeEdit:GetText() or cur)
        if s then s.textFontSize = v else db.textFontSize = v end; if f.textSizeEdit then f.textSizeEdit:SetText(tostring(v)) end; MSWA_RequestUpdateSpells()
    end
    HookBox(f.textSizeEdit, ApplyTextSize)
    f.textSizeMinus:SetScript("OnClick", function() local db = MSWA_GetDB(); local key = MSWA.selectedSpellID; local s = key and select(1, MSWA_GetOrCreateSpellSettings(db, key)) or nil
        local cur = (s and s.textFontSize) or db.textFontSize; local v = ClampTextSize((f.textSizeEdit and f.textSizeEdit:GetText()) or cur) - 1; v = ClampTextSize(v)
        if s then s.textFontSize = v else db.textFontSize = v end; if f.textSizeEdit then f.textSizeEdit:SetText(tostring(v)) end; MSWA_RequestUpdateSpells()
    end)
    f.textSizePlus:SetScript("OnClick", function() local db = MSWA_GetDB(); local key = MSWA.selectedSpellID; local s = key and select(1, MSWA_GetOrCreateSpellSettings(db, key)) or nil
        local cur = (s and s.textFontSize) or db.textFontSize; local v = ClampTextSize((f.textSizeEdit and f.textSizeEdit:GetText()) or cur) + 1; v = ClampTextSize(v)
        if s then s.textFontSize = v else db.textFontSize = v end; if f.textSizeEdit then f.textSizeEdit:SetText(tostring(v)) end; MSWA_RequestUpdateSpells()
    end)

    -- Text pos dropdown
    if f.textPosDrop and UIDropDownMenu_Initialize then
        UIDropDownMenu_SetWidth(f.textPosDrop, 120)
        UIDropDownMenu_Initialize(f.textPosDrop, function(self, level) local db = MSWA_GetDB(); local key = MSWA.selectedSpellID; local s = key and select(1, MSWA_GetSpellSettings(db, key)) or nil; local cur = (s and s.textPoint) or db.textPoint or "BOTTOMRIGHT"
            for _, point in ipairs({"BOTTOMRIGHT","BOTTOMLEFT","TOPRIGHT","TOPLEFT","CENTER"}) do
                local info = UIDropDownMenu_CreateInfo(); info.text = MSWA_GetTextPosLabel(point); info.checked = (tostring(cur) == tostring(point))
                info.func = function() local s2 = select(1, MSWA_GetOrCreateSpellSettings(db, key)); s2.textPoint = point; UIDropDownMenu_SetText(f.textPosDrop, MSWA_GetTextPosLabel(point)); CloseDropDownMenus(); MSWA_RequestUpdateSpells() end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
    end

    -- Color picker (simplified)
    f.textColorBtn:SetScript("OnClick", function()
        local db = MSWA_GetDB(); local keyAtOpen = MSWA.selectedSpellID; local s = keyAtOpen and select(1, MSWA_GetSpellSettings(db, keyAtOpen)) or nil
        local tc = (s and s.textColor) or db.textColor or { r = 1, g = 1, b = 1 }; local r, g, b = tonumber(tc.r) or 1, tonumber(tc.g) or 1, tonumber(tc.b) or 1
        local function Apply(nr, ng, nb)
            local s3 = keyAtOpen and select(1, MSWA_GetOrCreateSpellSettings(db, keyAtOpen)) or nil
            if s3 then s3.textColor = s3.textColor or {}; s3.textColor.r = nr; s3.textColor.g = ng; s3.textColor.b = nb
            else db.textColor = db.textColor or {}; db.textColor.r = nr; db.textColor.g = ng; db.textColor.b = nb end
            if f.textColorSwatch and MSWA_KeyEquals(MSWA.selectedSpellID, keyAtOpen) then f.textColorSwatch:SetColorTexture(nr, ng, nb, 1) end
            MSWA_RequestUpdateSpells()
        end
        if ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow then
            local function OnChanged() local nr, ng, nb = ColorPickerFrame:GetColorRGB(); if type(nr) == "number" then Apply(nr, ng, nb) end end
            ColorPickerFrame:SetupColorPickerAndShow({ r=r, g=g, b=b, hasOpacity=false, swatchFunc=OnChanged, func=OnChanged, okayFunc=OnChanged, cancelFunc=function(restore) if type(restore) == "table" then Apply(restore.r or r, restore.g or g, restore.b or b) else Apply(r, g, b) end end })
        elseif ColorPickerFrame then
            ColorPickerFrame.hasOpacity = false; ColorPickerFrame.previousValues = { r=r, g=g, b=b }
            ColorPickerFrame.func = function() Apply(ColorPickerFrame:GetColorRGB()) end
            ColorPickerFrame.cancelFunc = function(prev) if type(prev) == "table" then Apply(prev.r or r, prev.g or g, prev.b or b) else Apply(r, g, b) end end
            ColorPickerFrame:SetColorRGB(r, g, b); ColorPickerFrame:Show()
        end
    end)

    -- Button actions
    f.detailApply:SetScript("OnClick", function() local key = MSWA.selectedSpellID; if not key then return end; local db = MSWA_GetDB(); local s = (db.spellSettings or {})[key] or {}; s.x = nil; s.y = nil; s.anchorFrame = nil; db.spellSettings[key] = s; MSWA_RequestUpdateSpells(); MSWA_UpdateDetailPanel() end)
    f.detailACD:SetScript("OnClick", function() f.detailA:SetText("CooldownManager"); ApplyAnchor() end)
    f.detailAMSUF:SetScript("OnClick", function() f.detailA:SetText("MSUF_player"); ApplyAnchor() end)
    f.detailDefault:SetScript("OnClick", function() local key = MSWA.selectedSpellID; if not key then return end; local db = MSWA_GetDB(); (db.spellSettings or {})[key] = nil; MSWA_RequestUpdateSpells(); MSWA_UpdateDetailPanel() end)

    local function NudgeOffset(axis, delta) local key = MSWA.selectedSpellID; if not key then return end; local db = MSWA_GetDB(); db.spellSettings = db.spellSettings or {}; local s = db.spellSettings[key] or {}
        if axis == "X" then s.x = (s.x or 0) + delta else s.y = (s.y or 0) + delta end; db.spellSettings[key] = s
        f.detailX:SetText(("%d"):format(s.x or 0)); f.detailY:SetText(("%d"):format(s.y or 0)); MSWA_RequestUpdateSpells()
    end
    f.detailXMinus:SetScript("OnClick", function() NudgeOffset("X", -1) end); f.detailXPlus:SetScript("OnClick", function() NudgeOffset("X", 1) end)
    f.detailYMinus:SetScript("OnClick", function() NudgeOffset("Y", -1) end); f.detailYPlus:SetScript("OnClick", function() NudgeOffset("Y", 1) end)

    -- ID type dropdown
    f.idType = "AUTO"
    UIDropDownMenu_Initialize(f.idTypeDrop, function(self, level) if not level then return end
        local function Add(text, typeKey) local info = UIDropDownMenu_CreateInfo(); info.text = text; info.value = typeKey; info.func = function() f.idType = typeKey; UIDropDownMenu_SetSelectedValue(f.idTypeDrop, typeKey); UIDropDownMenu_SetText(f.idTypeDrop, text) end; info.checked = (f.idType == typeKey); UIDropDownMenu_AddButton(info, level) end
        Add("Auto", "AUTO"); Add("Spell", "SPELL"); Add("Item", "ITEM"); Add("Auto Buff", "AUTOBUFF"); Add("Item Buff", "ITEMBUFF")
    end)
    UIDropDownMenu_SetSelectedValue(f.idTypeDrop, "AUTO"); UIDropDownMenu_SetText(f.idTypeDrop, "Auto")

    -- Add from UI
    local function ReplaceDraftWithNewKey(oldKey, newKey) local db = MSWA_GetDB(); db.spellSettings = db.spellSettings or {}; db.trackedSpells = db.trackedSpells or {}
        if MSWA_IsDraftKey(oldKey) then
            local s = db.spellSettings[oldKey]; if s then db.spellSettings[oldKey] = nil; if not db.spellSettings[newKey] then db.spellSettings[newKey] = s end end
            if db.auraGroups and db.auraGroups[oldKey] then if not db.auraGroups[newKey] then db.auraGroups[newKey] = db.auraGroups[oldKey] end; db.auraGroups[oldKey] = nil end
            if db.customNames and db.customNames[oldKey] then if not db.customNames[newKey] then db.customNames[newKey] = db.customNames[oldKey] end; db.customNames[oldKey] = nil end
            db.trackedSpells[oldKey] = nil
        end
    end

    local function AddFromUI() local text = f.addEdit:GetText(); local id = tonumber(text); if not id then return end
        local db = MSWA_GetDB(); db.trackedItems = db.trackedItems or {}; db.trackedSpells = db.trackedSpells or {}
        local mode = f.idType or "AUTO"; local newKey
        local function IsAlready(sid) if db.trackedSpells[sid] then return true end; for k, en in pairs(db.trackedSpells) do if en and MSWA_IsSpellInstanceKey(k) and MSWA_KeyToSpellID(k) == sid then return true end end; return false end
        if mode == "ITEM" then db.trackedItems[id] = true; newKey = ("item:%d"):format(id)
        elseif mode == "SPELL" then local name = MSWA_GetSpellName(id); if not name then return end; if IsAlready(id) then newKey = MSWA_NewSpellInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedSpells[id] = true; newKey = id end
        elseif mode == "AUTOBUFF" then if IsAlready(id) then newKey = MSWA_NewSpellInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedSpells[id] = true; newKey = id end; db.spellSettings = db.spellSettings or {}; local s = db.spellSettings[newKey] or {}; s.auraMode = "AUTOBUFF"; if not s.autoBuffDuration then s.autoBuffDuration = 10 end; db.spellSettings[newKey] = s
        elseif mode == "ITEMBUFF" then db.trackedItems[id] = true; newKey = ("item:%d"):format(id); db.spellSettings = db.spellSettings or {}; local s = db.spellSettings[newKey] or {}; s.auraMode = "AUTOBUFF"; if not s.autoBuffDuration then s.autoBuffDuration = 10 end; db.spellSettings[newKey] = s
        else local name = MSWA_GetSpellName(id); if name then if IsAlready(id) then newKey = MSWA_NewSpellInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedSpells[id] = true; newKey = id end else db.trackedItems[id] = true; newKey = ("item:%d"):format(id) end end
        local oldKey = MSWA.selectedSpellID; if oldKey and MSWA_IsDraftKey(oldKey) and newKey then ReplaceDraftWithNewKey(oldKey, newKey) end
        MSWA.selectedSpellID = newKey; f.addEdit:SetText(""); MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList()
    end
    f.addButton:SetScript("OnClick", AddFromUI); f.addEdit:SetScript("OnEnterPressed", AddFromUI); f.addEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Top button scripts
    f.btnNew:SetScript("OnClick", function() local db = MSWA_GetDB(); db.trackedSpells = db.trackedSpells or {}; local dk = MSWA_NewDraftKey(); db.trackedSpells[dk] = true; MSWA.selectedSpellID = dk; MSWA.selectedGroupID = nil; SetActiveTab("GENERAL"); MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList(); if f.addEdit then f.addEdit:SetFocus(); f.addEdit:HighlightText() end end)
    f.btnGroup:SetScript("OnClick", function() local gid = MSWA_CreateGroup(nil); MSWA.selectedSpellID = nil; MSWA.selectedGroupID = gid; MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList() end)
    f.btnPreview:SetScript("OnClick", function()
        MSWA.previewMode = not MSWA.previewMode
        if MSWA.previewMode then f.btnPreview:SetText("|cff00ff00Preview|r"); MSWA_Print("Preview ON") else f.btnPreview:SetText("Preview"); MSWA_Print("Preview OFF.") end
        MSWA_RequestUpdateSpells()
    end)
    f.btnImport:SetScript("OnClick", function() MSWA_OpenImportFrame() end)
    f.btnExport:SetScript("OnClick", function()
        if MSWA.selectedGroupID then MSWA_ExportGroup(MSWA.selectedGroupID); return end
        local key = MSWA.selectedSpellID; if not key then MSWA_Print("Select an aura or group to export."); return end
        local db = MSWA_GetDB(); local gid = db.auraGroups and (db.auraGroups[key] or db.auraGroups[tostring(key)])
        if gid and db.groups and db.groups[gid] then MSWA_ExportGroup(gid); return end
        MSWA_ExportAura(key)
    end)

    -- OnShow / OnHide
    f:SetScript("OnShow", function()
        MSWA.selectedSpellID = nil; MSWA.selectedGroupID = nil; MSWA.previewMode = false
        if f.btnPreview then f.btnPreview:SetText("Preview") end
        f.activeTab = "GENERAL"
        if f.tabGeneral then f.tabGeneral:LockHighlight() end; if f.tabDisplay then f.tabDisplay:UnlockHighlight() end; if f.tabImport then f.tabImport:UnlockHighlight() end
        f:UpdateAuraList(); MSWA_ApplyUIFont()
    end)
    f:SetScript("OnHide", function()
        MSWA.selectedSpellID = nil; MSWA.selectedGroupID = nil
        if MSWA.previewMode then MSWA.previewMode = false; if f.btnPreview then f.btnPreview:SetText("Preview") end; MSWA_RequestUpdateSpells() end
    end)

    f:Hide(); MSWA.optionsFrame = f
    MSWA_RebuildFontChoices(); MSWA_InitFontDropdown(); MSWA_ApplyUIFont()
    f:UpdateAuraList()
    return f
end

-----------------------------------------------------------
-- Toggle options
-----------------------------------------------------------

function MSWA_ToggleOptions()
    local f = MSWA.optionsFrame or MSWA_CreateOptionsFrame()
    if f:IsShown() then f:Hide() else MSWA_RefreshOptionsList(); MSWA_ApplyUIFont(); f:Show() end
end

-----------------------------------------------------------
-- Slash commands
-----------------------------------------------------------

SLASH_MIDNIGHTSIMPLEWEAKAURAS1 = "/msa"
SLASH_MIDNIGHTSIMPLEWEAKAURAS2 = "/ms"
SLASH_MIDNIGHTSIMPLEWEAKAURAS3 = "/midnightsimpleauras"

SlashCmdList["MIDNIGHTSIMPLEWEAKAURAS"] = function(msg)
    local db = MSWA_GetDB()
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S+)%s*(.*)$"); cmd = cmd or ""; rest = rest or ""

    if cmd == "" or cmd == "config" or cmd == "options" or cmd == "menu" then MSWA_ToggleOptions(); return end
    if cmd == "move" or cmd == "unlock" then db.locked = false; MSWA.frame.infoText:Show(); MSWA_UpdatePositionFromDB(); MSWA_Print("Frame unlocked."); return end
    if cmd == "lock" then db.locked = true; MSWA.frame.infoText:Hide(); MSWA_UpdatePositionFromDB(); MSWA_Print("Frame locked."); return end
    if cmd == "reset" then db.position = { x = 0, y = -150 }; MSWA_UpdatePositionFromDB(); MSWA_Print("Position reset."); return end

    if cmd == "add" then
        local id = tonumber(rest); if not id then MSWA_Print("Use: /msa add <SpellID>"); return end
        local name = MSWA_GetSpellName(id); if not name then MSWA_Print("Invalid SpellID: " .. id); return end
        local newKey; if db.trackedSpells[id] then newKey = MSWA_NewSpellInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedSpells[id] = true; newKey = id end
        MSWA.selectedSpellID = newKey; MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList(); MSWA_Print(("Now tracking %s (%d)."):format(name, id)); return
    end
    if cmd == "additem" or cmd == "itemadd" then
        local id = tonumber(rest); if not id then MSWA_Print("Use: /msa additem <ItemID>"); return end
        db.trackedItems = db.trackedItems or {}; db.trackedItems[id] = true
        MSWA.selectedSpellID = ("item:%d"):format(id); MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList()
        MSWA_Print(("Now tracking item %d."):format(id)); return
    end
    if cmd == "remove" or cmd == "del" or cmd == "delete" then
        local id = tonumber(rest); if not id then MSWA_Print("Use: /msa remove <SpellID>"); return end
        if db.trackedSpells[id] then
            db.trackedSpells[id] = nil; if MSWA.selectedSpellID == id then MSWA.selectedSpellID = nil; MSWA.selectedGroupID = nil end
            MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList(); MSWA_Print(("Stopped tracking %d."):format(id))
        else MSWA_Print("Not tracked: " .. id) end; return
    end
    if cmd == "removeitem" or cmd == "delitem" or cmd == "deleteitem" then
        local id = tonumber(rest); if not id then MSWA_Print("Use: /msa removeitem <ItemID>"); return end
        db.trackedItems = db.trackedItems or {}; local key = ("item:%d"):format(id)
        if db.trackedItems[id] then db.trackedItems[id] = nil; if db.customNames then db.customNames[key] = nil end
            if MSWA.selectedSpellID == key then MSWA.selectedSpellID = nil; MSWA.selectedGroupID = nil end
            MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList(); MSWA_Print(("Stopped tracking item %d."):format(id))
        else MSWA_Print("Not tracked: " .. id) end; return
    end
    if cmd == "list" then
        MSWA_Print("Tracked SpellIDs:"); local empty = true
        for id, enabled in pairs(db.trackedSpells) do if enabled then print(("  - %s : %s"):format(tostring(id), MSWA_GetSpellName(id) or "???")); empty = false end end
        if empty then MSWA_Print("None.") end
        MSWA_Print("Tracked ItemIDs:"); local ie = true; db.trackedItems = db.trackedItems or {}
        for itemID, enabled in pairs(db.trackedItems) do if enabled then print(("  - %d"):format(itemID)); ie = false end end
        if ie then MSWA_Print("None.") end; return
    end

    MSWA_Print("Commands: /msa, /msa move, /msa lock, /msa reset, /msa add <ID>, /msa remove <ID>, /msa additem <ID>, /msa removeitem <ID>, /msa list")
end

-----------------------------------------------------------
-- Open helpers (called by MSUF)
-----------------------------------------------------------

function MSWA_OpenOptions() MSWA_ToggleOptions() end
function MidnightSimpleAuras_OpenOptions() MSWA_ToggleOptions() end
