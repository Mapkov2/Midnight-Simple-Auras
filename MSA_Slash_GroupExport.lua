-- MidnightSimpleAuras/MSA_Slash_GroupExport.lua
-- Minimal UI + slash commands for full Group export/import (includes members + aura settings).

local ADDON, MSA = ...

local function _print(msg)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage("|cff00d1ffMSA|r " .. tostring(msg))
  end
end

local function _getDB()
  -- Most addons store as MSA_DB or in MSA.db or similar. Try common patterns.
  if type(_G.MSA_DB) == "table" then return _G.MSA_DB end
  if type(MSA) == "table" then
    if type(MSA.db) == "table" then return MSA.db end
    if type(MSA.DB) == "table" then return MSA.DB end
    if type(MSA.saved) == "table" then return MSA.saved end
  end
  return nil
end

-- Simple export/import dialog (only created on demand)
local Dialog
local function EnsureDialog()
  if Dialog then return Dialog end

  local f = CreateFrame("Frame", "MSA_GroupExportDialog", UIParent, "BackdropTemplate")
  f:SetSize(760, 420)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

  f:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  f:SetBackdropColor(0, 0, 0, 0.92)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("MSA Group Export/Import")
  f._title = title

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  local help = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  help:SetText("/msag export <groupId>  |  /msag import (öffnet Paste-Fenster)")

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 14, -72)
  scroll:SetPoint("BOTTOMRIGHT", -34, 56)

  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetFontObject(ChatFontNormal)
  edit:SetWidth(680)
  edit:SetScript("OnEscapePressed", function() f:Hide() end)
  edit:SetScript("OnTextChanged", function(self)
    scroll:UpdateScrollChildRect()
  end)

  scroll:SetScrollChild(edit)
  f._scroll = scroll
  f._edit = edit

  local btnCopy = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  btnCopy:SetSize(160, 26)
  btnCopy:SetPoint("BOTTOMLEFT", 14, 18)
  btnCopy:SetText("Select All")
  btnCopy:SetScript("OnClick", function()
    edit:HighlightText(0, -1)
    edit:SetFocus()
  end)

  local btnImport = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  btnImport:SetSize(160, 26)
  btnImport:SetPoint("BOTTOMLEFT", btnCopy, "BOTTOMRIGHT", 10, 0)
  btnImport:SetText("Import Now")
  btnImport:SetScript("OnClick", function()
    local db = _getDB()
    if not db then _print("DB nicht gefunden (MSA_DB).") return end
    if not _G.MSA_ImportGroupFull then _print("MSA_ImportGroupFull fehlt (Datei nicht geladen?).") return end

    local txt = edit:GetText() or ""
    if txt == "" then _print("Kein Import-String.") return end

    local newId, err = _G.MSA_ImportGroupFull(db, txt)
    if not newId then
      _print("Import failed: " .. tostring(err))
      return
    end

    _print("Import OK. New GroupId: " .. tostring(newId))

    -- Best-effort refresh hooks (won't error if absent)
    if type(MSA) == "table" then
      if type(MSA.RebuildAll) == "function" then pcall(MSA.RebuildAll) end
      if type(MSA.ForceFullRefresh) == "function" then pcall(MSA.ForceFullRefresh) end
      if type(MSA.ApplyAll) == "function" then pcall(MSA.ApplyAll) end
    end
  end)

  local tip = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  tip:SetPoint("BOTTOMRIGHT", -14, 18)
  tip:SetJustifyH("RIGHT")
  tip:SetText("Hinweis: Kein Chat-Spam. String hier kopieren/einfügen.")

  f:Hide()
  Dialog = f
  return f
end

local function ShowDialog(titleText, bodyText, importMode)
  local f = EnsureDialog()
  f._title:SetText(titleText or "MSA Group Export/Import")
  f._edit:SetText(bodyText or "")
  f._edit:HighlightText(0, -1)
  f._edit:SetFocus()

  -- If importMode, keep button visible; otherwise still visible but can be ignored.
  f:Show()
end

-- Slash command
SLASH_MSAG1 = "/msag"
SlashCmdList.MSAG = function(msg)
  msg = msg or ""
  local cmd, rest = msg:match("^%s*(%S+)%s*(.-)%s*$")

  if not cmd or cmd == "" or cmd == "help" then
    _print("Commands: /msag export <groupId> | /msag import")
    return
  end

  if cmd == "export" then
    local gid = tonumber(rest)
    if not gid then
      _print("Usage: /msag export <groupId>")
      return
    end

    local db = _getDB()
    if not db then _print("DB nicht gefunden (MSA_DB).") return end
    if not _G.MSA_ExportGroupFull then _print("MSA_ExportGroupFull fehlt (Datei nicht geladen?).") return end

    local s, err = _G.MSA_ExportGroupFull(db, gid)
    if not s then
      _print("Export failed: " .. tostring(err))
      return
    end

    ShowDialog("MSA Export Group " .. gid, s, false)
    _print("Export OK. String im Fenster selektieren & kopieren.")
    return
  end

  if cmd == "import" then
    ShowDialog("MSA Import Group", "", true)
    _print("Paste den Export-String ins Fenster und klick 'Import Now'.")
    return
  end

  _print("Unknown command. /msag help")
end

