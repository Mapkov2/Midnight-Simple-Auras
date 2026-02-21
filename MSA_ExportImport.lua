-- ########################################################
-- MSA_ExportImport.lua
-- Serialize, parse, export/import frames, string building
-- ########################################################

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local tinsert = table.insert

-----------------------------------------------------------
-- Serialization helper
-----------------------------------------------------------

function MSWA_SerializeValue(v, indent, stack)
    indent = indent or ""
    stack = stack or {}

    local tv = type(v)
    if tv == "nil" then return "nil"
    elseif tv == "boolean" then return v and "true" or "false"
    elseif tv == "number" then return tostring(v)
    elseif tv == "string" then return string.format("%q", v)
    elseif tv == "table" then
        if stack[v] then return string.format("%q", "<cycle>") end
        stack[v] = true
        local parts = {}
        tinsert(parts, "{")
        local nextIndent = indent .. "  "
        local keys = {}
        for k in pairs(v) do tinsert(keys, k) end
        table.sort(keys, function(a, b)
            local ta, tb = type(a), type(b)
            if ta == tb then
                if ta == "number" then return a < b end
                return tostring(a) < tostring(b)
            end
            return ta < tb
        end)
        for _, k in ipairs(keys) do
            local val = v[k]
            local tval = type(val)
            if tval ~= "function" and tval ~= "userdata" and tval ~= "thread" then
                local keyStr
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    keyStr = k
                else
                    keyStr = "[" .. MSWA_SerializeValue(k, nextIndent, stack) .. "]"
                end
                local valStr = MSWA_SerializeValue(val, nextIndent, stack)
                tinsert(parts, ("\n%s%s = %s,"):format(nextIndent, keyStr, valStr))
            end
        end
        tinsert(parts, ("\n%s}"):format(indent))
        stack[v] = nil
        return table.concat(parts, "")
    end
    return string.format("%q", "<" .. tv .. ">")
end

-----------------------------------------------------------
-- Deep copy
-----------------------------------------------------------

function MSWA_DeepCopyTable(src, seen)
    if type(src) ~= "table" then return src end
    seen = seen or {}
    if seen[src] then return seen[src] end
    local dst = {}
    seen[src] = dst
    for k, v in pairs(src) do
        dst[MSWA_DeepCopyTable(k, seen)] = MSWA_DeepCopyTable(v, seen)
    end
    return dst
end

-----------------------------------------------------------
-- Export frame (copy box)
-----------------------------------------------------------

function MSWA_GetExportFrame()
    if MSWA._exportFrame then return MSWA._exportFrame end

    local f = CreateFrame("Frame", "MSWA_ExportFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(640, 360); f:SetPoint("CENTER"); f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("LEFT", f.TitleBg, "LEFT", 10, 0); f.title:SetText("Export")

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -38); scroll:SetPoint("BOTTOMRIGHT", -32, 46)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true); edit:SetAutoFocus(false); edit:SetFontObject(ChatFontNormal); edit:SetWidth(560)
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    edit:SetScript("OnMouseUp", function(self) self:HighlightText() end)
    scroll:SetScrollChild(edit); f.editBox = edit

    local btnClose = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnClose:SetSize(90, 22); btnClose:SetPoint("BOTTOMRIGHT", -14, 14); btnClose:SetText(CLOSE)
    btnClose:SetScript("OnClick", function() f:Hide() end)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 14, 18)
    hint:SetText("Click inside the box to select all, then Ctrl+C to copy.")

    MSWA._exportFrame = f
    return f
end

-----------------------------------------------------------
-- Import frame (paste box)
-----------------------------------------------------------

function MSWA_GetImportFrame()
    if MSWA._importFrame then return MSWA._importFrame end

    local f = CreateFrame("Frame", "MSWA_ImportFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(640, 360); f:SetPoint("CENTER"); f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("LEFT", f.TitleBg, "LEFT", 10, 0); f.title:SetText("Import")

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -38); scroll:SetPoint("BOTTOMRIGHT", -32, 46)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true); edit:SetAutoFocus(true); edit:SetFontObject(ChatFontNormal); edit:SetWidth(560)
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(edit); f.editBox = edit

    local btnImport = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnImport:SetSize(90, 22); btnImport:SetPoint("BOTTOMRIGHT", -14, 14); btnImport:SetText("Import")
    f.btnImport = btnImport

    local btnClose = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnClose:SetSize(90, 22); btnClose:SetPoint("BOTTOMRIGHT", btnImport, "TOPRIGHT", 0, 6); btnClose:SetText(CLOSE)
    btnClose:SetScript("OnClick", function() f:Hide() end)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 14, 18)
    hint:SetText("Paste a MSA2 or MSA_EXPORT string, then click Import.")

    MSWA._importFrame = f
    return f
end

-----------------------------------------------------------
-- Parse / Import helpers
-----------------------------------------------------------

local function SetTableKey(t, k, v)
    if not t then return end
    t[k] = v
    if type(k) == "number" then t[tostring(k)] = v end
end

local function ClearTableKey(t, k)
    if not t then return end
    t[k] = nil
    if type(k) == "number" then t[tostring(k)] = nil end
end

local function MSWA_ParseExportString(raw)
    if type(raw) ~= "string" then return nil, "Invalid input." end
    raw = raw:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return nil, "Empty import string." end

    local ver, body = raw:match("^MSA_EXPORT:(%d+)%s*\n(.+)$")
    if not ver then return nil, "Not a MSA_EXPORT string." end
    if tostring(ver) ~= "1" then return nil, "Unsupported export version: " .. tostring(ver) end

    local loader = loadstring or load
    if not loader then return nil, "Lua loader (loadstring) not available." end

    local chunk, err = loader(body)
    if not chunk then return nil, "Parse error: " .. tostring(err) end
    if setfenv then setfenv(chunk, {}) end

    local ok, payload = pcall(chunk)
    if not ok then return nil, "Import error: " .. tostring(payload) end
    if type(payload) ~= "table" then return nil, "Import payload is not a table." end
    return payload, nil
end

function MSWA_ImportAuraPayload(payload, forcedGroupID)
    if type(payload) ~= "table" then return end
    local key = payload.key
    if key == nil then return end

    local db = MSWA_GetDB()
    db.customNames   = db.customNames or {}
    db.auraGroups    = db.auraGroups or {}
    db.groups        = db.groups or {}
    db.groupOrder    = db.groupOrder or {}
    db.spellSettings = db.spellSettings or {}
    db.trackedSpells = db.trackedSpells or {}
    db.trackedItems  = db.trackedItems or {}

    if payload.type == "SPELL_INSTANCE" or MSWA_IsSpellInstanceKey(key) then
        local sid = payload.spellID or MSWA_KeyToSpellID(key)
        if sid then key = MSWA_NewSpellInstanceKey(sid) end
    elseif payload.type == "ITEM_INSTANCE" or MSWA_IsItemInstanceKey(key) then
        local iid = payload.itemID or MSWA_KeyToItemID(key)
        if iid then key = MSWA_NewItemInstanceKey(iid) end
    end

    local enabled = (payload.enabled ~= false)
    if MSWA_IsItemInstanceKey(key) then
        -- Item instances live in trackedSpells
        db.trackedSpells[key] = enabled
    elseif payload.type == "ITEM" or MSWA_IsItemKey(key) then
        local itemID = payload.itemID or MSWA_KeyToItemID(key)
        if itemID then db.trackedItems[itemID] = enabled end
    else
        db.trackedSpells[key] = enabled
    end

    if payload.customName and payload.customName ~= "" then
        SetTableKey(db.customNames, key, payload.customName)
    else
        ClearTableKey(db.customNames, key)
    end

    local gid = forcedGroupID or payload.groupID
    if gid then
        SetTableKey(db.auraGroups, key, gid)
    else
        ClearTableKey(db.auraGroups, key)
    end

    if payload.spellSettings and type(payload.spellSettings) == "table" then
        db.spellSettings[key] = MSWA_DeepCopyTable(payload.spellSettings)
        if type(key) == "number" then
            db.spellSettings[tostring(key)] = db.spellSettings[key]
        end
    end
end

function MSWA_ImportGroupPayload(payload)
    if type(payload) ~= "table" then return end
    if type(payload.group) ~= "table" then return end
    if type(payload.members) ~= "table" then return end

    local db = MSWA_GetDB()
    db.groups     = db.groups or {}
    db.groupOrder = db.groupOrder or {}

    local newGID = MSWA_NewGroupID()
    db.groups[newGID] = MSWA_DeepCopyTable(payload.group)
    tinsert(db.groupOrder, newGID)

    for _, auraPayload in ipairs(payload.members) do
        MSWA_ImportAuraPayload(auraPayload, newGID)
    end
end

function MSWA_ImportFromString(raw)
    if type(raw) ~= "string" then MSWA_Print("Import failed: invalid input."); return end
    raw = raw:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then MSWA_Print("Import failed: empty string."); return end

    local payload

    local tryDec = _G.MSA_TryDecodeCompactString
    if type(tryDec) == "function" then
        local decoded = tryDec(raw)
        if type(decoded) == "table" then payload = decoded end
    end

    if not payload then
        local prefix = raw:match("^%s*(MSA%d+):")
        if prefix == "MSA2" then
            MSWA_Print("Import failed: could not decode compact string (MSA2).")
            return
        end
    end

    if not payload then
        local parsed, err = MSWA_ParseExportString(raw)
        if parsed then
            payload = parsed
        elseif err then
            MSWA_Print(err)
            return
        end
    end

    if not payload or type(payload) ~= "table" then
        MSWA_Print("Import failed: could not parse input.")
        return
    end

    if payload.kind == "GROUP" or (payload.group and payload.members) then
        MSWA_ImportGroupPayload(payload)
        MSWA_Print("Imported group.")
    else
        local forcedGroupID = nil
        if payload.group and type(payload.group) == "table" then
            local db = MSWA_GetDB()
            db.groups     = db.groups or {}
            db.groupOrder = db.groupOrder or {}
            forcedGroupID = MSWA_NewGroupID()
            db.groups[forcedGroupID] = MSWA_DeepCopyTable(payload.group)
            tinsert(db.groupOrder, forcedGroupID)
        end
        MSWA_ImportAuraPayload(payload, forcedGroupID)
        MSWA_Print("Imported aura.")
    end

    MSWA_RequestFullRefresh()
end

function MSWA_OpenImportFrame()
    local f = MSWA_GetImportFrame()
    f.editBox:SetText(""); f:Show(); f.editBox:SetFocus()
    f.btnImport:SetScript("OnClick", function()
        local raw = f.editBox:GetText() or ""
        MSWA_ImportFromString(raw)
        f:Hide()
    end)
end

-----------------------------------------------------------
-- Build export strings
-----------------------------------------------------------

function MSWA_BuildAuraExportString(key)
    if key == nil then return nil end
    local db = MSWA_GetDB()
    local rawSettings = (db.spellSettings and db.spellSettings[key]) or nil
    local payload = {
        exportVersion = 1,
        key = key,
        type = (MSWA_IsItemInstanceKey(key) and "ITEM_INSTANCE") or (MSWA_IsItemKey(key) and "ITEM") or (MSWA_IsDraftKey(key) and "DRAFT") or (MSWA_IsSpellInstanceKey(key) and "SPELL_INSTANCE") or "SPELL",
        enabled = true,
        customName = (db.customNames and db.customNames[key]) or nil,
        groupID = (db.auraGroups and db.auraGroups[key]) or nil,
        spellSettings = rawSettings and MSWA_DeepCopyTable(rawSettings) or nil,
    }
    if MSWA_IsSpellInstanceKey(key) then payload.spellID = MSWA_KeyToSpellID(key) end
    if MSWA_IsItemInstanceKey(key) then
        payload.itemID = MSWA_KeyToItemID(key)
        if db.trackedSpells then payload.enabled = db.trackedSpells[key] and true or false end
    elseif MSWA_IsItemKey(key) then
        local itemID = MSWA_KeyToItemID(key)
        payload.itemID = itemID
        if itemID and db.trackedItems then payload.enabled = db.trackedItems[itemID] and true or false end
    else
        if db.trackedSpells then payload.enabled = db.trackedSpells[key] and true or false end
    end
    if payload.groupID and db.groups and db.groups[payload.groupID] then
        payload.group = MSWA_DeepCopyTable(db.groups[payload.groupID])
    end

    local enc = _G.MSA_EncodeCompactTable
    if type(enc) == "function" then
        local compact = enc(payload)
        if compact then return compact end
    end
    local body = "return " .. MSWA_SerializeValue(payload, "", {})
    return ("MSA_EXPORT:1\n%s"):format(body)
end

function MSWA_BuildGroupExportPayload(gid)
    if not gid then return nil end
    local db = MSWA_GetDB()
    if not db or not db.groups or not db.groups[gid] then return nil end

    local payload = {
        exportVersion = 1, kind = "GROUP", groupID = gid,
        group = MSWA_DeepCopyTable(db.groups[gid]),
        members = {},
    }

    local function BuildAuraPayload(db2, key, groupID)
        if key == nil then return nil end
        local p = { exportVersion = 1, kind = "AURA", key = key, groupID = groupID }
        if type(key) == "string" and MSWA_IsItemKey(key) then
            p.type = "ITEM"; p.itemID = MSWA_KeyToItemID(key)
            p.enabled = (p.itemID and db2.trackedItems and db2.trackedItems[p.itemID] == true) or false
        elseif MSWA_IsSpellInstanceKey(key) then
            p.type = "SPELL_INSTANCE"; p.spellID = MSWA_KeyToSpellID(key)
            p.enabled = (db2.trackedSpells and db2.trackedSpells[key] == true) or false
        else
            p.type = "SPELL"; p.spellID = key
            p.enabled = (db2.trackedSpells and db2.trackedSpells[key] == true) or false
        end
        if db2.customNames and db2.customNames[key] and db2.customNames[key] ~= "" then
            p.customName = db2.customNames[key]
        end
        if db2.spellSettings and type(db2.spellSettings[key]) == "table" then
            p.spellSettings = MSWA_DeepCopyTable(db2.spellSettings[key])
        end
        return p
    end

    local seen, keys = {}, {}
    if db.auraGroups then
        for key, gID in pairs(db.auraGroups) do
            if gID == gid then
                local canonical = key
                if type(key) == "string" then
                    local asNum = tonumber(key)
                    if asNum and not MSWA_IsItemKey(key) and not MSWA_IsDraftKey(key) and not MSWA_IsSpellInstanceKey(key) then
                        canonical = asNum
                    end
                end
                if not seen[tostring(canonical)] then
                    seen[tostring(canonical)] = true
                    tinsert(keys, canonical)
                end
            end
        end
    end

    local nums, items, strs = {}, {}, {}
    for _, key in ipairs(keys) do
        if type(key) == "number" then tinsert(nums, key)
        elseif type(key) == "string" and MSWA_IsItemKey(key) then tinsert(items, key)
        else tinsert(strs, key)
        end
    end
    table.sort(nums)
    table.sort(items, function(a, b) return (MSWA_KeyToItemID(a) or 0) < (MSWA_KeyToItemID(b) or 0) end)
    table.sort(strs, function(a, b) return tostring(a) < tostring(b) end)

    local ordered = {}
    for _, v in ipairs(nums) do tinsert(ordered, v) end
    for _, v in ipairs(items) do tinsert(ordered, v) end
    for _, v in ipairs(strs) do tinsert(ordered, v) end

    for _, key in ipairs(ordered) do
        local auraPayload = BuildAuraPayload(db, key, gid)
        if auraPayload then tinsert(payload.members, auraPayload) end
    end

    return payload
end

function MSWA_BuildGroupExportString(gid)
    local payload = MSWA_BuildGroupExportPayload(gid)
    if not payload then return nil end
    local enc = _G.MSA_EncodeCompactTable
    if type(enc) == "function" then
        local compact = enc(payload)
        if compact then return compact end
    end
    local body = "return " .. MSWA_SerializeValue(payload, "", {})
    return ("MSA_EXPORT:1\n%s"):format(body)
end

function MSWA_ExportAura(key)
    local s = MSWA_BuildAuraExportString(key)
    if not s then return end
    local f = MSWA_GetExportFrame()
    f.title:SetText("Export Aura")
    f.editBox:SetText(s); f.editBox:HighlightText(); f:Show()
end

function MSWA_ExportGroup(gid)
    local s = MSWA_BuildGroupExportString(gid)
    if not s then return end
    local db = MSWA_GetDB()
    local g = db.groups and db.groups[gid]
    local title = ("Export Group%s"):format((g and g.name) and (": " .. g.name) or "")
    local f = MSWA_GetExportFrame()
    f.title:SetText(title)
    f.editBox:SetText(s); f.editBox:HighlightText(); f:Show()
end
