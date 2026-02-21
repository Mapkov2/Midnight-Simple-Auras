-- ########################################################
-- MSA_Icons.lua
-- Main frame, icon creation, Masque, font/text, anchor, drag
--
-- v5: Removed duplicate definitions of MSWA_GetFontPathFromKey,
--     MSWA_GetTextStyleForKey, MSWA_ApplyTextStyleToButton,
--     MSWA_GetStackStyleForKey, MSWA_ApplyStackStyleToButton,
--     MSWA_GetStackShowMode, MSWA_TEXT_POS_LABELS,
--     MSWA_TEXT_POINT_OFFSETS, MSWA_GetTextPosLabel.
--
--     These are now defined ONLY in MSA_SpellAPI.lua (which loads
--     before this file). The previous Icons.lua versions were
--     overwriting the SpellAPI cached versions, causing the hot
--     path to use uncached pcall-per-call font lookups.
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

    -- Default: anchor to our main frame (legacy behavior)
    if not anchorName or anchorName == "" then
        return MSWA.frame or UIParent
    end

    if anchorName == "UIParent" then
        return UIParent
    end

    -- Legacy convenience labels
    if anchorName == "CooldownManager" or anchorName == "EssentialCooldownViewer" then
        local f = _G["EssentialCooldownViewer"] or _G["CooldownManager"]
        if f then return f end
        return UIParent
    end

    local f = _G[anchorName]
    if f then
        return f
    end

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

-- Hot path: only reskin when icon count actually changes
local lastMasqueIconCount = -1

function MSWA_ReskinMasque(activeCount)
    local group = MSWA_GetMasqueGroup()
    if not group or not group.ReSkin then return end
    -- Only reskin on structural change (icon count change) or explicit force
    if activeCount == nil then
        -- Forced reskin (skin change, options, mousewheel resize)
        lastMasqueIconCount = -1
        group:ReSkin()
        return
    end
    if activeCount ~= lastMasqueIconCount then
        lastMasqueIconCount = activeCount
        group:ReSkin()
    end
end

function MSWA_FixCheckHitRect(btn)
    if not btn or not btn.Text then return end
    btn:SetHitRectInsets(0, -btn.Text:GetStringWidth() - 8, 0, 0)
end

-----------------------------------------------------------
-- Font helpers (SharedMedia)
-- v5: MSWA_GetFontPathFromKey is now ONLY defined in MSA_SpellAPI.lua
--     with permanent caching. Removed duplicate here that was
--     overwriting the cached version with uncached pcall-per-call.
-----------------------------------------------------------

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
-- v5: Text/Stack position presets, style helpers, and
--     GetStackShowMode are now ONLY in MSA_SpellAPI.lua.
--     Removed duplicates that were overwriting optimized versions.
-----------------------------------------------------------

-----------------------------------------------------------
-- Main frame + drag logic
-----------------------------------------------------------

local frame = CreateFrame("Frame", "MidnightSimpleAurasFrame", UIParent)
MSWA.frame = frame
frame:SetFrameStrata("HIGH")
frame:SetToplevel(true)

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
                local anchorFrame = MSWA_GetAnchorFrame({ anchorFrame = grp.anchorFrame })
                if not anchorFrame then anchorFrame = MSWA.frame end
                local ax, ay = anchorFrame:GetCenter()
                if not ax then ax, ay = UIParent:GetCenter() end
                settings.x = (bx - ax) - (grp.x or 0)
                settings.y = (by - ay) - (grp.y or 0)
                settings.anchorFrame = nil
            else
                local anchorFrame = MSWA_GetAnchorFrame(settings)
                local ax, ay = anchorFrame:GetCenter()
                if not ax then ax, ay = UIParent:GetCenter() end
                settings.x = bx - ax
                settings.y = by - ay
            end

            settings.width  = self:GetWidth()
            settings.height = self:GetHeight()
            db.spellSettings[key] = settings

            -- Keep stored group order in sync with manual positioning
            if gid and type(MSWA_SyncGroupMembersFromPositions) == "function" then
                MSWA_SyncGroupMembersFromPositions(gid)
            end

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
