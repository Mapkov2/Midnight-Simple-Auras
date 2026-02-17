-- ########################################################
-- MSA_Core.lua
-- Namespace, config constants, shared upvalues
-- ########################################################

local ADDON_NAME, MSWA = ...

-- Use the addon private table as our namespace (keeps ns == MSWA across files)
if type(MSWA) ~= "table" then
    MSWA = _G.MSWA
    if type(MSWA) ~= "table" then
        MSWA = {}
    end
end

_G.MSWA = MSWA
-----------------------------------------------------------
-- Local upvalues for performance (shared via MSWA table)
-----------------------------------------------------------

local pairs, ipairs   = pairs, ipairs
local tinsert, tsort  = table.insert, table.sort
local tonumber        = tonumber
local tostring        = tostring
local print           = print
local UIParent        = UIParent
local wipe            = wipe or table.wipe

local LSM             = LibStub and LibStub("LibSharedMedia-3.0", true)
local Masque          = LibStub and LibStub("Masque", true)
local LCG             = LibStub and LibStub("LibCustomGlow-1.0", true)

local GetItemCooldown          = GetItemCooldown
local GetItemIcon              = GetItemIcon
local GetItemInfo              = GetItemInfo
local GetItemCount             = GetItemCount

-----------------------------------------------------------
-- Stash frequently needed refs on the namespace
-----------------------------------------------------------

MSWA.ADDON_NAME = ADDON_NAME
MSWA.LSM        = LSM
MSWA.Masque     = Masque
MSWA.LCG        = LCG

-----------------------------------------------------------
-- Basic config
-----------------------------------------------------------

MSWA.ICON_SIZE  = 32
MSWA.ICON_SPACE = 4
MSWA.MAX_ICONS  = 24

MSWA.selectedSpellID = nil
MSWA.selectedGroupID = nil
MSWA.fontChoices     = {}
MSWA.activeIconCount = 0
MSWA.previewMode     = false

-- Auto Buff runtime state (non-saved, per spell key)
MSWA._autoBuff = {}

-----------------------------------------------------------
-- Print helper
-----------------------------------------------------------

function MSWA_Print(msg)
    print("|cff00ff00[MSA]|r " .. msg)
end
