-- ########################################################
-- MSA_Icons.lua
-- Main frame, icon creation, Masque, font/text, anchor, drag
-- ########################################################

local ADDON_NAME = MSWA.ADDON_NAME
local Masque     = MSWA.Masque
local UIParent   = UIParent
local pcall, type, select, tostring, tonumber = pcall, type, select, tostring, tonumber
local tinsert    = table.insert
local ipairs     = ipairs
local LibStub    = LibStub

-----------------------------------------------------------
-- Anchor helpers (MSUF-style CooldownManager logic)
-----------------------------------------------------------

function MSWA_GetAnchorFrame(settings)
    settings = settings or {}
    local anchorName = settings.anchorFrame

    if not anchorName or anchorName == "" then
        return MSWA.frame
    end

    if anchorName == "CooldownManager" or anchorName == "EssentialCooldownViewer" then
        local ecv = _G["EssentialCooldownViewer"]
        if ecv and ecv:IsShown() then return ecv end
        return UIParent
    end

    local f = _G[anchorName]
    if f and f:IsShown() then return f end

    return UIParent
end

-----------------------------------------------------------
-- Masque helpers
-----------------------------------------------------------

function MSWA_GetMasqueGroup()
    if not Masque then return nil end
    if not MSWA.MasqueGroup then
        MSWA.MasqueGroup = Masque:Group("MidnightSimpleAuras", "Cooldown Icons")
    end
    return MSWA.MasqueGroup
end

function MSWA_ReskinMasque()
    local group = MSWA_GetMasqueGroup()
    if group and group.ReSkin then group:ReSkin() end
end

function MSWA_FixCheckHitRect(btn)
    if not btn or not btn.Text then return end
    btn:SetHitRectInsets(0, -btn.Text:GetStringWidth() - 8, 0, 0)
end

-----------------------------------------------------------
-- Font helpers (SharedMedia)
-----------------------------------------------------------

function MSWA_GetFontPathFromKey(fontKey)
    local defaultPath = GameFontNormal and GameFontNormal.GetFont and select(1, GameFontNormal:GetFont()) or nil
    if fontKey and fontKey ~= "DEFAULT" then
        if LibStub then
            local ok, LSM = pcall(LibStub, "LibSharedMedia-3.0")
            if ok and LSM and LSM.Fetch then
                local ok2, path = pcall(LSM.Fetch, LSM, "font", fontKey)
                if ok2 and path then return path end
            end
        end
    end
    return defaultPath
end

function MSWA_GetUIFontPath()
    local db = MSWA_GetDB()
    local key = (db and db.fontKey) or "DEFAULT"
    return MSWA_GetFontPathFromKey(key)
end

function MSWA_RebuildFontChoices()
    local fonts = {}
    local LSM = MSWA.LSM
    if not LSM and LibStub then LSM = LibStub("LibSharedMedia-3.0", true); MSWA.LSM = LSM end

    local defaultPath = GameFontNormal:GetFont()
    tinsert(fonts, { key = "DEFAULT",  label = "Default (Blizzard)", path = defaultPath })
    tinsert(fonts, { key = "FRIZQT",   label = "Friz Quadrata",      path = "Fonts\\FRIZQT__.TTF" })
    tinsert(fonts, { key = "ARIALN",   label = "Arial Narrow",       path = "Fonts\\ARIALN.TTF" })
    tinsert(fonts, { key = "MORPHEUS", label = "Morpheus",           path = "Fonts\\MORPHEUS.TTF" })
    tinsert(fonts, { key = "SKURRI",   label = "Skurri",             path = "Fonts\\SKURRI.TTF" })

    if LSM then
        local list = LSM:List("font")
        for _, name in ipairs(list) do
            local ok, path = pcall(LSM.Fetch, LSM, "font", name)
            if ok and path then
                tinsert(fonts, { key = name, label = name, path = path })
            end
        end
    end

    MSWA.fontChoices = fonts
end

MSWA.uiFont      = nil
MSWA.uiFontSmall = nil

function MSWA_ApplyUIFont()
    -- UI font customization intentionally disabled (per-aura only)
    return
end

-----------------------------------------------------------
-- Text position presets
-----------------------------------------------------------

MSWA_TEXT_POS_LABELS = {
    TOPLEFT = "Top Left",
    TOPRIGHT = "Top Right",
    BOTTOMLEFT = "Bottom Left",
    BOTTOMRIGHT = "Bottom Right",
    CENTER = "Center",
}

MSWA_TEXT_POINT_OFFSETS = {
    TOPLEFT = { 1, -1 },
    TOPRIGHT = { -1, -1 },
    BOTTOMLEFT = { 1, 1 },
    BOTTOMRIGHT = { -1, 1 },
    CENTER = { 0, 0 },
}

function MSWA_GetTextPosLabel(point)
    if not point then return MSWA_TEXT_POS_LABELS.BOTTOMRIGHT end
    return MSWA_TEXT_POS_LABELS[point] or tostring(point)
end

function MSWA_GetTextStyleForKey(key)
    local db = MSWA_GetDB()
    local s = nil
    if key ~= nil then s = select(1, MSWA_GetSpellSettings(db, key)) end

    local size = (s and s.textFontSize) or db.textFontSize or 12
    size = tonumber(size) or 12
    if size < 6 then size = 6 end
    if size > 48 then size = 48 end

    local tc = (s and s.textColor) or db.textColor or { r = 1, g = 1, b = 1 }
    local r  = tonumber(tc.r) or 1
    local g  = tonumber(tc.g) or 1
    local b  = tonumber(tc.b) or 1

    local point = (s and s.textPoint) or db.textPoint or "BOTTOMRIGHT"
    point = tostring(point or "BOTTOMRIGHT")
    local off = MSWA_TEXT_POINT_OFFSETS[point] or MSWA_TEXT_POINT_OFFSETS.BOTTOMRIGHT

    return size, r, g, b, point, off[1], off[2]
end

function MSWA_ApplyTextStyleToButton(btn, key)
    if not btn or not btn.count then return end

    local db = MSWA_GetDB()
    local s = (key ~= nil) and select(1, MSWA_GetSpellSettings(db, key)) or nil
    local fontKey = (s and s.textFontKey) or "DEFAULT"
    local path = MSWA_GetFontPathFromKey(fontKey)
    local size, r, g, b, point, ox, oy = MSWA_GetTextStyleForKey(key)

    if path and btn.count.SetFont then
        btn.count:SetFont(path, size, "OUTLINE")
    end
    if btn.count.SetTextColor then
        btn.count:SetTextColor(r, g, b, 1)
    end
    if btn.count.ClearAllPoints and btn.count.SetPoint then
        btn.count:ClearAllPoints()
        btn.count:SetPoint(point or "BOTTOMRIGHT", btn, point or "BOTTOMRIGHT", ox or -1, oy or 1)
    end
end

-----------------------------------------------------------
-- Stack text style helpers
-----------------------------------------------------------

function MSWA_GetStackStyleForKey(key)
    local db = MSWA_GetDB()
    local s = nil
    if key ~= nil then s = select(1, MSWA_GetSpellSettings(db, key)) end

    local size = (s and s.stackFontSize) or 12
    size = tonumber(size) or 12
    if size < 6 then size = 6 end
    if size > 48 then size = 48 end

    local tc = (s and s.stackColor) or { r = 1, g = 1, b = 1 }
    local r  = tonumber(tc.r) or 1
    local g  = tonumber(tc.g) or 1
    local b  = tonumber(tc.b) or 1

    local point = (s and s.stackPoint) or "BOTTOMRIGHT"
    point = tostring(point or "BOTTOMRIGHT")

    local ox = (s and s.stackOffsetX) or 0
    local oy = (s and s.stackOffsetY) or 0
    ox = tonumber(ox) or 0
    oy = tonumber(oy) or 0

    return size, r, g, b, point, ox, oy
end

function MSWA_ApplyStackStyleToButton(btn, key)
    if not btn or not btn.stackText then return end

    local db = MSWA_GetDB()
    local s = (key ~= nil) and select(1, MSWA_GetSpellSettings(db, key)) or nil
    local fontKey = (s and s.stackFontKey) or "DEFAULT"
    local path = MSWA_GetFontPathFromKey(fontKey)
    local size, r, g, b, point, ox, oy = MSWA_GetStackStyleForKey(key)

    if path and btn.stackText.SetFont then
        btn.stackText:SetFont(path, size, "OUTLINE")
    end
    if btn.stackText.SetTextColor then
        btn.stackText:SetTextColor(r, g, b, 1)
    end
    if btn.stackText.ClearAllPoints and btn.stackText.SetPoint then
        btn.stackText:ClearAllPoints()
        local baseOff = MSWA_TEXT_POINT_OFFSETS[point] or MSWA_TEXT_POINT_OFFSETS.BOTTOMRIGHT
        btn.stackText:SetPoint(point or "BOTTOMRIGHT", btn, point or "BOTTOMRIGHT", (baseOff[1] or -1) + ox, (baseOff[2] or 1) + oy)
    end
end

function MSWA_GetStackShowMode(key)
    if not key then return "auto" end
    local db = MSWA_GetDB()
    local s = select(1, MSWA_GetSpellSettings(db, key))
    if s and s.stackShowMode then return s.stackShowMode end
    return "auto"
end

-----------------------------------------------------------
-- Main frame + drag logic
-----------------------------------------------------------

local frame = CreateFrame("Frame", "MidnightSimpleAurasFrame", UIParent)
MSWA.frame = frame

frame:SetSize(1, MSWA.ICON_SIZE)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetHitRectInsets(-10, -10, -10, -10)

function MSWA_UpdatePositionFromDB()
    local db = MSWA_GetDB()
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", db.position.x, db.position.y)
    frame.infoText:SetShown(not db.locked)
end

local function MSWA_StartDragging()
    local db = MSWA_GetDB()
    if not db.locked then frame:StartMoving() end
end

local function MSWA_StopDragging()
    frame:StopMovingOrSizing()
    local db = MSWA_GetDB()
    local x, y   = frame:GetCenter()
    local ux, uy = UIParent:GetCenter()
    db.position.x = x - ux
    db.position.y = y - uy
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", db.position.x, db.position.y)
end

frame:SetScript("OnDragStart", MSWA_StartDragging)
frame:SetScript("OnDragStop",  MSWA_StopDragging)

frame.infoText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
frame.infoText:SetPoint("BOTTOM", frame, "TOP", 0, 2)
frame.infoText:SetText("MidnightSimpleAuras (drag with left mouse)")

-----------------------------------------------------------
-- Group dragging
-----------------------------------------------------------

local function MSWA_GetCursorUI()
    if not GetCursorPosition then return nil, nil end
    local ok, cx, cy = pcall(GetCursorPosition)
    if not ok or not cx or not cy then return nil, nil end
    local scale = UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale() or 1
    if not scale or scale == 0 then scale = 1 end
    return cx / scale, cy / scale
end

MSWA._groupDrag = nil
MSWA._groupDragFrame = nil

function MSWA_StartGroupDrag(gid)
    local opt = MSWA.optionsFrame
    if not (opt and opt.IsShown and opt:IsShown()) then return end

    local db = MSWA_GetDB()
    local g = db.groups and db.groups[gid]
    if not g then return end

    local hasMember = false
    if db.auraGroups then
        for _, gg in pairs(db.auraGroups) do
            if gg == gid then hasMember = true; break end
        end
    end
    if not hasMember then return end

    local mx, my = MSWA_GetCursorUI()
    if not mx then return end

    MSWA._groupDrag = {
        gid = gid,
        startMouseX = mx, startMouseY = my,
        startGX = g.x or 0, startGY = g.y or 0,
    }

    if not MSWA._groupDragFrame then
        local t = CreateFrame("Frame", nil, UIParent)
        t:Hide()
        t._accum = 0
        t:SetScript("OnUpdate", function(self, elapsed)
            if not MSWA._groupDrag then self:Hide(); return end
            self._accum = (self._accum or 0) + (elapsed or 0)
            if self._accum < 0.02 then return end
            self._accum = 0

            local cx, cy = MSWA_GetCursorUI()
            if not cx then return end

            local st = MSWA._groupDrag
            local db2 = MSWA_GetDB()
            local g2 = db2.groups and db2.groups[st.gid]
            if not g2 then MSWA._groupDrag = nil; self:Hide(); return end

            g2.x = (st.startGX or 0) + (cx - st.startMouseX)
            g2.y = (st.startGY or 0) + (cy - st.startMouseY)

            if MSWA.UpdateSpells then pcall(MSWA.UpdateSpells) end

            local f = MSWA.optionsFrame
            if f and f.IsShown and f:IsShown() and MSWA.selectedGroupID == st.gid and f.groupPanel and f.groupPanel:IsShown() then
                if f.groupXEdit and f.groupXEdit.HasFocus and (not f.groupXEdit:HasFocus()) then
                    f.groupXEdit:SetText(("%d"):format(g2.x or 0))
                end
                if f.groupYEdit and f.groupYEdit.HasFocus and (not f.groupYEdit:HasFocus()) then
                    f.groupYEdit:SetText(("%d"):format(g2.y or 0))
                end
            end
        end)
        MSWA._groupDragFrame = t
    end

    MSWA._groupDragFrame:Show()
end

function MSWA_StopGroupDrag()
    local st = MSWA._groupDrag
    if not st then return end

    local db = MSWA_GetDB()
    local g = db.groups and db.groups[st.gid]
    if g then
        g.x = math.floor((g.x or 0) + 0.5)
        g.y = math.floor((g.y or 0) + 0.5)
    end

    MSWA._groupDrag = nil
    if MSWA._groupDragFrame then MSWA._groupDragFrame:Hide() end

    if MSWA.UpdateSpells then pcall(MSWA.UpdateSpells) end

    local f = MSWA.optionsFrame
    if f and f.IsShown and f:IsShown() and MSWA.selectedGroupID == st.gid and f.groupPanel and f.groupPanel:IsShown() and g then
        if f.groupXEdit and f.groupXEdit.HasFocus and (not f.groupXEdit:HasFocus()) then
            f.groupXEdit:SetText(("%d"):format(g.x or 0))
        end
        if f.groupYEdit and f.groupYEdit.HasFocus and (not f.groupYEdit:HasFocus()) then
            f.groupYEdit:SetText(("%d"):format(g.y or 0))
        end
    end
end

-----------------------------------------------------------
-- Options list drag & drop
-----------------------------------------------------------

function MSWA_FindMSWARowFromFocus(focus)
    while focus do
        if focus.isMSWARow then return focus end
        focus = focus:GetParent()
    end
    return nil
end

function MSWA_EnsureDragOverlay()
    if MSWA.dragOverlay then return MSWA.dragOverlay end

    local overlay = CreateFrame("Frame", "MSWA_DragOverlay", UIParent)
    overlay:SetAllPoints(UIParent)
    overlay:SetFrameStrata("TOOLTIP")
    overlay:EnableMouse(false)
    overlay:Hide()

    local iconFrame = CreateFrame("Frame", nil, overlay)
    iconFrame:SetSize(26, 26)
    iconFrame.icon = iconFrame:CreateTexture(nil, "OVERLAY")
    iconFrame.icon:SetAllPoints(true)
    iconFrame:Hide()
    overlay._iconFrame = iconFrame

    overlay:SetScript("OnUpdate", function(self)
        if not MSWA._dragKey then return end
        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale() or 1
        x = x / scale; y = y / scale
        self._iconFrame:ClearAllPoints()
        self._iconFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
    end)

    MSWA.dragOverlay = overlay
    return overlay
end

function MSWA_BeginListDrag(key)
    if not key then return end
    local overlay = MSWA_EnsureDragOverlay()
    MSWA._dragKey = key
    MSWA._isDraggingList = true
    local icon = MSWA_GetIconForKey(key)
    overlay._iconFrame.icon:SetTexture(icon)
    overlay._iconFrame:Show()
    overlay:Show()
end

function MSWA_GetMouseFocusFrame()
    if type(GetMouseFoci) == "function" then
        local foci = GetMouseFoci()
        if type(foci) == "table" then
            for i = 1, #foci do
                local f = foci[i]
                if f and (not MSWA.dragOverlay or (f ~= MSWA.dragOverlay and f ~= MSWA.dragOverlay._iconFrame)) then
                    return f
                end
            end
        end
    end
    if type(GetMouseFocus) == "function" then return GetMouseFocus() end
    return nil
end

function MSWA_EndListDrag()
    local overlay = MSWA.dragOverlay
    local key = MSWA._dragKey

    MSWA._dragKey = nil
    MSWA._isDraggingList = false

    if overlay then
        overlay:Hide()
        if overlay._iconFrame then overlay._iconFrame:Hide() end
    end
    if not key then return end

    pcall(function()
        local focus = MSWA_GetMouseFocusFrame()
        local row = MSWA_FindMSWARowFromFocus(focus)
        if row and row.entryType == "GROUP" and row.groupID then
            MSWA_SetAuraGroup(key, row.groupID)
        elseif row and row.entryType == "UNGROUPED" then
            MSWA_SetAuraGroup(key, nil)
        end
    end)

    local f = MSWA and MSWA.optionsFrame
    if f and f.UpdateAuraList then pcall(function() f:UpdateAuraList() end) end

    local updater = (MSWA and MSWA.UpdateSpells) or _G.MSWA_UpdateSpells
    if type(updater) == "function" then pcall(updater) end
end

-----------------------------------------------------------
-- Icon creation
-----------------------------------------------------------

MSWA.icons = {}

local function MSWA_CreateIcon(i)
    local btn = CreateFrame("Button", ADDON_NAME.."Icon"..i, frame)
    btn:SetSize(MSWA.ICON_SIZE, MSWA.ICON_SIZE)
    btn:SetPoint("CENTER", frame, "CENTER", (i - 1) * (MSWA.ICON_SIZE + MSWA.ICON_SPACE), 0)

    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:EnableMouseWheel(true)
    btn:RegisterForDrag("LeftButton")

    btn.border = btn:CreateTexture(nil, "BACKGROUND")
    btn.border:SetPoint("TOPLEFT", -1, 1)
    btn.border:SetPoint("BOTTOMRIGHT", 1, -1)
    if Masque then
        btn.border:SetColorTexture(0, 0, 0, 0)
    else
        btn.border:SetColorTexture(0, 0, 0, 1)
    end

    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetAllPoints(true)
    btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    btn.cooldown = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
    btn.cooldown:SetAllPoints(true)
    if btn.cooldown.SetHideCountdownNumbers then
        btn.cooldown:SetHideCountdownNumbers(false)
    end

    btn.count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.count:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
    btn.count:SetText("")
    btn.count:Hide()

    btn.stackText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.stackText:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
    btn.stackText:SetText("")
    btn.stackText:Hide()

    btn.spellID = nil

    local group = MSWA_GetMasqueGroup()
    if group then
        group:AddButton(btn, {
            Icon     = btn.icon,
            Cooldown = btn.cooldown,
            Count    = btn.count,
        })
    end

    -- Drag logic
    btn:SetScript("OnDragStart", function(self)
        local opt = MSWA.optionsFrame
        if opt and opt:IsShown() then
            local key = self.spellID
            if key ~= nil and MSWA.selectedGroupID then
                local gid = MSWA_GetAuraGroup(key)
                if gid and gid == MSWA.selectedGroupID then
                    self._mswaGroupDragging = true
                    MSWA_StartGroupDrag(gid)
                    return
                end
            end
            if MSWA.selectedSpellID and self.spellID == MSWA.selectedSpellID then
                self:StartMoving()
                return
            end
            if MSWA.previewMode and self.spellID then
                MSWA.selectedSpellID = self.spellID
                MSWA.selectedGroupID = nil
                self:StartMoving()
                MSWA_RefreshOptionsList()
                return
            end
        end
        MSWA_StartDragging()
    end)

    btn:SetScript("OnDragStop", function(self)
        if self._mswaGroupDragging then
            self._mswaGroupDragging = nil
            MSWA_StopGroupDrag()
            return
        end
        local opt = MSWA.optionsFrame
        if opt and opt:IsShown() and MSWA.selectedSpellID and self.spellID == MSWA.selectedSpellID then
            self:StopMovingOrSizing()
            local db = MSWA_GetDB()
            db.spellSettings = db.spellSettings or {}
            local key = self.spellID
            local settings = db.spellSettings[key] or {}
            local bx, by = self:GetCenter()

            local gid = MSWA_GetAuraGroup(key)
            local grp = gid and db.groups and db.groups[gid] or nil
            if grp then
                local ax, ay = MSWA.frame:GetCenter()
                settings.x = (bx - ax) - (grp.x or 0)
                settings.y = (by - ay) - (grp.y or 0)
                settings.anchorFrame = nil
            else
                local anchorFrame = MSWA_GetAnchorFrame(settings)
                local ax, ay = anchorFrame:GetCenter()
                settings.x = bx - ax
                settings.y = by - ay
            end

            settings.width  = self:GetWidth()
            settings.height = self:GetHeight()
            db.spellSettings[key] = settings

            if MSWA.optionsFrame and MSWA.optionsFrame:IsShown() and MSWA.selectedSpellID == key then
                MSWA.optionsFrame.detailX:SetText(("%d"):format(settings.x or 0))
                MSWA.optionsFrame.detailY:SetText(("%d"):format(settings.y or 0))
                MSWA.optionsFrame.detailA:SetText(settings.anchorFrame or "")
            end
        else
            MSWA_StopDragging()
        end
    end)

    -- Mousewheel: resize icon
    btn:SetScript("OnMouseWheel", function(self, delta)
        local opt = MSWA.optionsFrame
        if not (opt and opt:IsShown()) then return end
        if not self.spellID then return end

        if MSWA.previewMode and self.spellID ~= MSWA.selectedSpellID then
            MSWA.selectedSpellID = self.spellID
            MSWA.selectedGroupID = nil
            MSWA_RefreshOptionsList()
        end

        if not (MSWA.selectedSpellID and self.spellID == MSWA.selectedSpellID) then return end
        local db = MSWA_GetDB()
        db.spellSettings = db.spellSettings or {}
        local key = self.spellID
        local settings = db.spellSettings[key] or {}

        local w = settings.width  or MSWA.ICON_SIZE
        local h = settings.height or MSWA.ICON_SIZE
        local step = 2

        w = w + delta * step
        h = h + delta * step
        if w < 16 then w = 16 end
        if h < 16 then h = 16 end
        if w > 128 then w = 128 end
        if h > 128 then h = 128 end

        self:SetSize(w, h)
        settings.width  = w
        settings.height = h
        db.spellSettings[key] = settings

        if MSWA.optionsFrame and MSWA.optionsFrame:IsShown() and MSWA.selectedSpellID == key then
            if MSWA.optionsFrame.detailW then MSWA.optionsFrame.detailW:SetText(("%d"):format(w)) end
            if MSWA.optionsFrame.detailH then MSWA.optionsFrame.detailH:SetText(("%d"):format(h)) end
        end
        MSWA_ReskinMasque()
    end)

    MSWA.icons[i] = btn
    return btn
end

for i = 1, MSWA.MAX_ICONS do
    MSWA_CreateIcon(i)
end
