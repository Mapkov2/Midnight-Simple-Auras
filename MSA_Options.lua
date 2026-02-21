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

    -- Modern Midnight 12.0 menu API (MenuUtil.CreateContextMenu)
    if not MenuUtil or not MenuUtil.CreateContextMenu then return end

    -- Count multi-selected auras
    local multiSel = MSWA._multiSelect or {}
    local multiCount = 0
    for _ in pairs(multiSel) do multiCount = multiCount + 1 end

    -- Multi-select batch menu: when right-clicking a multi-selected aura
    if multiCount > 1 and row.entryType == "AURA" and row.key and multiSel[row.key] then
        MenuUtil.CreateContextMenu(row, function(ownerRegion, rootDescription)
            rootDescription:CreateTitle(multiCount .. " Auras Selected")
            rootDescription:CreateButton("Export Selected (" .. multiCount .. ")", function()
                -- Collect all export strings and combine
                local parts = {}
                for key in pairs(multiSel) do
                    local s = MSWA_BuildAuraExportString(key)
                    if s then tinsert(parts, s) end
                end
                if #parts > 0 then
                    local combined = table.concat(parts, "\n---\n")
                    local ef = MSWA_GetExportFrame()
                    ef.title:SetText("Export " .. #parts .. " Auras")
                    ef.editBox:SetText(combined); ef.editBox:HighlightText(); ef:Show()
                end
            end)
            rootDescription:CreateDivider()
            rootDescription:CreateButton("|cffff4040Delete Selected (" .. multiCount .. ")|r", function()
                local keys = {}
                for key in pairs(multiSel) do tinsert(keys, key) end
                wipe(multiSel)
                for _, key in ipairs(keys) do
                    MSWA_DeleteAuraKey(key)
                end
                MSWA_RequestFullRefresh()
            end)
        end)
        return
    end

    MenuUtil.CreateContextMenu(row, function(ownerRegion, rootDescription)
        if row.entryType == "AURA" and row.key ~= nil then
            local key = row.key
            local currentName = (db.customNames and db.customNames[key]) or ""
            local displayName = MSWA_GetDisplayNameForKey(key) or "Aura"
            local defaultText = (currentName ~= "" and currentName) or displayName

            rootDescription:CreateTitle(displayName)
            rootDescription:CreateButton("Rename", function()
                C_Timer.After(0, function()
                    if MSWA_ShowInlineRenameForKey then
                        MSWA_ShowInlineRenameForKey(key, defaultText)
                    end
                end)
            end)

            -- Move Up / Move Down (only for grouped auras)
            local gid = row.groupID
            if gid and type(MSWA_MoveGroupMember) == "function" then
                local members = nil
                if type(MSWA_EnsureGroupMembers) == "function" then
                    members = MSWA_EnsureGroupMembers(gid)
                elseif db.groupMembers and type(db.groupMembers[gid]) == "table" then
                    members = db.groupMembers[gid]
                end
                local idxm, n = nil, (type(members) == "table" and #members or 0)
                if type(members) == "table" then
                    for j = 1, #members do
                        if members[j] == key then idxm = j; break end
                    end
                end
                local canUp  = idxm and idxm > 1
                local canDown = idxm and n > 1 and idxm < n

                local btnUp = rootDescription:CreateButton("Move Up", function()
                    MSWA_MoveGroupMember(gid, key, -1)
                    MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList()
                end)
                if not canUp then btnUp:SetEnabled(false) end

                local btnDown = rootDescription:CreateButton("Move Down", function()
                    MSWA_MoveGroupMember(gid, key, 1)
                    MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList()
                end)
                if not canDown then btnDown:SetEnabled(false) end
            end

            rootDescription:CreateButton("Export", function()
                MSWA_ExportAura(key)
            end)
            rootDescription:CreateDivider()
            rootDescription:CreateButton("|cffff4040Delete|r", function()
                MSWA_DeleteAuraKey(key)
                MSWA_RequestFullRefresh()
            end)

        elseif row.entryType == "GROUP" and row.groupID then
            local gid = row.groupID
            local g = db.groups and db.groups[gid]

            rootDescription:CreateTitle((g and g.name) or "Group")
            rootDescription:CreateButton("Rename", function()
                C_Timer.After(0, function()
                    if MSWA_ShowInlineRenameForGroup then
                        MSWA_ShowInlineRenameForGroup(gid, (g and g.name) or "")
                    end
                end)
            end)
            rootDescription:CreateButton("Export Group", function()
                MSWA_ExportGroup(gid)
            end)
            rootDescription:CreateDivider()
            rootDescription:CreateButton("|cffff4040Delete Group|r", function()
                MSWA_DeleteGroup(gid)
                MSWA_RequestFullRefresh()
            end)
        end
    end)
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

    -- Item instance keys (item:ID:N in trackedSpells)
    local itemInstanceKeys = {}
    for id, enabled in pairs(tracked) do
        if enabled and MSWA_IsItemInstanceKey(id) then tinsert(itemInstanceKeys, id) end
    end
    tsort(itemInstanceKeys, function(a, b)
        local ia = MSWA_KeyToItemID(a) or 0
        local ib = MSWA_KeyToItemID(b) or 0
        if ia ~= ib then return ia < ib end
        return a < b
    end)
    for _, k in ipairs(itemInstanceKeys) do tinsert(tempIDList, k) end

    for id, enabled in pairs(tracked) do
        if enabled and type(id) ~= "number" and not MSWA_IsSpellInstanceKey(id) and not MSWA_IsItemInstanceKey(id) then
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

    local function OrderGroupList(gid, list)
        if not list or #list <= 1 then return list end

        local members = nil
        if type(MSWA_EnsureGroupMembers) == "function" then
            members = MSWA_EnsureGroupMembers(gid)
        elseif db.groupMembers and type(db.groupMembers[gid]) == "table" then
            members = db.groupMembers[gid]
        end
        if type(members) ~= "table" or #members == 0 then return list end

        local present = {}
        for i = 1, #list do
            present[list[i]] = true
        end

        local out = {}
        for i = 1, #members do
            local k = members[i]
            if present[k] then
                tinsert(out, k)
                present[k] = nil
            end
        end

        -- Fallback: append any keys not yet in groupMembers (legacy DB)
        for i = 1, #list do
            local k = list[i]
            if present[k] then
                tinsert(out, k)
            end
        end
        return out
    end

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
                local list = OrderGroupList(gid, grouped[gid])
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
            if f.glowPanel2 then f.glowPanel2:Hide() end
            if f.emptyPanel then f.emptyPanel:Hide() end
            if f.groupPanel then f.groupPanel:Hide() end
            if f.groupPanel then f.groupPanel:Show() end
            if f.tabGeneral then f.tabGeneral:Disable() end
            if f.tabDisplay then f.tabDisplay:Disable() end
            if f.tabGlow then f.tabGlow:Disable() end
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
        if f.glowPanel2 then f.glowPanel2:Hide() end
        if f.emptyPanel then f.emptyPanel:Show() end
        if f.groupPanel then f.groupPanel:Hide() end
        if f.tabGeneral then f.tabGeneral:Disable() end
        if f.tabDisplay then f.tabDisplay:Disable() end
        if f.tabGlow then f.tabGlow:Disable() end
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
    local a
    do
        -- Show/store the *effective* anchor name:
        -- If this aura is inside a group, the group is the master anchor.
        local gid2 = (MSWA_GetAuraGroup and MSWA_GetAuraGroup(key)) or nil
        if gid2 then
            local g2 = (db.groups or {})[gid2]
            a = (g2 and g2.anchorFrame) or ""
        else
            a = s.anchorFrame or ""
        end
    end

    if f.rightTitle then f.rightTitle:SetText(name or "Selected Aura") end

    if f.emptyPanel then f.emptyPanel:Hide() end
    if f.groupPanel then f.groupPanel:Hide() end
    if f.tabGeneral then f.tabGeneral:Enable() end
    if f.tabDisplay then f.tabDisplay:Enable() end
    if f.tabGlow then f.tabGlow:Enable() end
    if f.tabImport then f.tabImport:Enable() end

    local tab = f.activeTab or "GENERAL"
    if tab == "DISPLAY" then
        if f.generalPanel then f.generalPanel:Hide() end
        if f.altPanel then f.altPanel:Hide() end
        if f.glowPanel2 then f.glowPanel2:Hide() end
        if f.displayPanel then f.displayPanel:Show() end
    elseif tab == "GLOW" then
        if f.generalPanel then f.generalPanel:Hide() end
        if f.displayPanel then f.displayPanel:Hide() end
        if f.altPanel then f.altPanel:Hide() end
        if f.glowPanel2 then f.glowPanel2:Show(); if f.glowPanel2.Sync then f.glowPanel2:Sync() end end
    elseif tab == "IMPORT" then
        if f.generalPanel then f.generalPanel:Hide() end
        if f.displayPanel then f.displayPanel:Hide() end
        if f.glowPanel2 then f.glowPanel2:Hide() end
        if f.altPanel then f.altPanel:Show(); if f.altPanel.Sync then f.altPanel:Sync() end end
    else
        if f.displayPanel then f.displayPanel:Hide() end
        if f.altPanel then f.altPanel:Hide() end
        if f.glowPanel2 then f.glowPanel2:Hide() end
        if f.generalPanel then f.generalPanel:Show() end
    end

    if f.detailName then
        local abTag = ""
        if s and s.auraMode == "AUTOBUFF" then
            abTag = MSWA_IsItemKey(key) and " |cff44ddff[Buff Timer]|r" or " |cff44ddff[Auto Buff]|r"
        elseif s and s.auraMode == "BUFF_THEN_CD" then
            abTag = " |cff44ffaa[Buff -> CD]|r"
        elseif s and s.auraMode == "REMINDER_BUFF" then
            abTag = " |cffff6644[Reminder Buff]|r"
        elseif s and s.auraMode == "CHARGES" then
            abTag = " |cff44ddff[Charges]|r"
        end
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

    -- Sync custom icon
    if f.customIconEdit then
        local cid = (s and s.customIconID) or nil
        if cid and tonumber(cid) and tonumber(cid) > 0 then
            f.customIconEdit:SetText(tostring(cid))
            if f.customIconPreview then f.customIconPreview:SetTexture(tonumber(cid)); f.customIconPreview:Show() end
        else
            f.customIconEdit:SetText("")
            if f.customIconPreview then f.customIconPreview:Hide() end
        end
    end

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
    if f.grayZeroCountCheck then
        f.grayZeroCountCheck:SetChecked((s and s.showOnZeroCount) and true or false)
    end
    if f.swipeDarkenCheck then
        -- "Swipe darkens on loss" == reverse swipe direction.
        f.swipeDarkenCheck:SetChecked((s and s.swipeDarken) and true or false)
    end
    if f.showDecimalCheck then
        f.showDecimalCheck:SetChecked((s and s.showDecimal) and true or false)
    end

    -- Sync alpha sliders
    if f.cdAlphaSlider then
        local v = (s and tonumber(s.cdAlpha)) or 1.0
        f.cdAlphaSlider:SetValue(math.floor(v * 100 + 0.5))
    end
    if f.oocAlphaSlider then
        local v = (s and tonumber(s.oocAlpha)) or 1.0
        f.oocAlphaSlider:SetValue(math.floor(v * 100 + 0.5))
    end
    if f.combatAlphaSlider then
        local v = (s and tonumber(s.combatAlpha)) or 1.0
        f.combatAlphaSlider:SetValue(math.floor(v * 100 + 0.5))
    end

    -- Sync conditional 2nd text color controls
    -- Timer-based text color works for AUTOBUFF / BUFF_THEN_CD / REMINDER_BUFF (we compute remaining ourselves)
    local isAutoBuff = s and (s.auraMode == "AUTOBUFF" or s.auraMode == "BUFF_THEN_CD" or s.auraMode == "REMINDER_BUFF" or s.auraMode == "CHARGES")
    if f.tc2Check then
        local canUseTC2 = isAutoBuff
        f.tc2Check:SetShown(canUseTC2)
        if f.tc2Label then f.tc2Label:SetShown(canUseTC2) end
        if f.tc2ColorLabel then f.tc2ColorLabel:SetShown(canUseTC2) end
        if f.tc2ColorBtn then f.tc2ColorBtn:SetShown(canUseTC2) end
        if f.tc2CondLabel then f.tc2CondLabel:SetShown(canUseTC2) end
        if f.tc2CondButton then f.tc2CondButton:SetShown(canUseTC2) end
        if f.tc2ValueEdit then f.tc2ValueEdit:SetShown(canUseTC2) end
        if f.tc2ValueLabel then f.tc2ValueLabel:SetShown(canUseTC2) end

        if canUseTC2 then
            local tc2en = (s and s.textColor2Enabled) and true or false
            f.tc2Check:SetChecked(tc2en)
        -- Color swatch
        if f.tc2ColorSwatch then
            local tc2 = (s and s.textColor2) or { r = 1, g = 0.2, b = 0.2 }
            f.tc2ColorSwatch:SetColorTexture(tonumber(tc2.r) or 1, tonumber(tc2.g) or 0.2, tonumber(tc2.b) or 0.2, 1)
        end
        -- Condition text
        local cond = (s and s.textColor2Cond) or "TIMER_BELOW"
        if f.tc2CondButton then
            if cond == "TIMER_ABOVE" then
                f.tc2CondButton:SetText("Timer >= X")
            else
                f.tc2CondButton:SetText("Timer <= X")
            end
        end
        -- Value
        if f.tc2ValueEdit then
            f.tc2ValueEdit:SetText(tostring((s and s.textColor2Value) or 5))
        end
        -- Enable/disable sub-controls
        local enSub = tc2en
        if f.tc2ColorBtn then f.tc2ColorBtn[enSub and "Enable" or "Disable"](f.tc2ColorBtn) end
        if f.tc2CondButton then f.tc2CondButton[enSub and "Enable" or "Disable"](f.tc2CondButton) end
        if f.tc2ValueEdit then f.tc2ValueEdit[enSub and "Enable" or "Disable"](f.tc2ValueEdit) end
        if f.tc2ColorLabel then f.tc2ColorLabel:SetAlpha(enSub and 1 or 0.4) end
        if f.tc2CondLabel then f.tc2CondLabel:SetAlpha(enSub and 1 or 0.4) end
        if f.tc2ValueLabel then f.tc2ValueLabel:SetAlpha(enSub and 1 or 0.4) end
        end -- canUseTC2
    end

    -- Sync Stack controls
    if f.stackShowMode then
        local mode = (s and s.stackShowMode) or "auto"
        local stackShowLabels2 = { auto = "Auto", show = "Force Show", hide = "Force Hide" }
        f.stackShowMode:SetText(stackShowLabels2[mode] or "Auto")
    end
    if f.stackSizeEdit then
        local sz = (s and s.stackFontSize) or 12
        sz = tonumber(sz) or 12; if sz < 6 then sz = 6 end; if sz > 48 then sz = 48 end
        f.stackSizeEdit:SetText(tostring(sz))
    end
    if f.stackPosDrop and UIDropDownMenu_SetText then
        local point = (s and s.stackPoint) or "BOTTOMRIGHT"
        UIDropDownMenu_SetText(f.stackPosDrop, MSWA_GetTextPosLabel(point))
    end
    if f.stackColorSwatch then
        local tc = (s and s.stackColor) or { r = 1, g = 1, b = 1 }
        f.stackColorSwatch:SetColorTexture(tonumber(tc.r) or 1, tonumber(tc.g) or 1, tonumber(tc.b) or 1, 1)
    end
    if f.stackOffXEdit then
        f.stackOffXEdit:SetText(tostring((s and s.stackOffsetX) or 0))
    end
    if f.stackOffYEdit then
        f.stackOffYEdit:SetText(tostring((s and s.stackOffsetY) or 0))
    end
    if f.stackFontDrop and f._initStackFontDrop then
        f._initStackFontDrop()
    end

    -- Sync Charge Tracker controls
    if f.chargeMaxEdit then
        f.chargeMaxEdit:SetText(tostring((s and s.chargeMax) or 3))
    end
    if f.chargeDurEdit then
        f.chargeDurEdit:SetText(tostring((s and s.chargeDuration) or 0))
    end
    if f.chargeSizeEdit then
        local csz = (s and s.chargeFontSize) or 12
        csz = tonumber(csz) or 12; if csz < 6 then csz = 6 end; if csz > 48 then csz = 48 end
        f.chargeSizeEdit:SetText(tostring(csz))
    end
    if f.chargePosDrop and UIDropDownMenu_SetText then
        local cpt = (s and s.chargePoint) or "BOTTOMRIGHT"
        UIDropDownMenu_SetText(f.chargePosDrop, MSWA_GetTextPosLabel(cpt))
    end
    if f.chargeColorSwatch then
        local cc = (s and s.chargeColor) or { r = 1, g = 1, b = 1 }
        f.chargeColorSwatch:SetColorTexture(tonumber(cc.r) or 1, tonumber(cc.g) or 1, tonumber(cc.b) or 1, 1)
    end
    if f.chargeOffXEdit then
        f.chargeOffXEdit:SetText(tostring((s and s.chargeOffsetX) or 0))
    end
    if f.chargeOffYEdit then
        f.chargeOffYEdit:SetText(tostring((s and s.chargeOffsetY) or 0))
    end

    -- Sync Auto Buff controls
    if f.autoBuffCheck then
        local isAutoBuff = (s and s.auraMode == "AUTOBUFF") and true or false
        local isBuffThenCD = (s and s.auraMode == "BUFF_THEN_CD") and true or false
        local isReminderBuff = (s and s.auraMode == "REMINDER_BUFF") and true or false
        local isCharges = (s and s.auraMode == "CHARGES") and true or false
        local hasBuffMode = isAutoBuff or isBuffThenCD or isReminderBuff
        local isSpellKey = MSWA_IsSpellKey(key)
        local isItemKey  = MSWA_IsItemKey(key)
        local isDraft    = MSWA_IsDraftKey(key)

        if isSpellKey or isItemKey then
            f.autoBuffCheck:Show(); f.autoBuffLabel:Show()
            f.autoBuffCheck:SetChecked(isAutoBuff)
            -- Contextual label
            if isItemKey then
                f.autoBuffLabel:SetText("|cffffcc00Buff Timer mode|r  (show icon + countdown when used)")
            else
                f.autoBuffLabel:SetText("|cffffcc00Auto Buff mode|r  (show icon only while buff is active)")
            end
        else
            f.autoBuffCheck:Hide(); f.autoBuffLabel:Hide()
        end

        -- Buff → Cooldown checkbox
        if f.buffThenCDCheck then
            if isSpellKey or isItemKey then
                f.buffThenCDCheck:Show(); f.buffThenCDLabel:Show()
                f.buffThenCDCheck:SetChecked(isBuffThenCD)
            else
                f.buffThenCDCheck:Hide(); f.buffThenCDLabel:Hide()
            end
        end

        -- Reminder Buff checkbox
        if f.reminderBuffCheck then
            if isSpellKey or isItemKey then
                f.reminderBuffCheck:Show(); f.reminderBuffLabel:Show()
                f.reminderBuffCheck:SetChecked(isReminderBuff)
            else
                f.reminderBuffCheck:Hide(); f.reminderBuffLabel:Hide()
            end
        end

        -- Show duration / delay / haste for ANY key with buff mode
        if f.buffDurLabel then f.buffDurLabel:SetShown(hasBuffMode) end
        if f.buffDurEdit then
            f.buffDurEdit:SetShown(hasBuffMode)
            if hasBuffMode then
                local dur = (s and s.autoBuffDuration) or (isReminderBuff and 3600 or 10)
                dur = math.floor(tonumber(dur) * 1000 + 0.5) / 1000
                f.buffDurEdit:SetText(tostring(dur))
            end
        end
        -- Buff delay
        if f.buffDelayLabel then f.buffDelayLabel:SetShown(hasBuffMode) end
        if f.buffDelayEdit then
            f.buffDelayEdit:SetShown(hasBuffMode)
            if hasBuffMode then
                local d = (s and s.autoBuffDelay) or 0
                d = math.floor(tonumber(d) * 1000 + 0.5) / 1000
                f.buffDelayEdit:SetText(tostring(d))
            end
        end
        -- Haste scaling toggle (only visible for buff modes)
        if f.hasteScaleCheck then
            f.hasteScaleCheck:SetShown(hasBuffMode)
            f.hasteScaleLabel:SetShown(hasBuffMode)
            if hasBuffMode then
                f.hasteScaleCheck:SetChecked((s and s.hasteScaling) and true or false)
            end
        end

        -- Reminder-specific settings (only visible when REMINDER_BUFF)
        local showReminder = isReminderBuff
        if f.reminderPersistDeathCheck then
            f.reminderPersistDeathCheck:SetShown(showReminder)
            f.reminderPersistDeathLabel:SetShown(showReminder)
            if showReminder then
                f.reminderPersistDeathCheck:SetChecked((s and s.reminderPersistDeath) and true or false)
            end
        end
        if f.reminderShowTimerCheck then
            f.reminderShowTimerCheck:SetShown(showReminder)
            f.reminderShowTimerLabel:SetShown(showReminder)
            if showReminder then
                f.reminderShowTimerCheck:SetChecked((s and s.reminderShowTimer) and true or false)
            end
        end
        if f.reminderTextLabel then f.reminderTextLabel:SetShown(showReminder) end
        if f.reminderTextEdit then
            f.reminderTextEdit:SetShown(showReminder)
            if showReminder then
                f.reminderTextEdit:SetText((s and s.reminderText) or "MISSING!")
            end
        end
        if f.reminderFontSizeLabel then f.reminderFontSizeLabel:SetShown(showReminder) end
        if f.reminderFontSizeEdit then
            f.reminderFontSizeEdit:SetShown(showReminder)
            if showReminder then
                f.reminderFontSizeEdit:SetText(tostring((s and s.reminderFontSize) or 12))
            end
        end
        if f.reminderColorLabel then f.reminderColorLabel:SetShown(showReminder) end
        for ci = 1, 4 do
            local cb = f["reminderColor" .. ci]
            if cb then cb:SetShown(showReminder) end
        end

        -- Charges checkbox
        local isCharges = (s and s.auraMode == "CHARGES") and true or false
        if f.chargesCheck then
            if isSpellKey or isItemKey then
                f.chargesCheck:Show(); f.chargesLabel:Show()
                f.chargesCheck:SetChecked(isCharges)
            else
                f.chargesCheck:Hide(); f.chargesLabel:Hide()
            end
        end

        -- Dynamic re-anchoring: collapse gaps when sub-sections are hidden
        -- Reminder checkbox: anchor to hasteScale (visible) or buffThenCD (hidden)
        if f.reminderBuffCheck then
            f.reminderBuffCheck:ClearAllPoints()
            if hasBuffMode and f.hasteScaleCheck then
                f.reminderBuffCheck:SetPoint("TOPLEFT", f.hasteScaleCheck, "BOTTOMLEFT", 0, -6)
            elseif f.buffThenCDCheck and f.buffThenCDCheck:IsShown() then
                f.reminderBuffCheck:SetPoint("TOPLEFT", f.buffThenCDCheck, "BOTTOMLEFT", 0, -6)
            elseif f.autoBuffCheck and f.autoBuffCheck:IsShown() then
                f.reminderBuffCheck:SetPoint("TOPLEFT", f.autoBuffCheck, "BOTTOMLEFT", 0, -6)
            else
                f.reminderBuffCheck:SetPoint("TOPLEFT", f.dropZone, "BOTTOMLEFT", -4, -8)
            end
        end
        -- Charges checkbox: anchor to reminder sub-settings (visible) or reminderBuff (hidden)
        if f.chargesCheck then
            f.chargesCheck:ClearAllPoints()
            if showReminder and f.reminderColorLabel then
                f.chargesCheck:SetPoint("TOPLEFT", f.reminderColorLabel, "BOTTOMLEFT", -22, -10)
            elseif f.reminderBuffCheck and f.reminderBuffCheck:IsShown() then
                f.chargesCheck:SetPoint("TOPLEFT", f.reminderBuffCheck, "BOTTOMLEFT", 0, -6)
            elseif f.buffThenCDCheck and f.buffThenCDCheck:IsShown() then
                f.chargesCheck:SetPoint("TOPLEFT", f.buffThenCDCheck, "BOTTOMLEFT", 0, -6)
            else
                f.chargesCheck:SetPoint("TOPLEFT", f.dropZone, "BOTTOMLEFT", -4, -8)
            end
        end
        -- Anchor label: anchor to chargesCheck (visible) or previous visible element
        if f._anchorLabel then
            f._anchorLabel:ClearAllPoints()
            if f.chargesCheck and f.chargesCheck:IsShown() then
                f._anchorLabel:SetPoint("TOPLEFT", f.chargesCheck, "BOTTOMLEFT", 0, -10)
            elseif f.reminderBuffCheck and f.reminderBuffCheck:IsShown() then
                f._anchorLabel:SetPoint("TOPLEFT", f.reminderBuffCheck, "BOTTOMLEFT", 0, -10)
            else
                f._anchorLabel:SetPoint("TOPLEFT", f.dropZone, "BOTTOMLEFT", -4, -8)
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
            local currentKey = (s2 and s2.textFontKey) or (db and db.fontKey) or "DEFAULT"

            for _, data in ipairs(MSWA.fontChoices or {}) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = data.label or data.key
                info.value = data.key
                info.checked = (data.key == currentKey)
                info.func = function()
                    local key = MSWA.selectedSpellID
                    local db2 = MSWA_GetDB()
                    if key then
                        db2.spellSettings = db2.spellSettings or {}
                        local t = db2.spellSettings
                        local ss = t[key] or t[tostring(key)]
                        if not ss then ss = {}; t[key] = ss end
                        if data.key == "DEFAULT" then ss.textFontKey = nil else ss.textFontKey = data.key end
                    else
                        -- No aura selected => set global default
                        db2.fontKey = (data.key == "DEFAULT") and "DEFAULT" or data.key
                    end
                    UIDropDownMenu_SetSelectedValue(f.fontDrop, data.key)
                    UIDropDownMenu_SetText(f.fontDrop, data.label or data.key)
                    if f.fontPreview and MSWA.fontLookup then
                        local fontPath = MSWA.fontLookup[data.key]
                        if data.key == "DEFAULT" or not fontPath then
                            f.fontPreview:SetFontObject(GameFontNormalSmall)
                        else f.fontPreview:SetFont(fontPath, 12, "") end
                    end
                    if MSWA_ForceUpdateSpells then MSWA_ForceUpdateSpells() else MSWA_RequestUpdateSpells() end
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        f._mswaFontDropInitialized = true
    end

    local db = MSWA_GetDB()
    local auraKey = MSWA.selectedSpellID
    if UIDropDownMenu_EnableDropDown then UIDropDownMenu_EnableDropDown(f.fontDrop) end

    local ss = auraKey and (select(1, MSWA_GetSpellSettings(db, auraKey)) or {}) or nil
    local fontKey = (ss and ss.textFontKey) or (db and db.fontKey) or "DEFAULT"
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

    -- Resizable
    if f.SetResizable then f:SetResizable(true) end
    if f.SetResizeBounds then
        f:SetResizeBounds(700, 400, 1200, 800)
    elseif f.SetMinResize then
        f:SetMinResize(700, 400); f:SetMaxResize(1200, 800)
    end

    -- Resize grip (bottom-right corner)
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function(self) f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function(self) f:StopMovingOrSizing() end)
    f.resizeGrip = grip

    -- Title (left) + Version (right)
    -- NOTE: Never use space-padding to "push" version text; it breaks under scaling and different fonts.
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("LEFT", f.TitleBg, "LEFT", 10, 0)
    f.title:SetText("Midnight Simple Auras")

    f.versionText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.versionText:SetText("Version 1.40")
    -- Anchor against the close button when available so it always stays top-right.
    local closeBtn = f.CloseButton or _G[f:GetName() .. "CloseButton"]
    if closeBtn then
        f.versionText:SetPoint("RIGHT", closeBtn, "LEFT", -8, 0)
        f.versionText:SetPoint("TOP", f.TitleBg, "TOP", 0, -1)
    else
        -- Fallback: hard top-right with safe padding.
        f.versionText:SetPoint("TOPRIGHT", f.TitleBg, "TOPRIGHT", -8, -1)
    end

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

    f.btnIDInfo = CreateFrame("Button", nil, f, "UIPanelButtonTemplate"); f.btnIDInfo:SetSize(60, 22)
    f.btnIDInfo:SetPoint("LEFT", f.btnPreview, "RIGHT", 6, 0); f.btnIDInfo:SetText("ID Info")

    -- Scroll frame + rows
    local rowHeight = 24
    local MAX_VISIBLE_ROWS = 28  -- pre-create enough for largest window
    f.rowHeight = rowHeight

    function f:GetVisibleRows()
        local h = self.listPanel and self.listPanel:GetHeight() or 336
        return math.max(4, math.floor((h - 30) / rowHeight))
    end

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
        inlineEdit:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        inlineEdit:SetText(currentText or "")
        inlineEdit:Show()
        inlineEdit:SetFocus()
        inlineEdit:HighlightText()
    end

    -- Global helpers so the context menu can trigger inline rename
    function MSWA_ShowInlineRenameForKey(key, defaultText)
        if not f.rows then return end
        for _, row in ipairs(f.rows) do
            if row.entryType == "AURA" and row.key == key and row:IsShown() then
                ShowInlineRename(row, defaultText, key, nil); return
            end
        end
    end
    function MSWA_ShowInlineRenameForGroup(gid, defaultText)
        if not f.rows then return end
        for _, row in ipairs(f.rows) do
            if row.entryType == "GROUP" and row.groupID == gid and row:IsShown() then
                ShowInlineRename(row, defaultText, nil, gid); return
            end
        end
    end

    -- Double-click state (per-row tracking)
    local lastClickRow = nil
    local lastClickTime = 0
    local DOUBLECLICK_THRESHOLD = 0.35

    f.rows = {}


-- Layout list row text (no inline buttons — context menu handles actions)
local function MSWA_LayoutListRowText(row)
    if not row or not row.text or not row.icon then return end
    row.text:ClearAllPoints()
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 6 + (row.indent or 0), 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
end

    -- Multi-select state (Shift+Click range selection)
    MSWA._multiSelect = {}   -- key → true
    f._lastClickIdx = nil    -- entry index of last normal click
    f._lastEntries = nil     -- cached entries from last UpdateAuraList

    local function ClearMultiSelect()
        wipe(MSWA._multiSelect)
        f._lastClickIdx = nil
    end

    local function MultiSelectCount()
        local n = 0
        for _ in pairs(MSWA._multiSelect) do n = n + 1 end
        return n
    end

    local function GetEntryIdx(entries, key)
        if not entries or not key then return nil end
        for i = 1, #entries do
            if entries[i].entryType == "AURA" and entries[i].key == key then return i end
        end
        return nil
    end

    for i = 1, MAX_VISIBLE_ROWS do
        local row = CreateFrame("Button", "MSWA_AuraRow" .. i, listPanel)
        row:SetSize(282, rowHeight); row:SetPoint("TOPLEFT", 8, -24 - (i - 1) * rowHeight)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

        row.icon = row:CreateTexture(nil, "ARTWORK"); row.icon:SetSize(20, 20); row.icon:SetPoint("LEFT")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0); row.text:SetPoint("RIGHT", row, "RIGHT", -6, 0); row.text:SetJustifyH("LEFT")

        row.sepTop = row:CreateTexture(nil, "BORDER"); row.sepTop:SetColorTexture(1, 1, 1, 0.12)
        row.sepTop:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0); row.sepTop:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
        row.sepTop:SetHeight(1); row.sepTop:Hide()

        row.sepBottom = row:CreateTexture(nil, "BORDER"); row.sepBottom:SetColorTexture(1, 1, 1, 0.12)
        row.sepBottom:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0); row.sepBottom:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        row.sepBottom:SetHeight(1); row.sepBottom:Hide()

        row.selectedTex = row:CreateTexture(nil, "BACKGROUND"); row.selectedTex:SetAllPoints(true)
        row.selectedTex:SetColorTexture(1, 1, 0, 0.15); row.selectedTex:Hide()

        -- Multi-select highlight (cyan tint, distinct from single-select yellow)
        row.multiSelTex = row:CreateTexture(nil, "BACKGROUND"); row.multiSelTex:SetAllPoints(true)
        row.multiSelTex:SetColorTexture(0.2, 0.6, 1, 0.2); row.multiSelTex:Hide()

        -- Drag insert indicator (bright line above or below row)
        row.dragInsertTop = row:CreateTexture(nil, "OVERLAY")
        row.dragInsertTop:SetHeight(2); row.dragInsertTop:SetColorTexture(0.2, 0.8, 1, 0.9)
        row.dragInsertTop:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 1); row.dragInsertTop:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 1)
        row.dragInsertTop:Hide()

        row.dragInsertBot = row:CreateTexture(nil, "OVERLAY")
        row.dragInsertBot:SetHeight(2); row.dragInsertBot:SetColorTexture(0.2, 0.8, 1, 0.9)
        row.dragInsertBot:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, -1); row.dragInsertBot:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, -1)
        row.dragInsertBot:Hide()

        row.isMSWARow = true; row.entryType = nil; row.groupID = nil; row.key = nil; row.indent = 0; row.spellID = nil

        row:RegisterForClicks("AnyUp"); row:RegisterForDrag("LeftButton")
        row:SetScript("OnDragStart", function(self) if self.entryType == "AURA" and self.key ~= nil then MSWA_BeginListDrag(self.key) end end)
        row:SetScript("OnDragStop", function(self) if MSWA._isDraggingList then MSWA_EndListDrag() end end)

        row:SetScript("OnClick", function(self, button)
            if MSWA._isDraggingList then return end

            -- Right-click: context menu (works with multi-select)
            if button == "RightButton" then
                -- If right-clicking an aura NOT in multi-select, or a non-aura row, clear multi-select
                if MultiSelectCount() > 0 then
                    local keepMulti = self.entryType == "AURA" and self.key and MSWA._multiSelect[self.key]
                    if not keepMulti then
                        ClearMultiSelect()
                        MSWA_RefreshOptionsList()
                    end
                end
                MSWA_ShowListContextMenu(self)
                return
            end

            local now = GetTime()
            local isDoubleClick = (lastClickRow == self) and (now - lastClickTime) < DOUBLECLICK_THRESHOLD
            lastClickRow = self
            lastClickTime = now

            -- Shift+Click: range select auras
            if IsShiftKeyDown() and self.entryType == "AURA" and self.key ~= nil and f._lastClickIdx and f._lastEntries then
                local entries = f._lastEntries
                local clickIdx = GetEntryIdx(entries, self.key)
                if clickIdx then
                    local fromIdx = math.min(f._lastClickIdx, clickIdx)
                    local toIdx   = math.max(f._lastClickIdx, clickIdx)
                    for ei = fromIdx, toIdx do
                        local e = entries[ei]
                        if e and e.entryType == "AURA" and e.key ~= nil then
                            MSWA._multiSelect[e.key] = true
                        end
                    end
                    -- Ensure the anchor aura is also in multi-select
                    if MSWA.selectedSpellID then
                        MSWA._multiSelect[MSWA.selectedSpellID] = true
                    end
                    MSWA_RefreshOptionsList()
                    return
                end
            end

            if self.entryType == "AURA" and self.key ~= nil then
                ClearMultiSelect()
                if isDoubleClick then
                    -- Double-click: inline rename
                    local db = MSWA_GetDB()
                    local currentName = (db.customNames and db.customNames[self.key]) or ""
                    if currentName == "" then currentName = MSWA_GetDisplayNameForKey(self.key) or "" end
                    ShowInlineRename(self, currentName, self.key, nil)
                    return
                end
                -- Track entry index for shift-range
                if f._lastEntries then
                    f._lastClickIdx = GetEntryIdx(f._lastEntries, self.key)
                end
                MSWA.selectedSpellID = self.key; MSWA.selectedGroupID = nil; MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList(); return
            end
            if self.entryType == "GROUP" and self.groupID then
                ClearMultiSelect()
                if isDoubleClick then
                    -- Double-click: inline rename group
                    local db = MSWA_GetDB()
                    local g = db.groups and db.groups[self.groupID]
                    local currentName = (g and g.name) or ""
                    ShowInlineRename(self, currentName, nil, self.groupID)
                    return
                end
                MSWA.selectedGroupID = self.groupID; MSWA.selectedSpellID = nil; MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList(); return
            end
            if self.entryType == "UNGROUPED" then
                ClearMultiSelect()
                MSWA.selectedSpellID = nil; MSWA.selectedGroupID = nil; MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList()
            end
        end)

        f.rows[i] = row
    end

    -----------------------------------------------------------
    -- Drag reorder system
    -----------------------------------------------------------

    -- Hide all drag insert indicators
    local function HideDragIndicators()
        for _, r in ipairs(f.rows) do
            if r.dragInsertTop then r.dragInsertTop:Hide() end
            if r.dragInsertBot then r.dragInsertBot:Hide() end
        end
        MSWA._dragDropTarget = nil
        MSWA._dragDropAfter  = nil
    end

    -- Insert aura at a specific position relative to a target aura
    function MSWA_InsertAuraAtPosition(dragKey, targetKey, insertAfter)
        if dragKey == nil or targetKey == nil or dragKey == targetKey then return end
        local db = MSWA_GetDB()
        db.auraGroups = db.auraGroups or {}
        db.groupMembers = db.groupMembers or {}
        db.spellSettings = db.spellSettings or {}

        local targetGid = db.auraGroups[targetKey]
        local dragGid   = db.auraGroups[dragKey]

        if targetGid and db.groups and db.groups[targetGid] then
            -- Target is in a group: insert drag key into that group
            -- Remove from previous group's member list
            if dragGid and dragGid ~= targetGid and db.groupMembers[dragGid] then
                for i = #db.groupMembers[dragGid], 1, -1 do
                    if db.groupMembers[dragGid][i] == dragKey then
                        table.remove(db.groupMembers[dragGid], i); break
                    end
                end
            end

            -- Assign to target group
            db.auraGroups[dragKey] = targetGid
            local s = db.spellSettings[dragKey] or {}
            s.anchorFrame = nil
            db.spellSettings[dragKey] = s

            local members = MSWA_EnsureGroupMembers(targetGid) or {}
            -- Remove dragKey if already present
            for i = #members, 1, -1 do
                if members[i] == dragKey then table.remove(members, i); break end
            end
            -- Find target index
            local targetIdx = nil
            for i = 1, #members do
                if members[i] == targetKey then targetIdx = i; break end
            end
            if not targetIdx then targetIdx = #members end
            local newIdx = insertAfter and (targetIdx + 1) or targetIdx
            table.insert(members, newIdx, dragKey)

            -- Recalculate x/y for all members in the group
            local group = db.groups[targetGid]
            local size = (group and group.size) or MSWA.ICON_SIZE
            for i = 1, #members do
                local ms = db.spellSettings[members[i]] or {}
                ms.x = (i - 1) * (size + MSWA.ICON_SPACE)
                ms.y = 0
                ms.width  = ms.width  or size
                ms.height = ms.height or size
                db.spellSettings[members[i]] = ms
            end
            -- Also recalculate old group if changed groups
            if dragGid and dragGid ~= targetGid and db.groupMembers[dragGid] then
                local oldGroup = db.groups[dragGid]
                local oldSize = (oldGroup and oldGroup.size) or MSWA.ICON_SIZE
                local oldMembers = db.groupMembers[dragGid]
                for i = 1, #oldMembers do
                    local ms = db.spellSettings[oldMembers[i]] or {}
                    ms.x = (i - 1) * (oldSize + MSWA.ICON_SPACE)
                    ms.y = 0
                    db.spellSettings[oldMembers[i]] = ms
                end
            end
        else
            -- Target is ungrouped: remove drag from its group, place ungrouped
            if dragGid and db.groupMembers[dragGid] then
                for i = #db.groupMembers[dragGid], 1, -1 do
                    if db.groupMembers[dragGid][i] == dragKey then
                        table.remove(db.groupMembers[dragGid], i); break
                    end
                end
                -- Recalculate old group
                local oldGroup = db.groups and db.groups[dragGid]
                local oldSize = (oldGroup and oldGroup.size) or MSWA.ICON_SIZE
                local oldMembers = db.groupMembers[dragGid]
                for i = 1, #oldMembers do
                    local ms = db.spellSettings[oldMembers[i]] or {}
                    ms.x = (i - 1) * (oldSize + MSWA.ICON_SPACE)
                    ms.y = 0
                    db.spellSettings[oldMembers[i]] = ms
                end
            end
            -- Preserve position offset when leaving group
            local s = db.spellSettings[dragKey] or {}
            if dragGid and db.groups and db.groups[dragGid] then
                local g = db.groups[dragGid]
                s.x = (s.x or 0) + (g.x or 0)
                s.y = (s.y or 0) + (g.y or 0)
                if g.anchorFrame and g.anchorFrame ~= "" then s.anchorFrame = g.anchorFrame end
            end
            db.spellSettings[dragKey] = s
            db.auraGroups[dragKey] = nil
        end
    end

    -- Hook drag overlay OnUpdate to show insert indicators on hovered rows
    local function DragOverlay_OnUpdate_Hook()
        if not MSWA._isDraggingList or not MSWA._dragKey then
            HideDragIndicators(); return
        end
        HideDragIndicators()

        local focus = MSWA_GetMouseFocusFrame and MSWA_GetMouseFocusFrame() or nil
        local row = focus and MSWA_FindMSWARowFromFocus(focus) or nil
        if not row or not row:IsShown() then return end

        -- Only show insert indicator on aura rows and group/ungrouped headers
        if row.entryType == "GROUP" or row.entryType == "UNGROUPED" then
            -- Existing group/ungroup drop (highlight the row)
            row.dragInsertBot:Show()
            MSWA._dragDropTarget = row
            MSWA._dragDropAfter  = nil
            return
        end

        if row.entryType ~= "AURA" or row.key == nil then return end
        if row.key == MSWA._dragKey then return end  -- don't show on self

        -- Determine top/bottom half of row
        local _, rowY = row:GetCenter()
        local _, cursorY = GetCursorPosition()
        local scale = row:GetEffectiveScale() or 1
        cursorY = cursorY / scale

        local insertAfter = cursorY < rowY
        if insertAfter then
            row.dragInsertBot:Show()
        else
            row.dragInsertTop:Show()
        end
        MSWA._dragDropTarget = row
        MSWA._dragDropAfter  = insertAfter
    end

    -- Hook the overlay once it's created
    local origBeginDrag = MSWA_BeginListDrag
    function MSWA_BeginListDrag(key)
        origBeginDrag(key)
        -- Attach our indicator update to the overlay
        local overlay = MSWA.dragOverlay
        if overlay and not overlay._mswaHooked then
            local origOnUpdate = overlay:GetScript("OnUpdate")
            overlay:SetScript("OnUpdate", function(self, ...)
                if origOnUpdate then origOnUpdate(self, ...) end
                DragOverlay_OnUpdate_Hook()
            end)
            overlay._mswaHooked = true
        end
    end

    -- Override EndListDrag to handle aura-to-aura drops
    function MSWA_EndListDrag()
        local overlay = MSWA.dragOverlay
        local key = MSWA._dragKey
        local dropTarget = MSWA._dragDropTarget
        local dropAfter  = MSWA._dragDropAfter

        MSWA._dragKey = nil
        MSWA._isDraggingList = false
        MSWA._dragDropTarget = nil
        MSWA._dragDropAfter  = nil

        HideDragIndicators()

        if overlay then
            overlay:Hide()
            if overlay._iconFrame then overlay._iconFrame:Hide() end
        end
        if not key then return end

        pcall(function()
            -- Use our stored drop target first (accurate indicator-based)
            local row = dropTarget
            if not row then
                -- Fallback to mouse focus
                local focus = MSWA_GetMouseFocusFrame and MSWA_GetMouseFocusFrame() or nil
                row = focus and MSWA_FindMSWARowFromFocus(focus) or nil
            end

            if not row then return end

            if row.entryType == "AURA" and row.key ~= nil and row.key ~= key then
                -- Aura-to-aura: reorder/move
                MSWA_InsertAuraAtPosition(key, row.key, dropAfter)
            elseif row.entryType == "GROUP" and row.groupID then
                -- Drop on group header: add to end (existing behavior)
                MSWA_SetAuraGroup(key, row.groupID)
            elseif row.entryType == "UNGROUPED" then
                -- Drop on ungrouped: remove from group
                MSWA_SetAuraGroup(key, nil)
            end
        end)

        if f and f.UpdateAuraList then pcall(function() f:UpdateAuraList() end) end
        if MSWA_RequestUpdateSpells then pcall(MSWA_RequestUpdateSpells) end
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
        f._lastEntries = entries  -- cache for shift-range selection
        local selectedKey = MSWA.selectedSpellID
        local selectedGroup = MSWA.selectedGroupID
        local multiSel = MSWA._multiSelect
        local total = #entries
        local visibleRows = self:GetVisibleRows()
        FauxScrollFrame_Update(scrollFrame, total, visibleRows, rowHeight)
        local offset = FauxScrollFrame_GetOffset(scrollFrame) or 0

        for i = 1, visibleRows do
            local row = self.rows[i]
            local idx = offset + i
            local entry = entries[idx]
            if entry then
                row.entryType = entry.entryType; row.groupID = entry.groupID; row.key = entry.key; row.indent = entry.indent or 0
                row:Show(); row.selectedTex:Hide(); row.multiSelTex:Hide(); row.dragInsertTop:Hide(); row.dragInsertBot:Hide()
                if row.sepTop then row.sepTop:Hide() end; if row.sepBottom then row.sepBottom:Hide() end
                row.icon:SetTexture(nil); row:SetAlpha(1)
                if row.icon.SetDesaturated then row.icon:SetDesaturated(false) end
                MSWA_LayoutListRowText(row)
                if entry.groupStart and row.sepTop then
                    row.sepTop:SetHeight(entry.thickTop and 2 or 1); row.sepTop:Show()
                end
                if entry.groupEnd and row.sepBottom then
                    row.sepBottom:SetHeight(entry.thickBottom and 2 or 1); row.sepBottom:Show()
                end
                if entry.entryType == "GROUP" then
                    local g = db.groups and db.groups[entry.groupID] or nil
                    row.text:SetText(g and g.name or "Group"); row.icon:SetTexture(nil)
                    if selectedGroup and selectedGroup == entry.groupID then row.selectedTex:Show() end
                elseif entry.entryType == "UNGROUPED" then
                    row.text:SetText("Ungrouped"); row.icon:SetTexture(nil)
                elseif entry.entryType == "NOTLOADED" then
                    row.text:SetText("Not Loaded"); row.icon:SetTexture(nil)
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
                    if selectedKey ~= nil and selectedKey == key then row.selectedTex:Show() end
                    -- Multi-select highlight (cyan)
                    if key and multiSel[key] then row.multiSelTex:Show() end
                end
            else
                row.entryType = nil; row.groupID = nil; row.key = nil; row.indent = 0; row.spellID = nil
                row.icon:SetTexture(nil); row.text:SetText(""); row.selectedTex:Hide(); row.multiSelTex:Hide(); row.dragInsertTop:Hide(); row.dragInsertBot:Hide()
                if row.sepTop then row.sepTop:Hide() end; if row.sepBottom then row.sepBottom:Hide() end
                row:Hide()
            end
        end
        -- Hide extra pre-created rows beyond current visibleRows
        for i = visibleRows + 1, MAX_VISIBLE_ROWS do
            local row = self.rows[i]
            if row then
                row.entryType = nil; row.groupID = nil; row.key = nil; row.indent = 0; row.spellID = nil
                row.icon:SetTexture(nil); row.text:SetText(""); row.selectedTex:Hide(); row.multiSelTex:Hide(); row.dragInsertTop:Hide(); row.dragInsertBot:Hide()
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

    local tabW, tabH = 80, 20
    local function SetActiveTab(tabKey)
        f.activeTab = tabKey
        if f.tabGeneral then f.tabGeneral:UnlockHighlight() end
        if f.tabDisplay then f.tabDisplay:UnlockHighlight() end
        if f.tabGlow then f.tabGlow:UnlockHighlight() end
        if f.tabImport then f.tabImport:UnlockHighlight() end
        if tabKey == "GENERAL" and f.tabGeneral then f.tabGeneral:LockHighlight() end
        if tabKey == "DISPLAY" and f.tabDisplay then f.tabDisplay:LockHighlight() end
        if tabKey == "GLOW" and f.tabGlow then f.tabGlow:LockHighlight() end
        if tabKey == "IMPORT" and f.tabImport then f.tabImport:LockHighlight() end
        MSWA_UpdateDetailPanel()
    end

    f.tabGeneral = CreateFrame("Button", nil, rightPanel, "UIPanelButtonTemplate"); f.tabGeneral:SetSize(tabW, tabH)
    f.tabGeneral:SetPoint("TOPLEFT", 14, -36); f.tabGeneral:SetText("General")
    f.tabDisplay = CreateFrame("Button", nil, rightPanel, "UIPanelButtonTemplate"); f.tabDisplay:SetSize(tabW, tabH)
    f.tabDisplay:SetPoint("LEFT", f.tabGeneral, "RIGHT", 4, 0); f.tabDisplay:SetText("Display")
    f.tabGlow = CreateFrame("Button", nil, rightPanel, "UIPanelButtonTemplate"); f.tabGlow:SetSize(tabW, tabH)
    f.tabGlow:SetPoint("LEFT", f.tabDisplay, "RIGHT", 4, 0); f.tabGlow:SetText("Glow")
    f.tabImport = CreateFrame("Button", nil, rightPanel, "UIPanelButtonTemplate"); f.tabImport:SetSize(tabW, tabH)
    f.tabImport:SetPoint("LEFT", f.tabGlow, "RIGHT", 4, 0); f.tabImport:SetText("Load Info")

    f.tabGeneral:SetScript("OnClick", function() SetActiveTab("GENERAL") end)
    f.tabDisplay:SetScript("OnClick", function() SetActiveTab("DISPLAY") end)
    f.tabGlow:SetScript("OnClick", function() SetActiveTab("GLOW") end)
    f.tabImport:SetScript("OnClick", function() SetActiveTab("IMPORT") end)
    f.activeTab = "GENERAL"; f.tabGeneral:LockHighlight()

    f.emptyPanel = CreateFrame("Frame", nil, rightPanel)
    f.emptyPanel:SetPoint("TOPLEFT", 12, -60); f.emptyPanel:SetPoint("BOTTOMRIGHT", -12, 12)
    f.emptyText = f.emptyPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.emptyText:SetPoint("CENTER", 0, 0); f.emptyText:SetText("Select an aura from the list on the left to edit it.")

    -- Load Info (altPanel)
    f.altPanel = CreateFrame("Frame", nil, rightPanel)
    f.altPanel:SetPoint("TOPLEFT", 12, -60); f.altPanel:SetPoint("BOTTOMRIGHT", -12, 12); f.altPanel:Hide()

    -- Scroll frame inside altPanel (prevents clipping on small windows)
    local altScroll = CreateFrame("ScrollFrame", "MSWA_LoadInfoScrollFrame", f.altPanel, "UIPanelScrollFrameTemplate")
    altScroll:SetPoint("TOPLEFT", 0, 0)
    altScroll:SetPoint("BOTTOMRIGHT", -26, 0)
    f._altScroll = altScroll

    local altContent = CreateFrame("Frame")
    altContent:SetWidth(400)
    altScroll:SetScrollChild(altContent)
    f._altContent = altContent

    altScroll:SetScript("OnSizeChanged", function(self, w)
        if w and w > 30 then altContent:SetWidth(w) end
    end)

    f.altTitle = altContent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.altTitle:SetPoint("TOPLEFT", altContent, "TOPLEFT", 16, -16); f.altTitle:SetText("|cffffcc00Load settings|r")

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
    f.loadNeverCheck = CreateFrame("CheckButton", nil, altContent, "UICheckButtonTemplate")
    f.loadNeverCheck:SetPoint("TOPLEFT", f.altTitle, "BOTTOMLEFT", -2, -12)
    f.loadNeverCheck.text = f.loadNeverCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.loadNeverCheck.text:SetPoint("LEFT", f.loadNeverCheck, "RIGHT", 4, 0)
    f.loadNeverCheck.text:SetText("|cffff4040Never (disable)|r")
    f.loadNeverCheck:EnableMouse(false)

    f.loadNeverRow = CreateFrame("Button", nil, altContent)
    f.loadNeverRow:SetFrameLevel(f.loadNeverCheck:GetFrameLevel() - 1)
    f.loadNeverRow:SetPoint("TOPLEFT", f.loadNeverCheck, "TOPLEFT", 0, 0)
    f.loadNeverRow:SetPoint("BOTTOMRIGHT", f.loadNeverCheck.text, "BOTTOMRIGHT", 0, 0)
    f.loadNeverRow:EnableMouse(true)

    f.loadCombatButton = CreateFrame("Button", nil, altContent, "UIPanelButtonTemplate")
    f.loadCombatButton:SetSize(210, 22); f.loadCombatButton:SetPoint("TOPLEFT", f.loadNeverCheck, "BOTTOMLEFT", 22, -10)

    f.loadEncounterButton = CreateFrame("Button", nil, altContent, "UIPanelButtonTemplate")
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

    f.loadCharLabel = altContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.loadCharLabel:SetPoint("TOPLEFT", f.loadCombatButton, "BOTTOMLEFT", -22, -14)
    f.loadCharLabel:SetText("|cffffcc00Character (Name-Realm):|r")

    f.loadCharEdit = CreateFrame("EditBox", nil, altContent, "InputBoxTemplate")
    f.loadCharEdit:SetSize(260, 22); f.loadCharEdit:SetAutoFocus(false)
    f.loadCharEdit:SetPoint("LEFT", f.loadCharLabel, "RIGHT", 8, 0); f.loadCharEdit:SetTextInsets(6, 6, 0, 0)

    f.loadCharMeBtn = CreateFrame("Button", nil, altContent, "UIPanelButtonTemplate")
    f.loadCharMeBtn:SetSize(50, 22); f.loadCharMeBtn:SetPoint("LEFT", f.loadCharEdit, "RIGHT", 4, 0)
    f.loadCharMeBtn:SetText("|cff00ff00Me|r")

    -- Class dropdown
    f.loadClassLabel = altContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.loadClassLabel:SetPoint("TOPLEFT", f.loadCharLabel, "BOTTOMLEFT", 0, -16)
    f.loadClassLabel:SetText("|cffffcc00Class:|r")

    f.loadClassDrop = CreateFrame("Frame", "MSWA_LoadClassDropDown", altContent, "UIDropDownMenuTemplate")
    f.loadClassDrop:SetPoint("LEFT", f.loadClassLabel, "RIGHT", -10, -3)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(f.loadClassDrop, 160) end

    -- Spec dropdown
    f.loadSpecLabel = altContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.loadSpecLabel:SetPoint("LEFT", f.loadClassDrop, "RIGHT", 4, 3)
    f.loadSpecLabel:SetText("|cffffcc00Spec:|r")

    f.loadSpecDrop = CreateFrame("Frame", "MSWA_LoadSpecDropDown", altContent, "UIDropDownMenuTemplate")
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

    f.altText = altContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.altText:SetPoint("TOPLEFT", 10, -10); f.altText:SetWidth(440); f.altText:SetJustifyH("LEFT"); f.altText:SetWordWrap(true); f.altText:SetText("")

    -- Set scroll child height for Load Info
    altContent:SetHeight(340)

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

    local gpAnchorLabel = f.groupPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal"); gpAnchorLabel:SetPoint("TOPLEFT", gpSizeLabel, "BOTTOMLEFT", 0, -18); gpAnchorLabel:SetText("Anchor Frame")
    f.groupAnchorEdit = CreateFrame("EditBox", nil, f.groupPanel, "InputBoxTemplate"); f.groupAnchorEdit:SetAutoFocus(false); f.groupAnchorEdit:SetSize(220, 22); f.groupAnchorEdit:SetPoint("LEFT", gpAnchorLabel, "RIGHT", 10, 0)
    f.groupAnchorEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyGroupSettings() end)
    f.groupAnchorEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local function ApplyGroupSettings()
        local db = MSWA_GetDB(); local gid = MSWA.selectedGroupID; local g = gid and db.groups and db.groups[gid]; if not g then return end
        local x = tonumber(f.groupXEdit:GetText()) or g.x or 0
        local y = tonumber(f.groupYEdit:GetText()) or g.y or 0
        local size = tonumber(f.groupSizeEdit:GetText()) or g.size or MSWA.ICON_SIZE
        local anchorFrame = f.groupAnchorEdit and f.groupAnchorEdit:GetText() or ""
        anchorFrame = anchorFrame and anchorFrame:gsub("^%s+", ""):gsub("%s+$", "") or ""
        if size < 8 then size = 8 end
        g.x = x; g.y = y
        g.anchorFrame = (anchorFrame ~= "" and anchorFrame) or nil
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
        g.size = size
        if MSWA_ForceUpdateSpells then MSWA_ForceUpdateSpells() else MSWA_RequestUpdateSpells() end
    end

    local function HookAutoApply(editBox)
        if not editBox then return end
        editBox:SetScript("OnEnterPressed", function(self)
            self._mswaSkipApply = nil
            self:ClearFocus() -- triggers OnEditFocusLost
        end)
        editBox:SetScript("OnEscapePressed", function(self)
            self._mswaSkipApply = true
            self:ClearFocus() -- OnEditFocusLost will resync instead of applying
        end)
        editBox:SetScript("OnEditFocusLost", function(self)
            if self._mswaSkipApply then
                self._mswaSkipApply = nil
                if f.groupPanel and f.groupPanel.Sync then f.groupPanel:Sync() end
                return
            end
            ApplyGroupSettings()
        end)
    end
    HookAutoApply(f.groupXEdit); HookAutoApply(f.groupYEdit); HookAutoApply(f.groupSizeEdit)
    if f.groupAnchorEdit then HookAutoApply(f.groupAnchorEdit) end

    function f.groupPanel:Sync()
        local db = MSWA_GetDB(); local gid = MSWA.selectedGroupID; local g = gid and db.groups and db.groups[gid]; if not g then return end
        f.groupNameEdit:SetText(g.name or ""); f.groupXEdit:SetText(tostring(g.x or 0))
        f.groupYEdit:SetText(tostring(g.y or 0)); f.groupSizeEdit:SetText(tostring(g.size or MSWA.ICON_SIZE))
        if f.groupAnchorEdit then f.groupAnchorEdit:SetText(g.anchorFrame or "") end
    end

    -- =========================================================
    -- Glow tab panel  (LibCustomGlow integration)
    -- =========================================================
    f.glowPanel2 = CreateFrame("Frame", nil, rightPanel)
    f.glowPanel2:SetPoint("TOPLEFT", 12, -60); f.glowPanel2:SetPoint("BOTTOMRIGHT", -12, 12); f.glowPanel2:Hide()

    -- Scroll frame inside glowPanel2 (prevents clipping on small windows)
    local glowScroll = CreateFrame("ScrollFrame", "MSWA_GlowScrollFrame", f.glowPanel2, "UIPanelScrollFrameTemplate")
    glowScroll:SetPoint("TOPLEFT", 0, 0)
    glowScroll:SetPoint("BOTTOMRIGHT", -26, 0)
    f._glowScroll = glowScroll

    local glowContent = CreateFrame("Frame")
    glowContent:SetWidth(400)
    glowScroll:SetScrollChild(glowContent)
    f._glowContent = glowContent

    glowScroll:SetScript("OnSizeChanged", function(self, w)
        if w and w > 30 then glowContent:SetWidth(w) end
    end)

    local glowAvailable = MSWA_IsGlowAvailable and MSWA_IsGlowAvailable() or false

    local glowTitle = glowContent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    glowTitle:SetPoint("TOPLEFT", 10, -6)
    glowTitle:SetText(glowAvailable and "|cffffcc00Glow Settings|r" or "|cffff4040Glow (LibCustomGlow not found)|r")

    -- Enable checkbox
    f.glowEnableCheck = CreateFrame("CheckButton", nil, glowContent, "ChatConfigCheckButtonTemplate")
    f.glowEnableCheck:SetPoint("TOPLEFT", glowTitle, "BOTTOMLEFT", -4, -10)
    f.glowEnableLabel = glowContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.glowEnableLabel:SetPoint("LEFT", f.glowEnableCheck, "RIGHT", 2, 0)
    f.glowEnableLabel:SetText("Enable Glow")

    -- Glow Type dropdown
    local glowTypeLabel = glowContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    glowTypeLabel:SetPoint("TOPLEFT", f.glowEnableCheck, "BOTTOMLEFT", 4, -12)
    glowTypeLabel:SetText("|cffffcc00Type:|r")
    f.glowTypeDrop = CreateFrame("Frame", "MSWA_GlowTypeDropDown", glowContent, "UIDropDownMenuTemplate")
    f.glowTypeDrop:SetPoint("LEFT", glowTypeLabel, "RIGHT", -10, -3)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(f.glowTypeDrop, 140) end

    UIDropDownMenu_Initialize(f.glowTypeDrop, function(self, level)
        level = level or 1
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = MSWA_GetAuraSettings and MSWA_GetAuraSettings(key) or nil
        local gs = s2 and s2.glow or {}
        local curType = gs.glowType or "PIXEL"

        for _, typeKey in ipairs(MSWA.GLOW_TYPE_ORDER or {}) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = MSWA.GLOW_TYPES[typeKey] or typeKey
            info.value = typeKey
            info.checked = (curType == typeKey)
            info.func = function()
                local k = MSWA.selectedSpellID; if not k then return end
                local ss = MSWA_EnsureAuraSettings(k)
                local g = MSWA_GetOrCreateGlowSettings(ss)
                g.glowType = typeKey
                UIDropDownMenu_SetText(f.glowTypeDrop, MSWA.GLOW_TYPES[typeKey])
                CloseDropDownMenus()
                MSWA_RequestUpdateSpells()
                if f.glowPanel2 and f.glowPanel2.Sync then f.glowPanel2:Sync() end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    -- Glow Color
    local glowColorLabel = glowContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    glowColorLabel:SetPoint("LEFT", f.glowTypeDrop, "RIGHT", 4, 3)
    glowColorLabel:SetText("|cffffcc00Color:|r")
    f.glowColorBtn = CreateFrame("Button", nil, glowContent)
    f.glowColorBtn:SetSize(20, 20); f.glowColorBtn:SetPoint("LEFT", glowColorLabel, "RIGHT", 6, 0); f.glowColorBtn:EnableMouse(true)
    f.glowColorSwatch = f.glowColorBtn:CreateTexture(nil, "ARTWORK"); f.glowColorSwatch:SetAllPoints(true); f.glowColorSwatch:SetColorTexture(0.95, 0.95, 0.32, 1)
    local glowColorBorder = f.glowColorBtn:CreateTexture(nil, "BORDER"); glowColorBorder:SetPoint("TOPLEFT", -1, 1); glowColorBorder:SetPoint("BOTTOMRIGHT", 1, -1); glowColorBorder:SetColorTexture(0, 0, 0, 1)

    f.glowColorBtn:SetScript("OnClick", function()
        local keyAtOpen = MSWA.selectedSpellID; if not keyAtOpen then return end
        local ss = MSWA_GetAuraSettings(keyAtOpen) or {}
        local gs = ss.glow or {}
        local gc = gs.color or { r = 0.95, g = 0.95, b = 0.32, a = 1 }
        local r, g, b = tonumber(gc.r) or 0.95, tonumber(gc.g) or 0.95, tonumber(gc.b) or 0.32

        local function ApplyGlowColor(nr, ng, nb)
            local ss2 = MSWA_EnsureAuraSettings(keyAtOpen)
            local g2 = MSWA_GetOrCreateGlowSettings(ss2)
            g2.color = g2.color or {}
            g2.color.r = nr; g2.color.g = ng; g2.color.b = nb; g2.color.a = 1
            if f.glowColorSwatch then f.glowColorSwatch:SetColorTexture(nr, ng, nb, 1) end
            MSWA_RequestUpdateSpells()
        end

        if ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow then
            local function OnChanged() local nr, ng, nb = ColorPickerFrame:GetColorRGB(); if type(nr) == "number" then ApplyGlowColor(nr, ng, nb) end end
            ColorPickerFrame:SetupColorPickerAndShow({ r=r, g=g, b=b, hasOpacity=false, swatchFunc=OnChanged, func=OnChanged, okayFunc=OnChanged, cancelFunc=function(restore) if type(restore) == "table" then ApplyGlowColor(restore.r or r, restore.g or g, restore.b or b) else ApplyGlowColor(r, g, b) end end })
        elseif ColorPickerFrame then
            ColorPickerFrame.hasOpacity = false; ColorPickerFrame.previousValues = { r=r, g=g, b=b }
            ColorPickerFrame.func = function() ApplyGlowColor(ColorPickerFrame:GetColorRGB()) end
            ColorPickerFrame.cancelFunc = function(prev) if type(prev) == "table" then ApplyGlowColor(prev.r or r, prev.g or g, prev.b or b) else ApplyGlowColor(r, g, b) end end
            ColorPickerFrame:SetColorRGB(r, g, b); ColorPickerFrame:Show()
        end
    end)

    -- Condition dropdown
    local glowCondLabel = glowContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    glowCondLabel:SetPoint("TOPLEFT", glowTypeLabel, "BOTTOMLEFT", 0, -20)
    glowCondLabel:SetText("|cffffcc00Condition:|r")
    f.glowCondDrop = CreateFrame("Frame", "MSWA_GlowCondDropDown", glowContent, "UIDropDownMenuTemplate")
    f.glowCondDrop:SetPoint("LEFT", glowCondLabel, "RIGHT", -10, -3)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(f.glowCondDrop, 140) end

    UIDropDownMenu_Initialize(f.glowCondDrop, function(self, level)
        level = level or 1
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = MSWA_GetAuraSettings and MSWA_GetAuraSettings(key) or nil
        local gs = s2 and s2.glow or {}
        local curCond = gs.condition or "ALWAYS"
        local isAutoBuff = s2 and (s2.auraMode == "AUTOBUFF" or s2.auraMode == "BUFF_THEN_CD" or s2.auraMode == "REMINDER_BUFF" or s2.auraMode == "CHARGES")

        for _, condKey in ipairs(MSWA.GLOW_COND_ORDER or {}) do
            -- Timer conditions available for AUTOBUFF / BUFF_THEN_CD / REMINDER_BUFF (we compute remaining ourselves)
            if isAutoBuff or (condKey ~= "TIMER_BELOW" and condKey ~= "TIMER_ABOVE") then
                local info = UIDropDownMenu_CreateInfo()
                info.text = MSWA.GLOW_CONDITIONS[condKey] or condKey
                info.value = condKey
                info.checked = (curCond == condKey)
                info.func = function()
                    local k = MSWA.selectedSpellID; if not k then return end
                    local ss = MSWA_EnsureAuraSettings(k)
                    local g2 = MSWA_GetOrCreateGlowSettings(ss)
                    g2.condition = condKey
                    UIDropDownMenu_SetText(f.glowCondDrop, MSWA.GLOW_CONDITIONS[condKey])
                    CloseDropDownMenus()
                    MSWA_RequestUpdateSpells()
                    if f.glowPanel2 and f.glowPanel2.Sync then f.glowPanel2:Sync() end
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
    end)

    -- Condition Value
    f.glowCondValueLabel = glowContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.glowCondValueLabel:SetPoint("LEFT", f.glowCondDrop, "RIGHT", 4, 3)
    f.glowCondValueLabel:SetText("Seconds:")
    f.glowCondValueEdit = CreateFrame("EditBox", nil, glowContent, "InputBoxTemplate")
    f.glowCondValueEdit:SetSize(50, 20); f.glowCondValueEdit:SetPoint("LEFT", f.glowCondValueLabel, "RIGHT", 6, 0)
    f.glowCondValueEdit:SetAutoFocus(false)

    local function ApplyGlowCondValue()
        local key = MSWA.selectedSpellID; if not key then return end
        local ss = MSWA_EnsureAuraSettings(key)
        local g2 = MSWA_GetOrCreateGlowSettings(ss)
        local v = tonumber(f.glowCondValueEdit:GetText())
        if v and v >= 0 then g2.conditionValue = v end
        MSWA_RequestUpdateSpells()
    end
    f.glowCondValueEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyGlowCondValue() end)
    f.glowCondValueEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.glowCondValueEdit:SetScript("OnEditFocusLost", function() ApplyGlowCondValue() end)

    -- Separator
    local glowSep = glowContent:CreateTexture(nil, "ARTWORK")
    glowSep:SetPoint("TOPLEFT", glowCondLabel, "BOTTOMLEFT", 0, -24)
    glowSep:SetSize(400, 1); glowSep:SetColorTexture(1, 1, 1, 0.15)

    -- Per-type settings header
    local glowDetailTitle = glowContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    glowDetailTitle:SetPoint("TOPLEFT", glowSep, "BOTTOMLEFT", 0, -10)
    glowDetailTitle:SetText("|cffffcc00Fine-Tuning:|r")

    -- Lines / Particles
    f.glowLinesLabel = glowContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.glowLinesLabel:SetPoint("TOPLEFT", glowDetailTitle, "BOTTOMLEFT", 0, -10)
    f.glowLinesLabel:SetText("Lines / Particles:")
    f.glowLinesEdit = CreateFrame("EditBox", nil, glowContent, "InputBoxTemplate")
    f.glowLinesEdit:SetSize(40, 20); f.glowLinesEdit:SetPoint("LEFT", f.glowLinesLabel, "RIGHT", 6, 0)
    f.glowLinesEdit:SetAutoFocus(false); f.glowLinesEdit:SetNumeric(true)

    -- Frequency
    f.glowFreqLabel = glowContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.glowFreqLabel:SetPoint("LEFT", f.glowLinesEdit, "RIGHT", 16, 0)
    f.glowFreqLabel:SetText("Speed:")
    f.glowFreqEdit = CreateFrame("EditBox", nil, glowContent, "InputBoxTemplate")
    f.glowFreqEdit:SetSize(50, 20); f.glowFreqEdit:SetPoint("LEFT", f.glowFreqLabel, "RIGHT", 6, 0)
    f.glowFreqEdit:SetAutoFocus(false)

    -- Thickness / Scale
    f.glowThickLabel = glowContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.glowThickLabel:SetPoint("TOPLEFT", f.glowLinesLabel, "BOTTOMLEFT", 0, -10)
    f.glowThickLabel:SetText("Thickness / Scale:")
    f.glowThickEdit = CreateFrame("EditBox", nil, glowContent, "InputBoxTemplate")
    f.glowThickEdit:SetSize(50, 20); f.glowThickEdit:SetPoint("LEFT", f.glowThickLabel, "RIGHT", 6, 0)
    f.glowThickEdit:SetAutoFocus(false)

    -- Duration (for Proc Glow)
    f.glowDurLabel = glowContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.glowDurLabel:SetPoint("LEFT", f.glowThickEdit, "RIGHT", 16, 0)
    f.glowDurLabel:SetText("Duration:")
    f.glowDurEdit = CreateFrame("EditBox", nil, glowContent, "InputBoxTemplate")
    f.glowDurEdit:SetSize(50, 20); f.glowDurEdit:SetPoint("LEFT", f.glowDurLabel, "RIGHT", 6, 0)
    f.glowDurEdit:SetAutoFocus(false)

    -- Apply hooks for fine-tuning fields
    local function ApplyGlowDetails()
        local key = MSWA.selectedSpellID; if not key then return end
        local ss = MSWA_EnsureAuraSettings(key)
        local g2 = MSWA_GetOrCreateGlowSettings(ss)
        local lines = tonumber(f.glowLinesEdit:GetText())
        local freq  = tonumber(f.glowFreqEdit:GetText())
        local thick = tonumber(f.glowThickEdit:GetText())
        local dur   = tonumber(f.glowDurEdit:GetText())
        if lines and lines >= 1 and lines <= 32 then g2.lines = lines end
        if freq then g2.frequency = freq end
        if thick and thick > 0 then
            g2.thickness = thick
            g2.scale = thick
        end
        if dur and dur > 0 then g2.duration = dur end
        -- Force glow refresh by stopping all and re-evaluating
        if MSWA_StopAllGlows then MSWA_StopAllGlows() end
        MSWA_RequestUpdateSpells()
    end
    local function HookGlowBox(box)
        box:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyGlowDetails() end)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        box:SetScript("OnEditFocusLost", function() ApplyGlowDetails() end)
    end
    HookGlowBox(f.glowLinesEdit); HookGlowBox(f.glowFreqEdit); HookGlowBox(f.glowThickEdit); HookGlowBox(f.glowDurEdit)

    -- Enable checkbox handler
    f.glowEnableCheck:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local ss = MSWA_EnsureAuraSettings(key)
        local g2 = MSWA_GetOrCreateGlowSettings(ss)
        g2.enabled = self:GetChecked() and true or false
        if not g2.enabled and MSWA_StopAllGlows then MSWA_StopAllGlows() end
        MSWA_RequestUpdateSpells()
        if f.glowPanel2 and f.glowPanel2.Sync then f.glowPanel2:Sync() end
    end)

    -- Hint text
    local glowHint = glowContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    glowHint:SetPoint("TOPLEFT", f.glowThickLabel, "BOTTOMLEFT", 0, -16)
    glowHint:SetWidth(420); glowHint:SetJustifyH("LEFT"); glowHint:SetWordWrap(true)
    glowHint:SetText("|cff888888Pixel Glow: lines rotate around icon. AutoCast: sparkle particles. Button: Blizzard proc glow. Proc: animated overlay.|r")

    -- Set scroll child height for Glow panel
    glowContent:SetHeight(360)

    -- Sync function
    function f.glowPanel2:Sync()
        local key = MSWA.selectedSpellID
        if not key then return end
        -- Stop active glows so changed settings (color, type, etc.) get re-applied
        MSWA_StopAllGlows()
        local s2 = MSWA_GetAuraSettings and MSWA_GetAuraSettings(key) or nil
        local gs = (s2 and s2.glow) or {}
        local defaults = MSWA.GLOW_DEFAULTS or {}
        local enabled = gs.enabled and true or false
        local glowType = gs.glowType or "PIXEL"
        local cond = gs.condition or "ALWAYS"

        f.glowEnableCheck:SetChecked(enabled)

        -- Type dropdown text
        UIDropDownMenu_SetText(f.glowTypeDrop, (MSWA.GLOW_TYPES or {})[glowType] or "Pixel Glow")

        -- Condition dropdown text
        local isAutoBuff2 = s2 and (s2.auraMode == "AUTOBUFF" or s2.auraMode == "BUFF_THEN_CD" or s2.auraMode == "REMINDER_BUFF" or s2.auraMode == "CHARGES")
        -- Timer conditions work for AUTOBUFF / BUFF_THEN_CD / REMINDER_BUFF; reset for spell/item CDs
        if not isAutoBuff2 and (cond == "TIMER_BELOW" or cond == "TIMER_ABOVE") then
            cond = "ALWAYS"
            if gs then gs.condition = "ALWAYS" end
        end
        UIDropDownMenu_SetText(f.glowCondDrop, (MSWA.GLOW_CONDITIONS or {})[cond] or "Always")

        -- Condition value visibility (for AUTOBUFF / BUFF_THEN_CD / REMINDER_BUFF timer conditions)
        local showValue = isAutoBuff2 and (cond == "TIMER_BELOW" or cond == "TIMER_ABOVE")
        f.glowCondValueLabel:SetShown(showValue)
        f.glowCondValueEdit:SetShown(showValue)
        if showValue then
            f.glowCondValueEdit:SetText(tostring(gs.conditionValue or defaults.conditionValue or 5))
        end

        -- Color swatch
        local gc = gs.color or defaults.color or { r = 0.95, g = 0.95, b = 0.32, a = 1 }
        f.glowColorSwatch:SetColorTexture(tonumber(gc.r) or 0.95, tonumber(gc.g) or 0.95, tonumber(gc.b) or 0.32, 1)

        -- Per-type labels and values
        if glowType == "PIXEL" then
            f.glowLinesLabel:SetText("Lines:"); f.glowLinesLabel:Show(); f.glowLinesEdit:Show()
            f.glowThickLabel:SetText("Thickness:"); f.glowThickLabel:Show(); f.glowThickEdit:Show()
            f.glowDurLabel:Hide(); f.glowDurEdit:Hide()
            f.glowLinesEdit:SetText(tostring(gs.lines or defaults.lines or 8))
            f.glowFreqEdit:SetText(tostring(gs.frequency or defaults.frequency or 0.25))
            f.glowThickEdit:SetText(tostring(gs.thickness or defaults.thickness or 2))
        elseif glowType == "AUTOCAST" then
            f.glowLinesLabel:SetText("Particles:"); f.glowLinesLabel:Show(); f.glowLinesEdit:Show()
            f.glowThickLabel:SetText("Scale:"); f.glowThickLabel:Show(); f.glowThickEdit:Show()
            f.glowDurLabel:Hide(); f.glowDurEdit:Hide()
            f.glowLinesEdit:SetText(tostring(gs.lines or 4))
            f.glowFreqEdit:SetText(tostring(gs.frequency or 0.125))
            f.glowThickEdit:SetText(tostring(gs.scale or defaults.scale or 1))
        elseif glowType == "BUTTON" then
            f.glowLinesLabel:Hide(); f.glowLinesEdit:Hide()
            f.glowThickLabel:Hide(); f.glowThickEdit:Hide()
            f.glowDurLabel:Hide(); f.glowDurEdit:Hide()
            f.glowFreqEdit:SetText(tostring(gs.frequency or 0.125))
        elseif glowType == "PROC" then
            f.glowLinesLabel:Hide(); f.glowLinesEdit:Hide()
            f.glowThickLabel:Hide(); f.glowThickEdit:Hide()
            f.glowDurLabel:Show(); f.glowDurEdit:Show()
            f.glowFreqEdit:SetText(tostring(gs.frequency or 0.25))
            f.glowDurEdit:SetText(tostring(gs.duration or defaults.duration or 1))
        end

        -- Disable controls if glow is not available
        if not glowAvailable then
            f.glowEnableCheck:Disable()
            if UIDropDownMenu_DisableDropDown then
                UIDropDownMenu_DisableDropDown(f.glowTypeDrop)
                UIDropDownMenu_DisableDropDown(f.glowCondDrop)
            end
            f.glowCondValueEdit:Disable(); f.glowLinesEdit:Disable()
            f.glowFreqEdit:Disable(); f.glowThickEdit:Disable(); f.glowDurEdit:Disable()
            f.glowColorBtn:Disable()
        else
            f.glowEnableCheck:Enable()
            if enabled then
                if UIDropDownMenu_EnableDropDown then
                    UIDropDownMenu_EnableDropDown(f.glowTypeDrop)
                    UIDropDownMenu_EnableDropDown(f.glowCondDrop)
                end
                f.glowCondValueEdit:Enable(); f.glowLinesEdit:Enable()
                f.glowFreqEdit:Enable(); f.glowThickEdit:Enable(); f.glowDurEdit:Enable()
                f.glowColorBtn:Enable()
            else
                if UIDropDownMenu_DisableDropDown then
                    UIDropDownMenu_DisableDropDown(f.glowTypeDrop)
                    UIDropDownMenu_DisableDropDown(f.glowCondDrop)
                end
                f.glowCondValueEdit:Disable(); f.glowLinesEdit:Disable()
                f.glowFreqEdit:Disable(); f.glowThickEdit:Disable(); f.glowDurEdit:Disable()
                f.glowColorBtn:Disable()
            end
        end
    end

    -- General tab
    f.generalPanel = CreateFrame("Frame", nil, rightPanel)
    f.generalPanel:SetPoint("TOPLEFT", 12, -60); f.generalPanel:SetPoint("BOTTOMRIGHT", -12, 12); f.generalPanel:Hide()

    -- Scroll frame inside generalPanel (prevents clipping on small windows)
    local gpScroll = CreateFrame("ScrollFrame", "MSWA_GeneralScrollFrame", f.generalPanel, "UIPanelScrollFrameTemplate")
    gpScroll:SetPoint("TOPLEFT", 0, 0)
    gpScroll:SetPoint("BOTTOMRIGHT", -26, 0)
    f._generalScroll = gpScroll

    local gp = CreateFrame("Frame")
    gp:SetWidth(400)
    gpScroll:SetScrollChild(gp)
    f._generalContent = gp

    gpScroll:SetScript("OnSizeChanged", function(self, w)
        if w and w > 30 then gp:SetWidth(w) end
    end)

    f.detailTitle = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.detailTitle:SetPoint("TOPLEFT", 10, -10); f.detailTitle:SetText("Selected aura:")
    f.detailName = gp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); f.detailName:SetPoint("TOPLEFT", f.detailTitle, "BOTTOMLEFT", 0, -4); f.detailName:SetText("")

    f.addLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormal"); f.addLabel:SetPoint("TOPLEFT", f.detailName, "BOTTOMLEFT", 0, -14); f.addLabel:SetText("Add ID:")
    f.addEdit = CreateFrame("EditBox", nil, gp, "InputBoxTemplate"); f.addEdit:SetSize(80, 20); f.addEdit:SetPoint("LEFT", f.addLabel, "RIGHT", 6, 0); f.addEdit:SetAutoFocus(false); f.addEdit:SetNumeric(true)
    f.idTypeLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.idTypeLabel:SetPoint("LEFT", f.addEdit, "RIGHT", 8, 0); f.idTypeLabel:SetText("Type:")
    f.idTypeDrop = CreateFrame("Frame", "MSWA_IDTypeDropDown", gp, "UIDropDownMenuTemplate"); f.idTypeDrop:SetPoint("LEFT", f.idTypeLabel, "RIGHT", -10, -3); UIDropDownMenu_SetWidth(f.idTypeDrop, 100)
    f.addButton = CreateFrame("Button", nil, gp, "UIPanelButtonTemplate"); f.addButton:SetSize(60, 20); f.addButton:SetPoint("LEFT", f.idTypeDrop, "RIGHT", 0, 3); f.addButton:SetText("Add")
    f.hint = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.hint:SetPoint("TOPLEFT", f.addLabel, "BOTTOMLEFT", 0, -10); f.hint:SetWidth(420); f.hint:SetJustifyH("LEFT"); f.hint:SetWordWrap(true)
    f.hint:SetText("Enter an ID or drag a spell / item from Spellbook or Bags onto the drop zone below. Type: Item for trinkets, Auto Buff for spell buffs, Item Buff for trinket/item buffs.")

    -- Drop zone for drag & drop from Spellbook / Inventory
    f.dropZone = CreateFrame("Button", nil, gp)
    f.dropZone:SetSize(320, 40)
    f.dropZone:SetPoint("TOPLEFT", f.hint, "BOTTOMLEFT", 0, -6)

    f.dropZone.bg = f.dropZone:CreateTexture(nil, "BACKGROUND")
    f.dropZone.bg:SetAllPoints()
    f.dropZone.bg:SetColorTexture(0.12, 0.12, 0.12, 0.7)

    f.dropZone.border = CreateFrame("Frame", nil, f.dropZone, "BackdropTemplate")
    f.dropZone.border:SetAllPoints()
    f.dropZone.border:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    f.dropZone.border:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)

    f.dropZone.icon = f.dropZone:CreateTexture(nil, "ARTWORK")
    f.dropZone.icon:SetSize(22, 22)
    f.dropZone.icon:SetPoint("LEFT", 10, 0)
    f.dropZone.icon:SetTexture("Interface\\CURSOR\\openhandglow")
    f.dropZone.icon:SetDesaturated(true)
    f.dropZone.icon:SetVertexColor(0.7, 0.7, 0.7)

    f.dropZone.label = f.dropZone:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.dropZone.label:SetPoint("LEFT", f.dropZone.icon, "RIGHT", 8, 0)
    f.dropZone.label:SetText("|cff888888Drop Spell or Item here|r")

    f.autoBuffCheck = CreateFrame("CheckButton", nil, gp, "ChatConfigCheckButtonTemplate"); f.autoBuffCheck:SetPoint("TOPLEFT", f.dropZone, "BOTTOMLEFT", -4, -8)
    f.autoBuffLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.autoBuffLabel:SetPoint("LEFT", f.autoBuffCheck, "RIGHT", 2, 0)
    f.autoBuffLabel:SetText("|cffffcc00Auto Buff mode|r  (show icon only while buff is active)")

    -- Buff → Cooldown checkbox
    f.buffThenCDCheck = CreateFrame("CheckButton", nil, gp, "ChatConfigCheckButtonTemplate")
    f.buffThenCDCheck:SetPoint("TOPLEFT", f.autoBuffCheck, "BOTTOMLEFT", 0, -2)
    f.buffThenCDLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.buffThenCDLabel:SetPoint("LEFT", f.buffThenCDCheck, "RIGHT", 2, 0)
    f.buffThenCDLabel:SetText("|cff44ffaaBuff -> Cooldown|r  (buff timer first, then cooldown)")

    f.buffDurLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.buffDurLabel:SetPoint("TOPLEFT", f.buffThenCDCheck, "BOTTOMLEFT", 22, -6); f.buffDurLabel:SetText("Buff duration (sec):")
    f.buffDurEdit = CreateFrame("EditBox", nil, gp, "InputBoxTemplate"); f.buffDurEdit:SetSize(60, 20); f.buffDurEdit:SetPoint("LEFT", f.buffDurLabel, "RIGHT", 6, 0); f.buffDurEdit:SetAutoFocus(false)

    f.buffDelayLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.buffDelayLabel:SetPoint("TOPLEFT", f.buffDurLabel, "BOTTOMLEFT", 0, -8); f.buffDelayLabel:SetText("Timer restart after (sec):")
    f.buffDelayEdit = CreateFrame("EditBox", nil, gp, "InputBoxTemplate"); f.buffDelayEdit:SetSize(60, 20); f.buffDelayEdit:SetPoint("LEFT", f.buffDelayLabel, "RIGHT", 6, 0); f.buffDelayEdit:SetAutoFocus(false)

    f.autoBuffCheck:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local db2 = MSWA_GetDB(); local s2 = select(1, MSWA_GetOrCreateSpellSettings(db2, key))
        if self:GetChecked() then
            s2.auraMode = "AUTOBUFF"; if not s2.autoBuffDuration then s2.autoBuffDuration = 10 end
            if f.buffThenCDCheck then f.buffThenCDCheck:SetChecked(false) end
            if f.reminderBuffCheck then f.reminderBuffCheck:SetChecked(false) end
            if f.chargesCheck then f.chargesCheck:SetChecked(false) end
        else
            s2.auraMode = nil; MSWA._autoBuff[key] = nil
        end
        MSWA_UpdateDetailPanel(); MSWA_RequestUpdateSpells()
    end)

    f.buffThenCDCheck:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local db2 = MSWA_GetDB(); local s2 = select(1, MSWA_GetOrCreateSpellSettings(db2, key))
        if self:GetChecked() then
            s2.auraMode = "BUFF_THEN_CD"; if not s2.autoBuffDuration then s2.autoBuffDuration = 10 end
            if f.autoBuffCheck then f.autoBuffCheck:SetChecked(false) end
            if f.reminderBuffCheck then f.reminderBuffCheck:SetChecked(false) end
            if f.chargesCheck then f.chargesCheck:SetChecked(false) end
        else
            s2.auraMode = nil; MSWA._autoBuff[key] = nil
        end
        MSWA_UpdateDetailPanel(); MSWA_RequestUpdateSpells()
    end)

    local function ApplyBuffDuration()
        local key = MSWA.selectedSpellID; if not key then return end
        local db2 = MSWA_GetDB(); local s2 = select(1, MSWA_GetOrCreateSpellSettings(db2, key))
        local v = tonumber(f.buffDurEdit:GetText()); if v and v >= 0.1 then s2.autoBuffDuration = math.floor(v * 1000 + 0.5) / 1000 end
        MSWA._autoBuff[key] = nil; MSWA_RequestUpdateSpells()
    end
    f.buffDurEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyBuffDuration() end)
    f.buffDurEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local function ApplyBuffDelay()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        local v = tonumber(f.buffDelayEdit:GetText())
        if v and v >= 0 then v = math.floor(v * 1000 + 0.5) / 1000; s2.autoBuffDelay = (v > 0) and v or nil else s2.autoBuffDelay = nil end
        MSWA._autoBuff[key] = nil; MSWA_RequestUpdateSpells()
    end
    f.buffDelayEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyBuffDelay() end)
    f.buffDelayEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.buffDelayEdit:SetScript("OnEditFocusLost", function() ApplyBuffDelay() end)

    -- Haste scaling toggle
    f.hasteScaleCheck = CreateFrame("CheckButton", nil, gp, "ChatConfigCheckButtonTemplate")
    f.hasteScaleCheck:SetPoint("TOPLEFT", f.buffDelayLabel, "BOTTOMLEFT", -22, -6)
    f.hasteScaleLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.hasteScaleLabel:SetPoint("LEFT", f.hasteScaleCheck, "RIGHT", 2, 0)
    f.hasteScaleLabel:SetText("Haste scaling  (duration adjusts to spell haste)")
    f.hasteScaleCheck:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        s2.hasteScaling = self:GetChecked() and true or nil
        MSWA._autoBuff[key] = nil; MSWA_RequestUpdateSpells()
    end)

    -- Reminder Buff checkbox (third radio-style option)
    f.reminderBuffCheck = CreateFrame("CheckButton", nil, gp, "ChatConfigCheckButtonTemplate")
    f.reminderBuffCheck:SetPoint("TOPLEFT", f.hasteScaleCheck, "BOTTOMLEFT", 0, -6)
    f.reminderBuffLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.reminderBuffLabel:SetPoint("LEFT", f.reminderBuffCheck, "RIGHT", 2, 0)
    f.reminderBuffLabel:SetText("|cffff6644Reminder Buff|r  (alert when buff is missing)")

    f.reminderBuffCheck:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local db2 = MSWA_GetDB(); local s2 = select(1, MSWA_GetOrCreateSpellSettings(db2, key))
        if self:GetChecked() then
            s2.auraMode = "REMINDER_BUFF"
            if not s2.autoBuffDuration then s2.autoBuffDuration = 3600 end
            if not s2.reminderText then s2.reminderText = "MISSING!" end
            if not s2.reminderTextColor then s2.reminderTextColor = { r = 1, g = 0.2, b = 0.2 } end
            if f.autoBuffCheck then f.autoBuffCheck:SetChecked(false) end
            if f.buffThenCDCheck then f.buffThenCDCheck:SetChecked(false) end
            if f.chargesCheck then f.chargesCheck:SetChecked(false) end
        else
            s2.auraMode = nil; MSWA._autoBuff[key] = nil
        end
        MSWA_UpdateDetailPanel(); MSWA_RequestUpdateSpells()
    end)

    -- Reminder Buff sub-settings (shown only when REMINDER_BUFF mode active)
    f.reminderPersistDeathCheck = CreateFrame("CheckButton", nil, gp, "ChatConfigCheckButtonTemplate")
    f.reminderPersistDeathCheck:SetPoint("TOPLEFT", f.reminderBuffCheck, "BOTTOMLEFT", 22, -2)
    f.reminderPersistDeathLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.reminderPersistDeathLabel:SetPoint("LEFT", f.reminderPersistDeathCheck, "RIGHT", 2, 0)
    f.reminderPersistDeathLabel:SetText("Persists through death  (poisons, flasks)")
    f.reminderPersistDeathCheck:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        s2.reminderPersistDeath = self:GetChecked() and true or nil
    end)

    f.reminderShowTimerCheck = CreateFrame("CheckButton", nil, gp, "ChatConfigCheckButtonTemplate")
    f.reminderShowTimerCheck:SetPoint("TOPLEFT", f.reminderPersistDeathCheck, "BOTTOMLEFT", 0, -2)
    f.reminderShowTimerLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.reminderShowTimerLabel:SetPoint("LEFT", f.reminderShowTimerCheck, "RIGHT", 2, 0)
    f.reminderShowTimerLabel:SetText("Show timer while buff active")
    f.reminderShowTimerCheck:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        s2.reminderShowTimer = self:GetChecked() and true or nil
        MSWA_RequestUpdateSpells()
    end)

    f.reminderTextLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.reminderTextLabel:SetPoint("TOPLEFT", f.reminderShowTimerCheck, "BOTTOMLEFT", 0, -8)
    f.reminderTextLabel:SetText("Reminder text:")
    f.reminderTextEdit = CreateFrame("EditBox", nil, gp, "InputBoxTemplate")
    f.reminderTextEdit:SetSize(120, 20); f.reminderTextEdit:SetPoint("LEFT", f.reminderTextLabel, "RIGHT", 6, 0); f.reminderTextEdit:SetAutoFocus(false)
    local function ApplyReminderText()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        local t = f.reminderTextEdit:GetText()
        s2.reminderText = (t and t ~= "") and t or nil
        MSWA_InvalidateIconCache()
    end
    f.reminderTextEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyReminderText() end)
    f.reminderTextEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.reminderTextEdit:SetScript("OnEditFocusLost", ApplyReminderText)

    f.reminderFontSizeLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.reminderFontSizeLabel:SetPoint("TOPLEFT", f.reminderTextLabel, "BOTTOMLEFT", 0, -8)
    f.reminderFontSizeLabel:SetText("Font size:")
    f.reminderFontSizeEdit = CreateFrame("EditBox", nil, gp, "InputBoxTemplate")
    f.reminderFontSizeEdit:SetSize(40, 20); f.reminderFontSizeEdit:SetPoint("LEFT", f.reminderFontSizeLabel, "RIGHT", 6, 0); f.reminderFontSizeEdit:SetAutoFocus(false); f.reminderFontSizeEdit:SetNumeric(true)
    local function ApplyReminderFontSize()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        local v = tonumber(f.reminderFontSizeEdit:GetText())
        s2.reminderFontSize = (v and v >= 6 and v <= 72) and v or nil
        MSWA_InvalidateIconCache()
    end
    f.reminderFontSizeEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyReminderFontSize() end)
    f.reminderFontSizeEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.reminderFontSizeEdit:SetScript("OnEditFocusLost", ApplyReminderFontSize)

    -- Color presets
    f.reminderColorLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.reminderColorLabel:SetPoint("TOPLEFT", f.reminderFontSizeLabel, "BOTTOMLEFT", 0, -8)
    f.reminderColorLabel:SetText("Text color:")

    local colorPresets = { { "Red", 1, 0.2, 0.2 }, { "Yellow", 1, 1, 0.2 }, { "Green", 0.2, 1, 0.2 }, { "White", 1, 1, 1 } }
    local prevColorBtn
    for ci, cp in ipairs(colorPresets) do
        local btn = CreateFrame("Button", nil, gp, "UIPanelButtonTemplate")
        btn:SetSize(52, 18); btn:SetText(cp[1])
        if ci == 1 then
            btn:SetPoint("LEFT", f.reminderColorLabel, "RIGHT", 6, 0)
        else
            btn:SetPoint("LEFT", prevColorBtn, "RIGHT", 2, 0)
        end
        btn:SetScript("OnClick", function()
            local key = MSWA.selectedSpellID; if not key then return end
            local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
            s2.reminderTextColor = { r = cp[2], g = cp[3], b = cp[4] }
            MSWA_InvalidateIconCache()
        end)
        prevColorBtn = btn
        f["reminderColor" .. ci] = btn
    end

    -- Charges checkbox (fourth radio-style option)
    f.chargesCheck = CreateFrame("CheckButton", nil, gp, "ChatConfigCheckButtonTemplate")
    f.chargesCheck:SetPoint("TOPLEFT", f.reminderColorLabel, "BOTTOMLEFT", -22, -10)
    f.chargesLabel = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.chargesLabel:SetPoint("LEFT", f.chargesCheck, "RIGHT", 2, 0)
    f.chargesLabel:SetText("|cff44ddffCharges|r  (user-defined charges, countdown per charge, gray at 0)")

    f.chargesCheck:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local db2 = MSWA_GetDB(); local s2 = select(1, MSWA_GetOrCreateSpellSettings(db2, key))
        if self:GetChecked() then
            s2.auraMode = "CHARGES"
            if not s2.chargeMax then s2.chargeMax = 3 end
            if not s2.chargeDuration then s2.chargeDuration = 0 end
            -- Init runtime state
            MSWA._charges = MSWA._charges or {}
            MSWA._charges[key] = { remaining = s2.chargeMax, rechargeStart = 0 }
            if f.autoBuffCheck then f.autoBuffCheck:SetChecked(false) end
            if f.buffThenCDCheck then f.buffThenCDCheck:SetChecked(false) end
            if f.reminderBuffCheck then f.reminderBuffCheck:SetChecked(false) end
        else
            s2.auraMode = nil
            if MSWA._charges then MSWA._charges[key] = nil end
        end
        MSWA_UpdateDetailPanel(); MSWA_RequestUpdateSpells()
    end)

    -- Anchor
    local labelA = gp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); labelA:SetPoint("TOPLEFT", f.chargesCheck, "BOTTOMLEFT", 0, -10); labelA:SetText("Anchor to frame:")
    f._anchorLabel = labelA
    f.detailA = CreateFrame("EditBox", nil, gp, "InputBoxTemplate"); f.detailA:SetSize(260, 20); f.detailA:SetPoint("LEFT", labelA, "RIGHT", 6, 0); f.detailA:SetAutoFocus(false)
    f.detailACD = CreateFrame("Button", nil, gp, "UIPanelButtonTemplate"); f.detailACD:SetSize(110, 22); f.detailACD:SetPoint("TOPLEFT", labelA, "BOTTOMLEFT", 0, -10); f.detailACD:SetText("CD Manager")
    f.detailAMSUF = CreateFrame("Button", nil, gp, "UIPanelButtonTemplate"); f.detailAMSUF:SetSize(110, 22); f.detailAMSUF:SetPoint("LEFT", f.detailACD, "RIGHT", 6, 0); f.detailAMSUF:SetText("MSUF Player")
    f.detailApply = CreateFrame("Button", nil, gp, "UIPanelButtonTemplate"); f.detailApply:SetSize(80, 22); f.detailApply:SetPoint("TOPLEFT", f.detailACD, "BOTTOMLEFT", 0, -8); f.detailApply:SetText("Reset Pos")
    f.detailDefault = CreateFrame("Button", nil, gp, "UIPanelButtonTemplate"); f.detailDefault:SetSize(80, 22); f.detailDefault:SetPoint("LEFT", f.detailApply, "RIGHT", 6, 0); f.detailDefault:SetText("Default")

    -- Set scroll child height for General panel
    gp:SetHeight(650)

    -- Display tab
    f.displayPanel = CreateFrame("Frame", nil, rightPanel); f.displayPanel:SetPoint("TOPLEFT", 12, -60); f.displayPanel:SetPoint("BOTTOMRIGHT", -12, 12); f.displayPanel:Hide()

    -- Scroll frame inside displayPanel (prevents clipping on small windows)
    local dpScroll = CreateFrame("ScrollFrame", "MSWA_DisplayScrollFrame", f.displayPanel, "UIPanelScrollFrameTemplate")
    dpScroll:SetPoint("TOPLEFT", 0, 0)
    dpScroll:SetPoint("BOTTOMRIGHT", -26, 0)
    f._displayScroll = dpScroll

    local dp = CreateFrame("Frame")
    dp:SetWidth(400)
    dpScroll:SetScrollChild(dp)
    f._displayContent = dp

    dpScroll:SetScript("OnSizeChanged", function(self, w)
        if w and w > 30 then dp:SetWidth(w) end
    end)

    local labelX = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); labelX:SetPoint("TOPLEFT", 10, -10); labelX:SetText("Offset X:")
    f.detailX = CreateFrame("EditBox", nil, dp, "InputBoxTemplate"); f.detailX:SetSize(70, 20); f.detailX:SetPoint("LEFT", labelX, "RIGHT", 6, 0); f.detailX:SetAutoFocus(false)
    f.detailXMinus = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate"); f.detailXMinus:SetSize(20, 20); f.detailXMinus:SetPoint("LEFT", f.detailX, "RIGHT", 2, 0); f.detailXMinus:SetText("-")
    f.detailXPlus = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate"); f.detailXPlus:SetSize(20, 20); f.detailXPlus:SetPoint("LEFT", f.detailXMinus, "RIGHT", 2, 0); f.detailXPlus:SetText("+")
    local labelY = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); labelY:SetPoint("TOPLEFT", labelX, "BOTTOMLEFT", 0, -10); labelY:SetText("Offset Y:")
    f.detailY = CreateFrame("EditBox", nil, dp, "InputBoxTemplate"); f.detailY:SetSize(70, 20); f.detailY:SetPoint("LEFT", labelY, "RIGHT", 6, 0); f.detailY:SetAutoFocus(false)
    f.detailYMinus = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate"); f.detailYMinus:SetSize(20, 20); f.detailYMinus:SetPoint("LEFT", f.detailY, "RIGHT", 2, 0); f.detailYMinus:SetText("-")
    f.detailYPlus = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate"); f.detailYPlus:SetSize(20, 20); f.detailYPlus:SetPoint("LEFT", f.detailYMinus, "RIGHT", 2, 0); f.detailYPlus:SetText("+")
    local labelW = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); labelW:SetPoint("TOPLEFT", labelY, "BOTTOMLEFT", 0, -14); labelW:SetText("Width:")
    f.detailW = CreateFrame("EditBox", nil, dp, "InputBoxTemplate"); f.detailW:SetSize(70, 20); f.detailW:SetPoint("LEFT", labelW, "RIGHT", 6, 0); f.detailW:SetAutoFocus(false)
    local labelH = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); labelH:SetPoint("TOPLEFT", labelW, "BOTTOMLEFT", 0, -10); labelH:SetText("Height:")
    f.detailH = CreateFrame("EditBox", nil, dp, "InputBoxTemplate"); f.detailH:SetSize(70, 20); f.detailH:SetPoint("LEFT", labelH, "RIGHT", 6, 0); f.detailH:SetAutoFocus(false)

    -- Custom Icon override
    f.customIconLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.customIconLabel:SetPoint("TOPLEFT", labelH, "BOTTOMLEFT", 0, -14)
    f.customIconLabel:SetText("Custom Icon:")

    f.customIconEdit = CreateFrame("EditBox", nil, dp, "InputBoxTemplate")
    f.customIconEdit:SetSize(70, 20)
    f.customIconEdit:SetPoint("LEFT", f.customIconLabel, "RIGHT", 6, 0)
    f.customIconEdit:SetAutoFocus(false)
    f.customIconEdit:SetNumeric(true)

    f.customIconPreview = dp:CreateTexture(nil, "ARTWORK")
    f.customIconPreview:SetSize(20, 20)
    f.customIconPreview:SetPoint("LEFT", f.customIconEdit, "RIGHT", 6, 0)
    f.customIconPreview:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.customIconPreview:Hide()

    f.customIconClear = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate")
    f.customIconClear:SetSize(20, 20)
    f.customIconClear:SetPoint("LEFT", f.customIconPreview, "RIGHT", 4, 0)
    f.customIconClear:SetText("X")
    f.customIconClear:SetScript("OnClick", function()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        s2.customIconID = nil
        if f.customIconEdit then f.customIconEdit:SetText("") end
        if f.customIconPreview then f.customIconPreview:Hide() end
        MSWA_InvalidateIconCache(); MSWA_RefreshOptionsList()
    end)

    local function ApplyCustomIcon()
        local key = MSWA.selectedSpellID; if not key then return end
        local val = tonumber(f.customIconEdit:GetText())
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        if val and val > 0 then
            s2.customIconID = val
            f.customIconPreview:SetTexture(val)
            f.customIconPreview:Show()
        else
            s2.customIconID = nil
            f.customIconPreview:Hide()
        end
        MSWA_InvalidateIconCache(); MSWA_RefreshOptionsList()
    end
    f.customIconEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyCustomIcon() end)
    f.customIconEdit:SetScript("OnEditFocusLost", function() ApplyCustomIcon() end)

    f.fontLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.fontLabel:SetPoint("TOPLEFT", f.customIconLabel, "BOTTOMLEFT", 0, -18); f.fontLabel:SetText("Font:")
    f.fontDrop = CreateFrame("Frame", "MSWA_FontDropDown", dp, "UIDropDownMenuTemplate"); f.fontDrop:SetPoint("LEFT", f.fontLabel, "RIGHT", -10, -3)
    f.fontPreview = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.fontPreview:SetPoint("LEFT", f.fontDrop, "RIGHT", -10, 0); f.fontPreview:SetText("AaBbYyZz 123")

    f.textSizeLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.textSizeLabel:SetPoint("TOPLEFT", f.fontLabel, "BOTTOMLEFT", 0, -16); f.textSizeLabel:SetText("Text size:")
    f.textSizeEdit = CreateFrame("EditBox", nil, dp, "InputBoxTemplate"); f.textSizeEdit:SetSize(50, 20); f.textSizeEdit:SetPoint("LEFT", f.textSizeLabel, "RIGHT", 6, 0); f.textSizeEdit:SetAutoFocus(false); f.textSizeEdit:SetNumeric(true)
    f.textSizeMinus = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate"); f.textSizeMinus:SetSize(20, 20); f.textSizeMinus:SetPoint("LEFT", f.textSizeEdit, "RIGHT", 2, 0); f.textSizeMinus:SetText("-")
    f.textSizePlus = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate"); f.textSizePlus:SetSize(20, 20); f.textSizePlus:SetPoint("LEFT", f.textSizeMinus, "RIGHT", 2, 0); f.textSizePlus:SetText("+")

    f.textPosLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.textPosLabel:SetPoint("LEFT", f.textSizePlus, "RIGHT", 14, 0); f.textPosLabel:SetText("Pos:")
    f.textPosDrop = CreateFrame("Frame", "MSWA_TextPosDropDown", dp, "UIDropDownMenuTemplate"); f.textPosDrop:SetPoint("LEFT", f.textPosLabel, "RIGHT", -10, -3)

    f.textColorLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.textColorLabel:SetPoint("TOPLEFT", f.textSizeLabel, "BOTTOMLEFT", 0, -12); f.textColorLabel:SetText("Text color:")
    f.textColorBtn = CreateFrame("Button", nil, dp); f.textColorBtn:SetSize(18, 18); f.textColorBtn:SetPoint("LEFT", f.textColorLabel, "RIGHT", 8, 0); f.textColorBtn:EnableMouse(true)
    f.textColorSwatch = f.textColorBtn:CreateTexture(nil, "ARTWORK"); f.textColorSwatch:SetAllPoints(true); f.textColorSwatch:SetColorTexture(1, 1, 1, 1)
    f.textColorBorder = f.textColorBtn:CreateTexture(nil, "BORDER"); f.textColorBorder:SetPoint("TOPLEFT", -1, 1); f.textColorBorder:SetPoint("BOTTOMRIGHT", 1, -1); f.textColorBorder:SetColorTexture(0, 0, 0, 1)

    f.grayCooldownCheck = CreateFrame("CheckButton", nil, dp, "ChatConfigCheckButtonTemplate"); f.grayCooldownCheck:SetPoint("TOPLEFT", f.textColorLabel, "BOTTOMLEFT", -4, -14)
    f.grayCooldownLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.grayCooldownLabel:SetPoint("LEFT", f.grayCooldownCheck, "RIGHT", 2, 0); f.grayCooldownLabel:SetText("Grayscale on cooldown")
    f.grayCooldownCheck:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local s = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key)); s.grayOnCooldown = self:GetChecked() and true or nil
        MSWA_RequestUpdateSpells()
    end)

    -- Grayscale on zero item count
    f.grayZeroCountCheck = CreateFrame("CheckButton", nil, dp, "ChatConfigCheckButtonTemplate")
    f.grayZeroCountCheck:SetPoint("TOPLEFT", f.grayCooldownCheck, "BOTTOMLEFT", 0, -4)
    f.grayZeroCountLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.grayZeroCountLabel:SetPoint("LEFT", f.grayZeroCountCheck, "RIGHT", 2, 0)
    f.grayZeroCountLabel:SetText("Show grayed when item count is 0")
    f.grayZeroCountCheck:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        s2.showOnZeroCount = self:GetChecked() and true or nil
        MSWA_RequestUpdateSpells()
    end)

    -- Swipe darkens on loss
    f.swipeDarkenCheck = CreateFrame("CheckButton", nil, dp, "ChatConfigCheckButtonTemplate")
    f.swipeDarkenCheck:SetPoint("TOPLEFT", f.grayZeroCountCheck, "BOTTOMLEFT", 0, -4)
    f.swipeDarkenLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.swipeDarkenLabel:SetPoint("LEFT", f.swipeDarkenCheck, "RIGHT", 2, 0)
    f.swipeDarkenLabel:SetText("Swipe darkens on loss")
    f.swipeDarkenCheck:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        -- Nil == default (standard Blizzard swipe direction).
        -- True == "darkens on loss" (reverse swipe).
        s2.swipeDarken = self:GetChecked() and true or nil
        MSWA_RequestUpdateSpells()
    end)

    -- Show decimal (one decimal place for timers < 10s)
    f.showDecimalCheck = CreateFrame("CheckButton", nil, dp, "ChatConfigCheckButtonTemplate")
    f.showDecimalCheck:SetPoint("TOPLEFT", f.swipeDarkenCheck, "BOTTOMLEFT", 0, -4)
    f.showDecimalLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.showDecimalLabel:SetPoint("LEFT", f.showDecimalCheck, "RIGHT", 2, 0)
    f.showDecimalLabel:SetText("Show decimal (e.g. 3.7 instead of 4)")
    f.showDecimalCheck:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        s2.showDecimal = self:GetChecked() and true or nil
        MSWA_RequestUpdateSpells()
    end)

    -- ======= Alpha Sliders Section =======
    local alphaSep = dp:CreateTexture(nil, "ARTWORK")
    alphaSep:SetPoint("TOPLEFT", f.showDecimalCheck, "BOTTOMLEFT", 4, -10)
    alphaSep:SetSize(400, 1); alphaSep:SetColorTexture(1, 1, 1, 0.12)

    local alphaTitle = dp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    alphaTitle:SetPoint("TOPLEFT", alphaSep, "BOTTOMLEFT", 0, -6)
    alphaTitle:SetText("|cffffcc00Alpha / Opacity|r")

    -- Helper to create a clean labeled alpha slider (0% - 100%)
    local function CreateAlphaSlider(parent, label, anchorFrame, yOff, settingsKey)
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(22)
        row:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, yOff)
        row:SetPoint("RIGHT", parent, "RIGHT", -10, 0)

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", row, "LEFT", 0, 0)
        lbl:SetWidth(100)
        lbl:SetJustifyH("LEFT")
        lbl:SetText(label)

        local valText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        valText:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        valText:SetWidth(36)
        valText:SetJustifyH("RIGHT")

        local slider = CreateFrame("Slider", nil, row, "OptionsSliderTemplate")
        slider:SetPoint("LEFT", lbl, "RIGHT", 4, 0)
        slider:SetPoint("RIGHT", valText, "LEFT", -8, 0)
        slider:SetHeight(16)
        slider:SetMinMaxValues(0, 100)
        slider:SetValueStep(5)
        slider:SetObeyStepOnDrag(true)
        -- Hide built-in template labels to prevent clipping
        slider.Low:SetText(""); slider.Low:Hide()
        slider.High:SetText(""); slider.High:Hide()
        slider.Text:SetText(""); slider.Text:Hide()

        slider:SetScript("OnValueChanged", function(self, val)
            val = math.floor(val + 0.5)
            valText:SetText(val .. "%")
            local key = MSWA.selectedSpellID; if not key then return end
            local ss = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
            if val >= 100 then
                ss[settingsKey] = nil
            else
                ss[settingsKey] = val / 100
            end
            MSWA_RequestUpdateSpells()
        end)

        return slider, row, valText
    end

    f.cdAlphaSlider, f.cdAlphaRow, f.cdAlphaVal = CreateAlphaSlider(dp, "On Cooldown:", alphaTitle, -4, "cdAlpha")
    f.oocAlphaSlider, f.oocAlphaRow, f.oocAlphaVal = CreateAlphaSlider(dp, "Out of Combat:", f.cdAlphaRow, -2, "oocAlpha")
    f.combatAlphaSlider, f.combatAlphaRow, f.combatAlphaVal = CreateAlphaSlider(dp, "In Combat:", f.oocAlphaRow, -2, "combatAlpha")

    -- ======= Stack Text Section =======
    local stackSep = dp:CreateTexture(nil, "ARTWORK")
    stackSep:SetPoint("TOPLEFT", f.combatAlphaRow, "BOTTOMLEFT", 0, -10)
    stackSep:SetSize(400, 1); stackSep:SetColorTexture(1, 1, 1, 0.12)

    f.stackShowLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.stackShowLabel:SetPoint("TOPLEFT", stackSep, "BOTTOMLEFT", 0, -8)
    f.stackShowLabel:SetText("|cffffcc00Stacks|r")

    f.stackShowMode = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate")
    f.stackShowMode:SetSize(100, 20); f.stackShowMode:SetPoint("LEFT", f.stackShowLabel, "RIGHT", 10, 0)
    f.stackShowMode:SetText("Auto")

    local stackShowModes = { "auto", "show", "hide" }
    local stackShowLabels = { auto = "Auto", show = "Force Show", hide = "Force Hide" }
    f.stackShowMode:SetScript("OnClick", function()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        local cur = s2.stackShowMode or "auto"
        local idx = 1
        for i, m in ipairs(stackShowModes) do if m == cur then idx = i; break end end
        idx = idx % #stackShowModes + 1
        s2.stackShowMode = stackShowModes[idx]
        f.stackShowMode:SetText(stackShowLabels[s2.stackShowMode] or "Auto")
        MSWA_RequestUpdateSpells()
    end)

    -- Stack Font
    f.stackFontLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.stackFontLabel:SetPoint("TOPLEFT", f.stackShowLabel, "BOTTOMLEFT", 0, -12)
    f.stackFontLabel:SetText("Font:")
    f.stackFontDrop = CreateFrame("Frame", "MSWA_StackFontDropDown", dp, "UIDropDownMenuTemplate")
    f.stackFontDrop:SetPoint("LEFT", f.stackFontLabel, "RIGHT", -10, -3)

    -- Stack Size
    f.stackSizeLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.stackSizeLabel:SetPoint("TOPLEFT", f.stackFontLabel, "BOTTOMLEFT", 0, -16)
    f.stackSizeLabel:SetText("Size:")
    f.stackSizeEdit = CreateFrame("EditBox", nil, dp, "InputBoxTemplate")
    f.stackSizeEdit:SetSize(50, 20); f.stackSizeEdit:SetPoint("LEFT", f.stackSizeLabel, "RIGHT", 6, 0); f.stackSizeEdit:SetAutoFocus(false); f.stackSizeEdit:SetNumeric(true)
    f.stackSizeMinus = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate"); f.stackSizeMinus:SetSize(20, 20); f.stackSizeMinus:SetPoint("LEFT", f.stackSizeEdit, "RIGHT", 2, 0); f.stackSizeMinus:SetText("-")
    f.stackSizePlus = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate"); f.stackSizePlus:SetSize(20, 20); f.stackSizePlus:SetPoint("LEFT", f.stackSizeMinus, "RIGHT", 2, 0); f.stackSizePlus:SetText("+")

    -- Stack Pos
    f.stackPosLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.stackPosLabel:SetPoint("LEFT", f.stackSizePlus, "RIGHT", 14, 0)
    f.stackPosLabel:SetText("Pos:")
    f.stackPosDrop = CreateFrame("Frame", "MSWA_StackPosDropDown", dp, "UIDropDownMenuTemplate")
    f.stackPosDrop:SetPoint("LEFT", f.stackPosLabel, "RIGHT", -10, -3)

    -- Stack Color
    f.stackColorLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.stackColorLabel:SetPoint("TOPLEFT", f.stackSizeLabel, "BOTTOMLEFT", 0, -12)
    f.stackColorLabel:SetText("Color:")
    f.stackColorBtn = CreateFrame("Button", nil, dp); f.stackColorBtn:SetSize(18, 18); f.stackColorBtn:SetPoint("LEFT", f.stackColorLabel, "RIGHT", 8, 0); f.stackColorBtn:EnableMouse(true)
    f.stackColorSwatch = f.stackColorBtn:CreateTexture(nil, "ARTWORK"); f.stackColorSwatch:SetAllPoints(true); f.stackColorSwatch:SetColorTexture(1, 1, 1, 1)
    local stackColorBorder = f.stackColorBtn:CreateTexture(nil, "BORDER"); stackColorBorder:SetPoint("TOPLEFT", f.stackColorBtn, "TOPLEFT", -1, 1); stackColorBorder:SetPoint("BOTTOMRIGHT", f.stackColorBtn, "BOTTOMRIGHT", 1, -1); stackColorBorder:SetColorTexture(0, 0, 0, 1)

    -- Stack Offset X/Y
    f.stackOffXLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.stackOffXLabel:SetPoint("LEFT", f.stackColorBtn, "RIGHT", 16, 0)
    f.stackOffXLabel:SetText("Offset X:")
    f.stackOffXEdit = CreateFrame("EditBox", nil, dp, "InputBoxTemplate")
    f.stackOffXEdit:SetSize(40, 20); f.stackOffXEdit:SetPoint("LEFT", f.stackOffXLabel, "RIGHT", 4, 0); f.stackOffXEdit:SetAutoFocus(false)

    f.stackOffYLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.stackOffYLabel:SetPoint("LEFT", f.stackOffXEdit, "RIGHT", 10, 0)
    f.stackOffYLabel:SetText("Y:")
    f.stackOffYEdit = CreateFrame("EditBox", nil, dp, "InputBoxTemplate")
    f.stackOffYEdit:SetSize(40, 20); f.stackOffYEdit:SetPoint("LEFT", f.stackOffYLabel, "RIGHT", 4, 0); f.stackOffYEdit:SetAutoFocus(false)

    -- ======= Stack control scripts =======
    -- Stack font dropdown
    f._initStackFontDrop = function()
        if not f.stackFontDrop or not UIDropDownMenu_Initialize then return end
        if not MSWA.fontChoices then MSWA_RebuildFontChoices() end
        UIDropDownMenu_SetWidth(f.stackFontDrop, 120)
        if not f._mswaStackFontDropInitialized then
            UIDropDownMenu_Initialize(f.stackFontDrop, function(self, level)
                local db = MSWA_GetDB(); local auraKey = MSWA.selectedSpellID
                local s2 = auraKey and select(1, MSWA_GetSpellSettings(db, auraKey)) or nil
                local currentKey = (s2 and s2.stackFontKey) or (db and db.stackFontKey) or (db and db.fontKey) or "DEFAULT"
                for _, data in ipairs(MSWA.fontChoices or {}) do
                    local info = UIDropDownMenu_CreateInfo()
                    info.text = data.label or data.key; info.value = data.key; info.checked = (data.key == currentKey)
                    info.func = function()
                        local key = MSWA.selectedSpellID
                        local db2 = MSWA_GetDB()
                        if key then
                            local ss = select(1, MSWA_GetOrCreateSpellSettings(db2, key))
                            if data.key == "DEFAULT" then ss.stackFontKey = nil else ss.stackFontKey = data.key end
                        else
                            -- No aura selected => set global stack default (nil follows global fontKey)
                            db2.stackFontKey = (data.key == "DEFAULT") and nil or data.key
                        end
                        UIDropDownMenu_SetText(f.stackFontDrop, data.label or data.key); CloseDropDownMenus()
                        if MSWA_ForceUpdateSpells then MSWA_ForceUpdateSpells() else MSWA_RequestUpdateSpells() end
                    end
                    UIDropDownMenu_AddButton(info, level)
                end
            end)
            f._mswaStackFontDropInitialized = true
        end
        local db = MSWA_GetDB(); local auraKey = MSWA.selectedSpellID
        local ss = auraKey and select(1, MSWA_GetSpellSettings(db, auraKey)) or nil
        local fontKey = (ss and ss.stackFontKey) or (db and db.stackFontKey) or (db and db.fontKey) or "DEFAULT"
        local label = "Default (Blizzard)"
        for _, data in ipairs(MSWA.fontChoices or {}) do
            if data.key == fontKey then label = data.label or data.key; break end
        end
        if UIDropDownMenu_SetText then UIDropDownMenu_SetText(f.stackFontDrop, label) end
    end

    -- Stack size +/-
    local function ClampStackSize(v) v = tonumber(v) or 12; if v < 6 then v = 6 end; if v > 48 then v = 48 end; return v end
    local function ApplyStackSize()
        local key = MSWA.selectedSpellID
        local db = MSWA_GetDB()
        local v = ClampStackSize(f.stackSizeEdit and f.stackSizeEdit:GetText())
        if key then
            local s2 = select(1, MSWA_GetOrCreateSpellSettings(db, key))
            s2.stackFontSize = v
        else
            db.stackFontSize = v
        end
        if f.stackSizeEdit then f.stackSizeEdit:SetText(tostring(v)) end
        if MSWA_ForceUpdateSpells then MSWA_ForceUpdateSpells() else MSWA_RequestUpdateSpells() end
    end
    if f.stackSizeEdit then
        f.stackSizeEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyStackSize() end)
        f.stackSizeEdit:SetScript("OnEditFocusLost", function() ApplyStackSize() end)
    end
    f.stackSizeMinus:SetScript("OnClick", function()
        local key = MSWA.selectedSpellID
        local db = MSWA_GetDB()
        local cur = db.stackFontSize or 12
        if key then
            local s2 = select(1, MSWA_GetOrCreateSpellSettings(db, key))
            cur = s2.stackFontSize or cur
        end
        local v = ClampStackSize((f.stackSizeEdit and f.stackSizeEdit:GetText()) or cur) - 1; v = ClampStackSize(v)
        if key then
            local s2 = select(1, MSWA_GetOrCreateSpellSettings(db, key))
            s2.stackFontSize = v
        else
            db.stackFontSize = v
        end
        if f.stackSizeEdit then f.stackSizeEdit:SetText(tostring(v)) end
        if MSWA_ForceUpdateSpells then MSWA_ForceUpdateSpells() else MSWA_RequestUpdateSpells() end
    end)
    f.stackSizePlus:SetScript("OnClick", function()
        local key = MSWA.selectedSpellID
        local db = MSWA_GetDB()
        local cur = db.stackFontSize or 12
        if key then
            local s2 = select(1, MSWA_GetOrCreateSpellSettings(db, key))
            cur = s2.stackFontSize or cur
        end
        local v = ClampStackSize((f.stackSizeEdit and f.stackSizeEdit:GetText()) or cur) + 1; v = ClampStackSize(v)
        if key then
            local s2 = select(1, MSWA_GetOrCreateSpellSettings(db, key))
            s2.stackFontSize = v
        else
            db.stackFontSize = v
        end
        if f.stackSizeEdit then f.stackSizeEdit:SetText(tostring(v)) end
        if MSWA_ForceUpdateSpells then MSWA_ForceUpdateSpells() else MSWA_RequestUpdateSpells() end
    end)

    -- Stack pos dropdown
    if f.stackPosDrop and UIDropDownMenu_Initialize then
        UIDropDownMenu_SetWidth(f.stackPosDrop, 120)
        UIDropDownMenu_Initialize(f.stackPosDrop, function(self, level)
            local db = MSWA_GetDB(); local key = MSWA.selectedSpellID
            local s2 = key and select(1, MSWA_GetSpellSettings(db, key)) or nil
            local cur = (s2 and s2.stackPoint) or (db and db.stackPoint) or "BOTTOMRIGHT"
            for _, point in ipairs({"BOTTOMRIGHT","BOTTOMLEFT","TOPRIGHT","TOPLEFT","CENTER"}) do
                local info = UIDropDownMenu_CreateInfo(); info.text = MSWA_GetTextPosLabel(point); info.checked = (tostring(cur) == tostring(point))
                info.func = function()
                    if key then
                        local ss = select(1, MSWA_GetOrCreateSpellSettings(db, key)); ss.stackPoint = point
                    else
                        db.stackPoint = point
                    end
                    UIDropDownMenu_SetText(f.stackPosDrop, MSWA_GetTextPosLabel(point)); CloseDropDownMenus(); if MSWA_ForceUpdateSpells then MSWA_ForceUpdateSpells() else MSWA_RequestUpdateSpells() end
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
    end

    -- Stack color picker
    f.stackColorBtn:SetScript("OnClick", function()
        local keyAtOpen = MSWA.selectedSpellID
        local db3 = MSWA_GetDB()
        local ss = keyAtOpen and select(1, MSWA_GetSpellSettings(db3, keyAtOpen)) or nil
        local tc = (ss and ss.stackColor) or (db3 and db3.stackColor) or { r = 1, g = 1, b = 1 }
        local r, g, b = tonumber(tc.r) or 1, tonumber(tc.g) or 1, tonumber(tc.b) or 1
        local function ApplySC(nr, ng, nb)
            if keyAtOpen then
                local s3 = select(1, MSWA_GetOrCreateSpellSettings(db3, keyAtOpen))
                if s3 then s3.stackColor = s3.stackColor or {}; s3.stackColor.r = nr; s3.stackColor.g = ng; s3.stackColor.b = nb end
            else
                db3.stackColor = db3.stackColor or {}; db3.stackColor.r = nr; db3.stackColor.g = ng; db3.stackColor.b = nb
            end
            if f.stackColorSwatch and MSWA_KeyEquals(MSWA.selectedSpellID, keyAtOpen) then f.stackColorSwatch:SetColorTexture(nr, ng, nb, 1) end
            if MSWA_ForceUpdateSpells then MSWA_ForceUpdateSpells() else MSWA_RequestUpdateSpells() end
        end
        if ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow then
            local function OnChanged() local nr, ng, nb = ColorPickerFrame:GetColorRGB(); if type(nr) == "number" then ApplySC(nr, ng, nb) end end
            ColorPickerFrame:SetupColorPickerAndShow({ r=r, g=g, b=b, hasOpacity=false, swatchFunc=OnChanged, func=OnChanged, okayFunc=OnChanged, cancelFunc=function(restore) if type(restore) == "table" then ApplySC(restore.r or r, restore.g or g, restore.b or b) else ApplySC(r, g, b) end end })
        elseif ColorPickerFrame then
            ColorPickerFrame.hasOpacity = false; ColorPickerFrame.previousValues = { r=r, g=g, b=b }
            ColorPickerFrame.func = function() ApplySC(ColorPickerFrame:GetColorRGB()) end
            ColorPickerFrame.cancelFunc = function(prev) if type(prev) == "table" then ApplySC(prev.r or r, prev.g or g, prev.b or b) else ApplySC(r, g, b) end end
            ColorPickerFrame:SetColorRGB(r, g, b); ColorPickerFrame:Show()
        end
    end)

    -- Stack offset apply
    local function ApplyStackOffset()
        local db = MSWA_GetDB()
        local key = MSWA.selectedSpellID
        local ox = tonumber(f.stackOffXEdit and f.stackOffXEdit:GetText()) or 0
        local oy = tonumber(f.stackOffYEdit and f.stackOffYEdit:GetText()) or 0
        if key then
            local s2 = select(1, MSWA_GetOrCreateSpellSettings(db, key))
            s2.stackOffsetX = ox
            s2.stackOffsetY = oy
        else
            db.stackOffsetX = ox
            db.stackOffsetY = oy
        end
        if MSWA_ForceUpdateSpells then MSWA_ForceUpdateSpells() else MSWA_RequestUpdateSpells() end
    end
    if f.stackOffXEdit then
        f.stackOffXEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyStackOffset() end)
        f.stackOffXEdit:SetScript("OnEditFocusLost", function() ApplyStackOffset() end)
    end
    if f.stackOffYEdit then
        f.stackOffYEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyStackOffset() end)
        f.stackOffYEdit:SetScript("OnEditFocusLost", function() ApplyStackOffset() end)
    end

    -- ======= Charge Tracker Section =======
    -- User-defined charges: each cast consumes a charge,
    -- recharge timer restores them. 0 charges = desaturated icon.
    local chargeSep = dp:CreateTexture(nil, "ARTWORK")
    chargeSep:SetPoint("TOPLEFT", f.stackColorLabel, "BOTTOMLEFT", 0, -10)
    chargeSep:SetSize(400, 1); chargeSep:SetColorTexture(1, 1, 1, 0.12)

    f.chargeHeaderLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.chargeHeaderLabel:SetPoint("TOPLEFT", chargeSep, "BOTTOMLEFT", 0, -8)
    f.chargeHeaderLabel:SetText("|cff44ddffCharge Tracker|r  (requires aura mode 'Charges')")

    -- Max Charges
    f.chargeMaxLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.chargeMaxLabel:SetPoint("TOPLEFT", f.chargeHeaderLabel, "BOTTOMLEFT", 0, -10)
    f.chargeMaxLabel:SetText("Max Charges:")
    f.chargeMaxEdit = CreateFrame("EditBox", nil, dp, "InputBoxTemplate")
    f.chargeMaxEdit:SetSize(50, 20); f.chargeMaxEdit:SetPoint("LEFT", f.chargeMaxLabel, "RIGHT", 6, 0); f.chargeMaxEdit:SetAutoFocus(false); f.chargeMaxEdit:SetNumeric(true)
    f.chargeMaxMinus = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate"); f.chargeMaxMinus:SetSize(20, 20); f.chargeMaxMinus:SetPoint("LEFT", f.chargeMaxEdit, "RIGHT", 2, 0); f.chargeMaxMinus:SetText("-")
    f.chargeMaxPlus = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate"); f.chargeMaxPlus:SetSize(20, 20); f.chargeMaxPlus:SetPoint("LEFT", f.chargeMaxMinus, "RIGHT", 2, 0); f.chargeMaxPlus:SetText("+")

    -- Recharge Duration (seconds)
    f.chargeDurLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.chargeDurLabel:SetPoint("LEFT", f.chargeMaxPlus, "RIGHT", 14, 0)
    f.chargeDurLabel:SetText("Recharge (sec):")
    f.chargeDurEdit = CreateFrame("EditBox", nil, dp, "InputBoxTemplate")
    f.chargeDurEdit:SetSize(50, 20); f.chargeDurEdit:SetPoint("LEFT", f.chargeDurLabel, "RIGHT", 6, 0); f.chargeDurEdit:SetAutoFocus(false)

    -- Reset Charges button
    f.chargeResetBtn = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate")
    f.chargeResetBtn:SetSize(100, 20); f.chargeResetBtn:SetPoint("TOPLEFT", f.chargeMaxLabel, "BOTTOMLEFT", 0, -10)
    f.chargeResetBtn:SetText("Reset Charges")

    -- Charge Font Size
    f.chargeSizeLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.chargeSizeLabel:SetPoint("TOPLEFT", f.chargeResetBtn, "BOTTOMLEFT", 0, -10)
    f.chargeSizeLabel:SetText("Size:")
    f.chargeSizeEdit = CreateFrame("EditBox", nil, dp, "InputBoxTemplate")
    f.chargeSizeEdit:SetSize(50, 20); f.chargeSizeEdit:SetPoint("LEFT", f.chargeSizeLabel, "RIGHT", 6, 0); f.chargeSizeEdit:SetAutoFocus(false); f.chargeSizeEdit:SetNumeric(true)
    f.chargeSizeMinus = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate"); f.chargeSizeMinus:SetSize(20, 20); f.chargeSizeMinus:SetPoint("LEFT", f.chargeSizeEdit, "RIGHT", 2, 0); f.chargeSizeMinus:SetText("-")
    f.chargeSizePlus = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate"); f.chargeSizePlus:SetSize(20, 20); f.chargeSizePlus:SetPoint("LEFT", f.chargeSizeMinus, "RIGHT", 2, 0); f.chargeSizePlus:SetText("+")

    -- Charge Position
    f.chargePosLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.chargePosLabel:SetPoint("LEFT", f.chargeSizePlus, "RIGHT", 14, 0)
    f.chargePosLabel:SetText("Pos:")
    f.chargePosDrop = CreateFrame("Frame", "MSWA_ChargePosDropDown", dp, "UIDropDownMenuTemplate")
    f.chargePosDrop:SetPoint("LEFT", f.chargePosLabel, "RIGHT", -10, -3)

    -- Charge Color
    f.chargeColorLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.chargeColorLabel:SetPoint("TOPLEFT", f.chargeSizeLabel, "BOTTOMLEFT", 0, -12)
    f.chargeColorLabel:SetText("Color:")
    f.chargeColorBtn = CreateFrame("Button", nil, dp); f.chargeColorBtn:SetSize(18, 18); f.chargeColorBtn:SetPoint("LEFT", f.chargeColorLabel, "RIGHT", 8, 0); f.chargeColorBtn:EnableMouse(true)
    f.chargeColorSwatch = f.chargeColorBtn:CreateTexture(nil, "ARTWORK"); f.chargeColorSwatch:SetAllPoints(true); f.chargeColorSwatch:SetColorTexture(1, 1, 1, 1)
    local chargeBorder = f.chargeColorBtn:CreateTexture(nil, "BORDER"); chargeBorder:SetPoint("TOPLEFT", f.chargeColorBtn, "TOPLEFT", -1, 1); chargeBorder:SetPoint("BOTTOMRIGHT", f.chargeColorBtn, "BOTTOMRIGHT", 1, -1); chargeBorder:SetColorTexture(0, 0, 0, 1)

    -- Charge Offset X/Y
    f.chargeOffXLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.chargeOffXLabel:SetPoint("LEFT", f.chargeColorBtn, "RIGHT", 16, 0)
    f.chargeOffXLabel:SetText("Offset X:")
    f.chargeOffXEdit = CreateFrame("EditBox", nil, dp, "InputBoxTemplate")
    f.chargeOffXEdit:SetSize(40, 20); f.chargeOffXEdit:SetPoint("LEFT", f.chargeOffXLabel, "RIGHT", 4, 0); f.chargeOffXEdit:SetAutoFocus(false)

    f.chargeOffYLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.chargeOffYLabel:SetPoint("LEFT", f.chargeOffXEdit, "RIGHT", 10, 0)
    f.chargeOffYLabel:SetText("Y:")
    f.chargeOffYEdit = CreateFrame("EditBox", nil, dp, "InputBoxTemplate")
    f.chargeOffYEdit:SetSize(40, 20); f.chargeOffYEdit:SetPoint("LEFT", f.chargeOffYLabel, "RIGHT", 4, 0); f.chargeOffYEdit:SetAutoFocus(false)

    -- ======= Charge control scripts =======
    local function ClampChargeMax(v) v = tonumber(v) or 3; if v < 1 then v = 1 end; if v > 20 then v = 20 end; return v end
    local function ApplyChargeMax()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        local v = ClampChargeMax(f.chargeMaxEdit and f.chargeMaxEdit:GetText())
        s2.chargeMax = v
        if f.chargeMaxEdit then f.chargeMaxEdit:SetText(tostring(v)) end
        -- Reset runtime charges to new max
        if MSWA._charges and MSWA._charges[key] then
            MSWA._charges[key].remaining = v
            MSWA._charges[key].rechargeStart = 0
        end
        MSWA_ForceUpdateSpells()
    end
    f.chargeMaxEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyChargeMax() end)
    f.chargeMaxEdit:SetScript("OnEditFocusLost", function() ApplyChargeMax() end)
    f.chargeMaxMinus:SetScript("OnClick", function()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        s2.chargeMax = ClampChargeMax((s2.chargeMax or 3) - 1)
        if f.chargeMaxEdit then f.chargeMaxEdit:SetText(tostring(s2.chargeMax)) end
        if MSWA._charges and MSWA._charges[key] then
            MSWA._charges[key].remaining = s2.chargeMax
            MSWA._charges[key].rechargeStart = 0
        end
        MSWA_ForceUpdateSpells()
    end)
    f.chargeMaxPlus:SetScript("OnClick", function()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        s2.chargeMax = ClampChargeMax((s2.chargeMax or 3) + 1)
        if f.chargeMaxEdit then f.chargeMaxEdit:SetText(tostring(s2.chargeMax)) end
        if MSWA._charges and MSWA._charges[key] then
            MSWA._charges[key].remaining = s2.chargeMax
            MSWA._charges[key].rechargeStart = 0
        end
        MSWA_ForceUpdateSpells()
    end)

    -- Recharge duration apply
    local function ApplyChargeDuration()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        local v = tonumber(f.chargeDurEdit and f.chargeDurEdit:GetText()) or 0
        if v < 0 then v = 0 end
        s2.chargeDuration = v
        if f.chargeDurEdit then f.chargeDurEdit:SetText(tostring(v)) end
        MSWA_ForceUpdateSpells()
    end
    f.chargeDurEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyChargeDuration() end)
    f.chargeDurEdit:SetScript("OnEditFocusLost", function() ApplyChargeDuration() end)

    -- Reset charges button
    f.chargeResetBtn:SetScript("OnClick", function()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetSpellSettings(MSWA_GetDB(), key))
        local maxC = (s2 and tonumber(s2.chargeMax)) or 3
        MSWA._charges = MSWA._charges or {}
        MSWA._charges[key] = { remaining = maxC, rechargeStart = 0 }
        MSWA_ForceUpdateSpells()
    end)

    local function ClampChargeSize(v) v = tonumber(v) or 12; if v < 6 then v = 6 end; if v > 48 then v = 48 end; return v end
    local function ApplyChargeSize()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        local v = ClampChargeSize(f.chargeSizeEdit and f.chargeSizeEdit:GetText())
        s2.chargeFontSize = v
        if f.chargeSizeEdit then f.chargeSizeEdit:SetText(tostring(v)) end
        MSWA_InvalidateIconCache()
    end
    if f.chargeSizeEdit then
        f.chargeSizeEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyChargeSize() end)
        f.chargeSizeEdit:SetScript("OnEditFocusLost", function() ApplyChargeSize() end)
    end
    f.chargeSizeMinus:SetScript("OnClick", function()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        local cur = ClampChargeSize(s2.chargeFontSize or 12)
        s2.chargeFontSize = ClampChargeSize(cur - 1)
        if f.chargeSizeEdit then f.chargeSizeEdit:SetText(tostring(s2.chargeFontSize)) end
        MSWA_InvalidateIconCache()
    end)
    f.chargeSizePlus:SetScript("OnClick", function()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        local cur = ClampChargeSize(s2.chargeFontSize or 12)
        s2.chargeFontSize = ClampChargeSize(cur + 1)
        if f.chargeSizeEdit then f.chargeSizeEdit:SetText(tostring(s2.chargeFontSize)) end
        MSWA_InvalidateIconCache()
    end)

    -- Charge position dropdown
    if UIDropDownMenu_Initialize and UIDropDownMenu_SetWidth then
        UIDropDownMenu_SetWidth(f.chargePosDrop, 100)
        UIDropDownMenu_Initialize(f.chargePosDrop, function(self, level)
            local posLabels = MSWA_TEXT_POS_LABELS or {}
            local key = MSWA.selectedSpellID
            local db3 = MSWA_GetDB()
            local s3 = key and select(1, MSWA_GetSpellSettings(db3, key)) or nil
            local curPos = (s3 and s3.chargePoint) or "BOTTOMRIGHT"
            for pt, label in pairs(posLabels) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = label; info.value = pt; info.checked = (pt == curPos)
                info.func = function()
                    local k2 = MSWA.selectedSpellID; if not k2 then return end
                    local ss = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), k2))
                    ss.chargePoint = pt
                    UIDropDownMenu_SetText(f.chargePosDrop, label); CloseDropDownMenus()
                    MSWA_InvalidateIconCache()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
    end

    -- Charge color picker
    f.chargeColorBtn:SetScript("OnClick", function()
        local keyAtOpen = MSWA.selectedSpellID
        local db3 = MSWA_GetDB()
        local ss = keyAtOpen and select(1, MSWA_GetSpellSettings(db3, keyAtOpen)) or nil
        local tc = (ss and ss.chargeColor) or { r = 1, g = 1, b = 1 }
        local r, g, b = tonumber(tc.r) or 1, tonumber(tc.g) or 1, tonumber(tc.b) or 1
        local function ApplyCC(nr, ng, nb)
            if keyAtOpen then
                local s3 = select(1, MSWA_GetOrCreateSpellSettings(db3, keyAtOpen))
                if s3 then s3.chargeColor = s3.chargeColor or {}; s3.chargeColor.r = nr; s3.chargeColor.g = ng; s3.chargeColor.b = nb end
            end
            if f.chargeColorSwatch and MSWA_KeyEquals(MSWA.selectedSpellID, keyAtOpen) then f.chargeColorSwatch:SetColorTexture(nr, ng, nb, 1) end
            MSWA_InvalidateIconCache()
        end
        if ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow then
            local function OnChanged() local nr, ng, nb = ColorPickerFrame:GetColorRGB(); if type(nr) == "number" then ApplyCC(nr, ng, nb) end end
            ColorPickerFrame:SetupColorPickerAndShow({ r=r, g=g, b=b, hasOpacity=false, swatchFunc=OnChanged, func=OnChanged, okayFunc=OnChanged, cancelFunc=function(restore) if type(restore) == "table" then ApplyCC(restore.r or r, restore.g or g, restore.b or b) else ApplyCC(r, g, b) end end })
        elseif ColorPickerFrame then
            ColorPickerFrame.hasOpacity = false; ColorPickerFrame.previousValues = { r=r, g=g, b=b }
            ColorPickerFrame.func = function() ApplyCC(ColorPickerFrame:GetColorRGB()) end
            ColorPickerFrame.cancelFunc = function(prev) if type(prev) == "table" then ApplyCC(prev.r or r, prev.g or g, prev.b or b) else ApplyCC(r, g, b) end end
            ColorPickerFrame:SetColorRGB(r, g, b); ColorPickerFrame:Show()
        end
    end)

    -- Charge offset apply
    local function ApplyChargeOffset()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        s2.chargeOffsetX = tonumber(f.chargeOffXEdit and f.chargeOffXEdit:GetText()) or 0
        s2.chargeOffsetY = tonumber(f.chargeOffYEdit and f.chargeOffYEdit:GetText()) or 0
        MSWA_InvalidateIconCache()
    end
    if f.chargeOffXEdit then
        f.chargeOffXEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyChargeOffset() end)
        f.chargeOffXEdit:SetScript("OnEditFocusLost", function() ApplyChargeOffset() end)
    end
    if f.chargeOffYEdit then
        f.chargeOffYEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyChargeOffset() end)
        f.chargeOffYEdit:SetScript("OnEditFocusLost", function() ApplyChargeOffset() end)
    end

    -- ======= Conditional 2nd Text Color =======
    local tc2Sep = dp:CreateTexture(nil, "ARTWORK")
    tc2Sep:SetPoint("TOPLEFT", f.chargeColorLabel, "BOTTOMLEFT", 0, -10)
    tc2Sep:SetSize(400, 1); tc2Sep:SetColorTexture(1, 1, 1, 0.12)

    f.tc2Check = CreateFrame("CheckButton", nil, dp, "ChatConfigCheckButtonTemplate")
    f.tc2Check:SetPoint("TOPLEFT", tc2Sep, "BOTTOMLEFT", -4, -8)
    f.tc2Label = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.tc2Label:SetPoint("LEFT", f.tc2Check, "RIGHT", 2, 0)
    f.tc2Label:SetText("|cffffcc00Conditional text color|r")

    -- 2nd color swatch
    f.tc2ColorLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.tc2ColorLabel:SetPoint("TOPLEFT", f.tc2Check, "BOTTOMLEFT", 22, -8)
    f.tc2ColorLabel:SetText("Color:")
    f.tc2ColorBtn = CreateFrame("Button", nil, dp)
    f.tc2ColorBtn:SetSize(18, 18); f.tc2ColorBtn:SetPoint("LEFT", f.tc2ColorLabel, "RIGHT", 6, 0); f.tc2ColorBtn:EnableMouse(true)
    f.tc2ColorSwatch = f.tc2ColorBtn:CreateTexture(nil, "ARTWORK"); f.tc2ColorSwatch:SetAllPoints(true); f.tc2ColorSwatch:SetColorTexture(1, 0, 0, 1)
    local tc2Border = f.tc2ColorBtn:CreateTexture(nil, "BORDER"); tc2Border:SetPoint("TOPLEFT", f.tc2ColorBtn, "TOPLEFT", -1, 1); tc2Border:SetPoint("BOTTOMRIGHT", f.tc2ColorBtn, "BOTTOMRIGHT", 1, -1); tc2Border:SetColorTexture(0, 0, 0, 1)

    -- Condition button (cycles: TIMER_BELOW ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ TIMER_ABOVE)
    f.tc2CondLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.tc2CondLabel:SetPoint("LEFT", f.tc2ColorBtn, "RIGHT", 16, 0)
    f.tc2CondLabel:SetText("When:")
    f.tc2CondButton = CreateFrame("Button", nil, dp, "UIPanelButtonTemplate")
    f.tc2CondButton:SetSize(90, 20); f.tc2CondButton:SetPoint("LEFT", f.tc2CondLabel, "RIGHT", 4, 0)

    -- Threshold value (editbox right of button, then "sec" label)
    f.tc2ValueEdit = CreateFrame("EditBox", nil, dp, "InputBoxTemplate")
    f.tc2ValueEdit:SetSize(40, 20); f.tc2ValueEdit:SetPoint("LEFT", f.tc2CondButton, "RIGHT", 6, 0)
    f.tc2ValueEdit:SetAutoFocus(false)
    f.tc2ValueLabel = dp:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.tc2ValueLabel:SetPoint("LEFT", f.tc2ValueEdit, "RIGHT", 4, 0)
    f.tc2ValueLabel:SetText("sec")

    -- Set scroll child height (covers all content so scrollbar appears when needed)
    dp:SetHeight(770)

    -- Helper: update condition button text
    local function UpdateTC2CondText(cond)
        if not f.tc2CondButton then return end
        if cond == "TIMER_ABOVE" then
            f.tc2CondButton:SetText("Timer >= X")
        else
            f.tc2CondButton:SetText("Timer <= X")
        end
    end

    -- Enable checkbox
    f.tc2Check:SetScript("OnClick", function(self)
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        s2.textColor2Enabled = self:GetChecked() and true or nil
        if s2.textColor2Enabled and not s2.textColor2 then
            s2.textColor2 = { r = 1, g = 0.2, b = 0.2 }
        end
        MSWA_RequestUpdateSpells(); MSWA_UpdateDetailPanel()
    end)

    -- Condition cycle
    f.tc2CondButton:SetScript("OnClick", function()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        local cur = s2.textColor2Cond or "TIMER_BELOW"
        s2.textColor2Cond = (cur == "TIMER_BELOW") and "TIMER_ABOVE" or "TIMER_BELOW"
        UpdateTC2CondText(s2.textColor2Cond)
        MSWA_RequestUpdateSpells()
    end)

    -- Value edit
    local function ApplyTC2Value()
        local key = MSWA.selectedSpellID; if not key then return end
        local s2 = select(1, MSWA_GetOrCreateSpellSettings(MSWA_GetDB(), key))
        local v = tonumber(f.tc2ValueEdit:GetText())
        if v and v >= 0 then s2.textColor2Value = v end
        MSWA_RequestUpdateSpells()
    end
    f.tc2ValueEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); ApplyTC2Value() end)
    f.tc2ValueEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.tc2ValueEdit:SetScript("OnEditFocusLost", function() ApplyTC2Value() end)

    -- Color picker for 2nd color
    f.tc2ColorBtn:SetScript("OnClick", function()
        local keyAtOpen = MSWA.selectedSpellID; if not keyAtOpen then return end
        local db3 = MSWA_GetDB()
        local ss = keyAtOpen and select(1, MSWA_GetSpellSettings(db3, keyAtOpen)) or nil
        local tc2 = (ss and ss.textColor2) or { r = 1, g = 0.2, b = 0.2 }
        local r, g, b = tonumber(tc2.r) or 1, tonumber(tc2.g) or 0.2, tonumber(tc2.b) or 0.2
        local function ApplyC2(nr, ng, nb)
            local s3 = keyAtOpen and select(1, MSWA_GetOrCreateSpellSettings(db3, keyAtOpen)) or nil
            if s3 then s3.textColor2 = s3.textColor2 or {}; s3.textColor2.r = nr; s3.textColor2.g = ng; s3.textColor2.b = nb end
            if f.tc2ColorSwatch and MSWA_KeyEquals(MSWA.selectedSpellID, keyAtOpen) then f.tc2ColorSwatch:SetColorTexture(nr, ng, nb, 1) end
            MSWA_RequestUpdateSpells()
        end
        if ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow then
            local function OnChanged() local nr, ng, nb = ColorPickerFrame:GetColorRGB(); if type(nr) == "number" then ApplyC2(nr, ng, nb) end end
            ColorPickerFrame:SetupColorPickerAndShow({ r=r, g=g, b=b, hasOpacity=false, swatchFunc=OnChanged, func=OnChanged, okayFunc=OnChanged, cancelFunc=function(restore) if type(restore) == "table" then ApplyC2(restore.r or r, restore.g or g, restore.b or b) else ApplyC2(r, g, b) end end })
        elseif ColorPickerFrame then
            ColorPickerFrame.hasOpacity = false; ColorPickerFrame.previousValues = { r=r, g=g, b=b }
            ColorPickerFrame.func = function() ApplyC2(ColorPickerFrame:GetColorRGB()) end
            ColorPickerFrame.cancelFunc = function(prev) if type(prev) == "table" then ApplyC2(prev.r or r, prev.g or g, prev.b or b) else ApplyC2(r, g, b) end end
            ColorPickerFrame:SetColorRGB(r, g, b); ColorPickerFrame:Show()
        end
    end)

    -- Apply logic + hooks (identical to original)
    local function ApplyDisplay()
        local key = MSWA.selectedSpellID
        if not key then return end
        local db = MSWA_GetDB()
        db.spellSettings = db.spellSettings or {}
        local s = db.spellSettings[key] or {}

        local x = tonumber(f.detailX:GetText() or "") or 0
        local y = tonumber(f.detailY:GetText() or "") or 0
        local w = tonumber(f.detailW:GetText() or "") or MSWA.ICON_SIZE
        local h = tonumber(f.detailH:GetText() or "") or MSWA.ICON_SIZE

        if w < 16 then w = 16 end
        if h < 16 then h = 16 end
        if w > 128 then w = 128 end
        if h > 128 then h = 128 end

        s.x = x; s.y = y; s.width = w; s.height = h
        db.spellSettings[key] = s

        -- Live-apply size instantly to the currently visible icon (no waiting for engine throttle)
        if MSWA.icons then
            for i = 1, (MSWA.MAX_ICONS or 0) do
                local btn = MSWA.icons[i]
                if btn and btn.spellID and ((MSWA_KeyEquals and MSWA_KeyEquals(btn.spellID, key)) or btn.spellID == key) then
                    btn:SetSize(w, h)
                    break
                end
            end
        end
        if type(MSWA_ReskinMasque) == "function" then MSWA_ReskinMasque() end

        if MSWA_ForceUpdateSpells then MSWA_ForceUpdateSpells() else MSWA_RequestUpdateSpells() end
    end
    local function ApplyAnchor() local key = MSWA.selectedSpellID; if not key then return end; local db = MSWA_GetDB(); db.spellSettings = db.spellSettings or {}; local s = db.spellSettings[key] or {}
        local a = f.detailA:GetText() or ""
        a = tostring(a):gsub("^%s+", ""):gsub("%s+$", "")
        if a == "" then a = nil end

        -- If this aura belongs to a group, the group is the master anchor.
        local gid = (MSWA_GetAuraGroup and MSWA_GetAuraGroup(key)) or nil
        if gid and db.groups and db.groups[gid] then
            local g = db.groups[gid]
            g.anchorFrame = a
            -- Keep per-aura anchor cleared while grouped (prevents confusion/overrides).
            s.anchorFrame = nil
            db.groups[gid] = g
        else
            s.anchorFrame = a
        end

        db.spellSettings[key] = s
        MSWA_RequestUpdateSpells()
        MSWA_UpdateDetailPanel()
    end
    local function HookBox(box, applyFunc) if not box then return end; box:SetScript("OnEnterPressed", function(self) self:ClearFocus(); applyFunc() end); box:SetScript("OnEditFocusLost", function() applyFunc() end) end
    HookBox(f.detailX, ApplyDisplay); HookBox(f.detailY, ApplyDisplay); HookBox(f.detailW, ApplyDisplay); HookBox(f.detailH, ApplyDisplay); HookBox(f.detailA, ApplyAnchor)

    -- Live-apply width/height while typing (debounced) for instant feedback
    local function HookLiveNumeric(box, applyFunc, delay)
        if not (box and applyFunc) then return end
        if not (C_Timer and C_Timer.After) then return end
        local token = 0
        box:HookScript("OnTextChanged", function(self, userInput)
            if not userInput then return end
            if not self:HasFocus() then return end
            local n = tonumber(self:GetText() or "")
            if not n then return end
            token = token + 1
            local my = token
            C_Timer.After(delay or 0.12, function()
                if token ~= my then return end
                if self._mswaSkipApply then return end
                applyFunc()
            end)
        end)
    end
    HookLiveNumeric(f.detailW, ApplyDisplay, 0.14)
    HookLiveNumeric(f.detailH, ApplyDisplay, 0.14)


    -- Text size +/-
    local function ClampTextSize(v) v = tonumber(v) or 12; if v < 6 then v = 6 end; if v > 48 then v = 48 end; return v end
    local function ApplyTextSize() local db = MSWA_GetDB(); local key = MSWA.selectedSpellID; local s = key and select(1, MSWA_GetOrCreateSpellSettings(db, key)) or nil
        local cur = (s and s.textFontSize) or db.textFontSize; local v = ClampTextSize(f.textSizeEdit and f.textSizeEdit:GetText() or cur)
        if s then s.textFontSize = v else db.textFontSize = v end; if f.textSizeEdit then f.textSizeEdit:SetText(tostring(v)) end; if MSWA_ForceUpdateSpells then MSWA_ForceUpdateSpells() else MSWA_RequestUpdateSpells() end
    end
    HookBox(f.textSizeEdit, ApplyTextSize)
    f.textSizeMinus:SetScript("OnClick", function() local db = MSWA_GetDB(); local key = MSWA.selectedSpellID; local s = key and select(1, MSWA_GetOrCreateSpellSettings(db, key)) or nil
        local cur = (s and s.textFontSize) or db.textFontSize; local v = ClampTextSize((f.textSizeEdit and f.textSizeEdit:GetText()) or cur) - 1; v = ClampTextSize(v)
        if s then s.textFontSize = v else db.textFontSize = v end; if f.textSizeEdit then f.textSizeEdit:SetText(tostring(v)) end; if MSWA_ForceUpdateSpells then MSWA_ForceUpdateSpells() else MSWA_RequestUpdateSpells() end
    end)
    f.textSizePlus:SetScript("OnClick", function() local db = MSWA_GetDB(); local key = MSWA.selectedSpellID; local s = key and select(1, MSWA_GetOrCreateSpellSettings(db, key)) or nil
        local cur = (s and s.textFontSize) or db.textFontSize; local v = ClampTextSize((f.textSizeEdit and f.textSizeEdit:GetText()) or cur) + 1; v = ClampTextSize(v)
        if s then s.textFontSize = v else db.textFontSize = v end; if f.textSizeEdit then f.textSizeEdit:SetText(tostring(v)) end; if MSWA_ForceUpdateSpells then MSWA_ForceUpdateSpells() else MSWA_RequestUpdateSpells() end
    end)

    -- Text pos dropdown
    if f.textPosDrop and UIDropDownMenu_Initialize then
        UIDropDownMenu_SetWidth(f.textPosDrop, 120)
        UIDropDownMenu_Initialize(f.textPosDrop, function(self, level) local db = MSWA_GetDB(); local key = MSWA.selectedSpellID; local s = key and select(1, MSWA_GetSpellSettings(db, key)) or nil; local cur = (s and s.textPoint) or db.textPoint or "BOTTOMRIGHT"
            for _, point in ipairs({"BOTTOMRIGHT","BOTTOMLEFT","TOPRIGHT","TOPLEFT","CENTER"}) do
                local info = UIDropDownMenu_CreateInfo(); info.text = MSWA_GetTextPosLabel(point); info.checked = (tostring(cur) == tostring(point))
                info.func = function()
                    if key then
                        local s2 = select(1, MSWA_GetOrCreateSpellSettings(db, key)); s2.textPoint = point
                    else
                        db.textPoint = point
                    end
                    UIDropDownMenu_SetText(f.textPosDrop, MSWA_GetTextPosLabel(point)); CloseDropDownMenus(); if MSWA_ForceUpdateSpells then MSWA_ForceUpdateSpells() else MSWA_RequestUpdateSpells() end
                end
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
        Add("Auto", "AUTO"); Add("Spell", "SPELL"); Add("Item", "ITEM"); Add("Auto Buff", "AUTOBUFF"); Add("Item Buff", "ITEMBUFF"); Add("Buff -> CD", "BUFF_THEN_CD"); Add("Item Buff -> CD", "ITEMBUFF_THEN_CD"); Add("Reminder Buff", "REMINDER_BUFF"); Add("Item Reminder", "ITEM_REMINDER"); Add("Spell Charges", "SPELL_CHARGES"); Add("Item Charges", "ITEM_CHARGES")
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
        local function IsAlreadySpell(sid) if db.trackedSpells[sid] then return true end; for k, en in pairs(db.trackedSpells) do if en and MSWA_IsSpellInstanceKey(k) and MSWA_KeyToSpellID(k) == sid then return true end end; return false end
        local function IsAlreadyItem(iid) local bk = ("item:%d"):format(iid); if db.trackedItems[iid] then return true end; for k, en in pairs(db.trackedSpells) do if en and MSWA_IsItemKey(k) and MSWA_KeyToItemID(k) == iid then return true end end; return false end
        if mode == "ITEM" then
            if IsAlreadyItem(id) then newKey = MSWA_NewItemInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedItems[id] = true; newKey = ("item:%d"):format(id) end
        elseif mode == "SPELL" then local name = MSWA_GetSpellName(id); if not name then return end; if IsAlreadySpell(id) then newKey = MSWA_NewSpellInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedSpells[id] = true; newKey = id end
        elseif mode == "AUTOBUFF" then if IsAlreadySpell(id) then newKey = MSWA_NewSpellInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedSpells[id] = true; newKey = id end; db.spellSettings = db.spellSettings or {}; local s = db.spellSettings[newKey] or {}; s.auraMode = "AUTOBUFF"; if not s.autoBuffDuration then s.autoBuffDuration = 10 end; db.spellSettings[newKey] = s
        elseif mode == "ITEMBUFF" then
            if IsAlreadyItem(id) then newKey = MSWA_NewItemInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedItems[id] = true; newKey = ("item:%d"):format(id) end
            db.spellSettings = db.spellSettings or {}; local s = db.spellSettings[newKey] or {}; s.auraMode = "AUTOBUFF"; if not s.autoBuffDuration then s.autoBuffDuration = 10 end; db.spellSettings[newKey] = s
        elseif mode == "BUFF_THEN_CD" then if IsAlreadySpell(id) then newKey = MSWA_NewSpellInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedSpells[id] = true; newKey = id end; db.spellSettings = db.spellSettings or {}; local s = db.spellSettings[newKey] or {}; s.auraMode = "BUFF_THEN_CD"; if not s.autoBuffDuration then s.autoBuffDuration = 10 end; db.spellSettings[newKey] = s
        elseif mode == "ITEMBUFF_THEN_CD" then
            if IsAlreadyItem(id) then newKey = MSWA_NewItemInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedItems[id] = true; newKey = ("item:%d"):format(id) end
            db.spellSettings = db.spellSettings or {}; local s = db.spellSettings[newKey] or {}; s.auraMode = "BUFF_THEN_CD"; if not s.autoBuffDuration then s.autoBuffDuration = 10 end; db.spellSettings[newKey] = s
        elseif mode == "REMINDER_BUFF" then
            if IsAlreadySpell(id) then newKey = MSWA_NewSpellInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedSpells[id] = true; newKey = id end
            db.spellSettings = db.spellSettings or {}; local s = db.spellSettings[newKey] or {}; s.auraMode = "REMINDER_BUFF"; if not s.autoBuffDuration then s.autoBuffDuration = 3600 end; s.reminderText = "MISSING!"; s.reminderTextColor = { r = 1, g = 0.2, b = 0.2 }; db.spellSettings[newKey] = s
        elseif mode == "ITEM_REMINDER" then
            if IsAlreadyItem(id) then newKey = MSWA_NewItemInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedItems[id] = true; newKey = ("item:%d"):format(id) end
            db.spellSettings = db.spellSettings or {}; local s = db.spellSettings[newKey] or {}; s.auraMode = "REMINDER_BUFF"; if not s.autoBuffDuration then s.autoBuffDuration = 3600 end; s.reminderText = "MISSING!"; s.reminderTextColor = { r = 1, g = 0.2, b = 0.2 }; db.spellSettings[newKey] = s
        elseif mode == "SPELL_CHARGES" then
            if IsAlreadySpell(id) then newKey = MSWA_NewSpellInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedSpells[id] = true; newKey = id end
            db.spellSettings = db.spellSettings or {}; local s = db.spellSettings[newKey] or {}; s.auraMode = "CHARGES"; if not s.chargeMax then s.chargeMax = 3 end; if not s.chargeDuration then s.chargeDuration = 0 end; db.spellSettings[newKey] = s
            MSWA._charges = MSWA._charges or {}; MSWA._charges[newKey] = { remaining = s.chargeMax, rechargeStart = 0 }
        elseif mode == "ITEM_CHARGES" then
            if IsAlreadyItem(id) then newKey = MSWA_NewItemInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedItems[id] = true; newKey = ("item:%d"):format(id) end
            db.spellSettings = db.spellSettings or {}; local s = db.spellSettings[newKey] or {}; s.auraMode = "CHARGES"; if not s.chargeMax then s.chargeMax = 3 end; if not s.chargeDuration then s.chargeDuration = 0 end; db.spellSettings[newKey] = s
            MSWA._charges = MSWA._charges or {}; MSWA._charges[newKey] = { remaining = s.chargeMax, rechargeStart = 0 }
        else local name = MSWA_GetSpellName(id); if name then if IsAlreadySpell(id) then newKey = MSWA_NewSpellInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedSpells[id] = true; newKey = id end else if IsAlreadyItem(id) then newKey = MSWA_NewItemInstanceKey(id); db.trackedSpells[newKey] = true else db.trackedItems[id] = true; newKey = ("item:%d"):format(id) end end end
        local oldKey = MSWA.selectedSpellID; if oldKey and MSWA_IsDraftKey(oldKey) and newKey then ReplaceDraftWithNewKey(oldKey, newKey) end
        MSWA.selectedSpellID = newKey; f.addEdit:SetText(""); MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList()
    end
    f.addButton:SetScript("OnClick", AddFromUI); f.addEdit:SetScript("OnEnterPressed", AddFromUI); f.addEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Drag & drop from Spellbook / Inventory ----------------------------------
    -- GetCursorInfo() returns in WoW 12.0 Midnight:
    --   spell:  "spell", bookSlotIndex, bookType, spellID
    --   item:   "item",  itemID,        itemLink
    --   macro:  "macro", macroIndex
    -- NOTE: For spells the FIRST number (id) is the book-slot index, NOT the
    --        spell ID.  The actual spell ID lives in the 4th return (extra).
    --        We resolve through C_Spell.GetSpellInfo which accepts both ID
    --        and spell name, exactly like AceGUI / BetterCooldownManager do.

    local function ResolveSpellIDFromCursor(id, info, extra)
        -- Try extra first (spellID in 12.0)
        if extra then
            local data = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(extra)
            if data and data.spellID then return data.spellID, data.name end
        end
        -- Try id (may be spellID in some API versions)
        if id then
            local data = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
            if data and data.spellID then return data.spellID, data.name end
        end
        -- Try id as name string (spell dragged by name)
        if id and type(id) == "string" then
            local data = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
            if data and data.spellID then return data.spellID, data.name end
        end
        return nil, nil
    end

    local function ResolveItemIDFromCursor(id, info)
        -- id = itemID for item drags
        local itemID = tonumber(id)
        if itemID and itemID > 0 then return itemID end
        -- Fallback: parse from itemLink in info
        if type(info) == "string" then
            local parsed = info:match("item:(%d+)")
            if parsed then return tonumber(parsed) end
        end
        return nil
    end

    local function HandleCursorDrop()
        if not GetCursorInfo then return false end
        local cursorType, id, info, extra = GetCursorInfo()
        if not cursorType then return false end

        local numericID
        if cursorType == "spell" then
            local spellID, spellName = ResolveSpellIDFromCursor(id, info, extra)
            if not spellID then ClearCursor(); return false end
            numericID = spellID
            f.idType = "SPELL"
            if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(f.idTypeDrop, "SPELL") end
            if UIDropDownMenu_SetText then UIDropDownMenu_SetText(f.idTypeDrop, "Spell") end

        elseif cursorType == "item" then
            local itemID = ResolveItemIDFromCursor(id, info)
            if not itemID then ClearCursor(); return false end
            numericID = itemID
            f.idType = "ITEM"
            if UIDropDownMenu_SetSelectedValue then UIDropDownMenu_SetSelectedValue(f.idTypeDrop, "ITEM") end
            if UIDropDownMenu_SetText then UIDropDownMenu_SetText(f.idTypeDrop, "Item") end

        elseif cursorType == "macro" then
            -- Macro drag: try to resolve spell inside the macro (best effort)
            ClearCursor(); return false
        else
            ClearCursor(); return false
        end

        f.addEdit:SetText(tostring(numericID))
        ClearCursor()
        AddFromUI()
        return true
    end

    -- addEdit receives drag (like AceGUI EditBox)
    f.addEdit:SetScript("OnReceiveDrag", function() HandleCursorDrop() end)
    f.addEdit:HookScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and GetCursorInfo and GetCursorInfo() then HandleCursorDrop() end
    end)

    -- dropZone receives drag
    f.dropZone:SetScript("OnReceiveDrag", function() HandleCursorDrop() end)
    f.dropZone:SetScript("OnClick", function(self, button)
        if button == "LeftButton" and GetCursorInfo and GetCursorInfo() then HandleCursorDrop() end
    end)
    f.dropZone:RegisterForClicks("LeftButtonUp")

    -- dropZone hover highlight
    f.dropZone:SetScript("OnEnter", function(self)
        local hasCursor = GetCursorInfo and GetCursorInfo()
        if hasCursor then
            self.bg:SetColorTexture(0.15, 0.25, 0.15, 0.8)
            self.border:SetBackdropBorderColor(0.3, 0.9, 0.3, 1)
            self.label:SetText("|cff44ff44Release to add aura|r")
            self.icon:SetDesaturated(false)
            self.icon:SetVertexColor(0.4, 1, 0.4)
        else
            self.bg:SetColorTexture(0.18, 0.18, 0.18, 0.8)
            self.border:SetBackdropBorderColor(0.7, 0.7, 0.7, 1)
            self.label:SetText("|cffbbbbbbDrop Spell or Item here|r")
            self.icon:SetDesaturated(true)
            self.icon:SetVertexColor(0.85, 0.85, 0.85)
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Drag & Drop", 1, 0.82, 0)
        GameTooltip:AddLine("Drag a spell from your Spellbook or", 1, 1, 1)
        GameTooltip:AddLine("an item from your Bags to add it.", 1, 1, 1)
        GameTooltip:Show()
    end)
    f.dropZone:SetScript("OnLeave", function(self)
        self.bg:SetColorTexture(0.12, 0.12, 0.12, 0.7)
        self.border:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
        self.label:SetText("|cff888888Drop Spell or Item here|r")
        self.icon:SetDesaturated(true)
        self.icon:SetVertexColor(0.7, 0.7, 0.7)
        GameTooltip:Hide()
    end)

    -- Top button scripts
    f.btnNew:SetScript("OnClick", function() local db = MSWA_GetDB(); db.trackedSpells = db.trackedSpells or {}; local dk = MSWA_NewDraftKey(); db.trackedSpells[dk] = true; MSWA.selectedSpellID = dk; MSWA.selectedGroupID = nil; SetActiveTab("GENERAL"); MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList(); if f.addEdit then f.addEdit:SetFocus(); f.addEdit:HighlightText() end end)
    f.btnGroup:SetScript("OnClick", function() local gid = MSWA_CreateGroup(nil); MSWA.selectedSpellID = nil; MSWA.selectedGroupID = gid; MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList() end)
    f.btnPreview:SetScript("OnClick", function()
        MSWA.previewMode = not MSWA.previewMode
        if MSWA.previewMode then f.btnPreview:SetText("|cff00ff00Preview|r"); MSWA_Print("Preview ON") else f.btnPreview:SetText("Preview"); MSWA_Print("Preview OFF.") end
        MSWA_RequestUpdateSpells()
    end)

    local function SyncIDInfoBtn()
        local db = MSWA_GetDB()
        if db.showSpellID or db.showIconID then
            f.btnIDInfo:SetText("|cff00ff00ID Info|r")
        else
            f.btnIDInfo:SetText("ID Info")
        end
    end
    f.btnIDInfo:SetScript("OnClick", function(self, button)
        local db = MSWA_GetDB()
        if button == "RightButton" then
            -- Right-click: cycle modes (Both ÃƒÂ¢Ã¢â‚¬Â Ã¢â‚¬â„¢ Spell only ÃƒÂ¢Ã¢â‚¬Â Ã¢â‚¬â„¢ Icon only ÃƒÂ¢Ã¢â‚¬Â Ã¢â‚¬â„¢ Off)
            if db.showSpellID and db.showIconID then
                db.showSpellID = true; db.showIconID = false
                MSWA_Print("Tooltip: Spell/Item ID only")
            elseif db.showSpellID and not db.showIconID then
                db.showSpellID = false; db.showIconID = true
                MSWA_Print("Tooltip: Icon ID only")
            elseif not db.showSpellID and db.showIconID then
                db.showSpellID = false; db.showIconID = false
                MSWA_Print("Tooltip: ID Info OFF")
            else
                db.showSpellID = true; db.showIconID = true
                MSWA_Print("Tooltip: Spell/Item ID + Icon ID")
            end
        else
            -- Left-click: simple toggle both
            local on = not (db.showSpellID or db.showIconID)
            db.showSpellID = on; db.showIconID = on
            if on then MSWA_Print("Tooltip ID Info ON") else MSWA_Print("Tooltip ID Info OFF") end
        end
        SyncIDInfoBtn()
    end)
    f.btnIDInfo:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f.btnIDInfo:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("ID Info", 1, 0.82, 0)
        GameTooltip:AddLine("Left-click: toggle on/off", 1, 1, 1)
        GameTooltip:AddLine("Right-click: cycle modes", 0.7, 0.7, 0.7)
        local db = MSWA_GetDB()
        local status = "Off"
        if db.showSpellID and db.showIconID then status = "Spell + Icon ID"
        elseif db.showSpellID then status = "Spell/Item ID only"
        elseif db.showIconID then status = "Icon ID only" end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Current: |cffffffff" .. status .. "|r", 1, 0.82, 0)
        GameTooltip:Show()
    end)
    f.btnIDInfo:SetScript("OnLeave", function() GameTooltip:Hide() end)
    SyncIDInfoBtn()
    f.btnImport:SetScript("OnClick", function() MSWA_OpenImportFrame() end)
    f.btnExport:SetScript("OnClick", function()
        if MSWA.selectedGroupID then MSWA_ExportGroup(MSWA.selectedGroupID); return end
        local key = MSWA.selectedSpellID; if not key then MSWA_Print("Select an aura or group to export."); return end
        local db = MSWA_GetDB(); local gid = db.auraGroups and (db.auraGroups[key] or db.auraGroups[tostring(key)])
        if gid and db.groups and db.groups[gid] then MSWA_ExportGroup(gid); return end
        MSWA_ExportAura(key)
    end)

    -- OnShow / OnHide / OnSizeChanged
    f:SetScript("OnSizeChanged", function(self)
        if self:IsShown() and self.UpdateAuraList then
            self:UpdateAuraList()
        end
    end)
    f:SetScript("OnShow", function()
        MSWA.selectedSpellID = nil; MSWA.selectedGroupID = nil; MSWA.previewMode = false
        if f.btnPreview then f.btnPreview:SetText("Preview") end
        SyncIDInfoBtn()
        f.activeTab = "GENERAL"
        if f.tabGeneral then f.tabGeneral:LockHighlight() end; if f.tabDisplay then f.tabDisplay:UnlockHighlight() end; if f.tabGlow then f.tabGlow:UnlockHighlight() end; if f.tabImport then f.tabImport:UnlockHighlight() end
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
        db.trackedItems = db.trackedItems or {}; db.trackedSpells = db.trackedSpells or {}
        local newKey
        if db.trackedItems[id] then newKey = MSWA_NewItemInstanceKey(id); db.trackedSpells[newKey] = true
        else db.trackedItems[id] = true; newKey = ("item:%d"):format(id) end
        MSWA.selectedSpellID = newKey; MSWA_RequestUpdateSpells(); MSWA_RefreshOptionsList()
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

    if cmd == "id" or cmd == "idinfo" then
        local on = not (db.showSpellID or db.showIconID)
        db.showSpellID = on; db.showIconID = on
        if on then MSWA_Print("Tooltip ID Info ON") else MSWA_Print("Tooltip ID Info OFF") end
        local optF = MSWA.optionsFrame
        if optF and optF.btnIDInfo then
            if on then optF.btnIDInfo:SetText("|cff00ff00ID Info|r") else optF.btnIDInfo:SetText("ID Info") end
        end
        return
    end

    MSWA_Print("Commands: /msa, /msa move, /msa lock, /msa reset, /msa add <ID>, /msa remove <ID>, /msa additem <ID>, /msa removeitem <ID>, /msa list, /msa id")
end

-----------------------------------------------------------
-- Open helpers (called by MSUF)
-----------------------------------------------------------

function MSWA_OpenOptions() MSWA_ToggleOptions() end
function MidnightSimpleAuras_OpenOptions() MSWA_ToggleOptions() end
