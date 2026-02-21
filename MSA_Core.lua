-- ########################################################
-- MSA_Core.lua
-- Namespace, config constants, shared upvalues
--
-- v2: Tooltip OnUpdate handler optimized – checks flags
--     first before any function calls (zero overhead when
--     already processed).
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

-----------------------------------------------------------
-- Tooltip ID Info (Spell ID / Icon ID / Item ID)
-- v2: Optimized – early return via boolean flags avoids
--     all function calls once the tooltip is already
--     annotated. OnUpdate still fires but does zero work.
-----------------------------------------------------------

do
    local function ResetFlags(tooltip)
        tooltip._mswaHasSpell = false
        tooltip._mswaHasItem  = false
    end

    local function AddSpellInfo(tooltip)
        if tooltip._mswaHasSpell then return end
        local db = MSWA_GetDB and MSWA_GetDB()
        if not db then return end
        if not db.showSpellID and not db.showIconID then return end

        local ok, _, spellID = pcall(tooltip.GetSpell, tooltip)
        if not ok or not spellID then return end

        local ok2, icon = pcall(function()
            return C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID)
        end)
        if not ok2 then icon = nil end

        if db.showSpellID then
            if icon then
                tooltip:AddLine("|T" .. icon .. ":0|t Spell ID: |cffffffff" .. spellID .. "|r", 1, 0.82, 0)
            else
                tooltip:AddLine("Spell ID: |cffffffff" .. spellID .. "|r", 1, 0.82, 0)
            end
        end

        if icon and db.showIconID then
            tooltip:AddLine("|T" .. icon .. ":0|t Icon ID: |cffffffff" .. icon .. "|r", 1, 0.82, 0)
        end

        tooltip._mswaHasSpell = true
        tooltip:Show()
    end

    local function AddItemInfo(tooltip)
        if tooltip._mswaHasItem then return end
        local db = MSWA_GetDB and MSWA_GetDB()
        if not db then return end
        if not db.showSpellID and not db.showIconID then return end

        local ok, _, link = pcall(tooltip.GetItem, tooltip)
        if not ok or not link then return end

        local itemID = link:match("item:(%d+)")
        if not itemID then return end

        local ok2, icon = pcall(function() return select(10, GetItemInfo(itemID)) end)
        if not ok2 then icon = nil end

        if db.showSpellID then
            if icon then
                tooltip:AddLine("|T" .. icon .. ":0|t Item ID: |cffffffff" .. itemID .. "|r", 1, 0.82, 0)
            else
                tooltip:AddLine("Item ID: |cffffffff" .. itemID .. "|r", 1, 0.82, 0)
            end
        end

        if icon and db.showIconID then
            tooltip:AddLine("|T" .. icon .. ":0|t Icon ID: |cffffffff" .. icon .. "|r", 1, 0.82, 0)
        end

        tooltip._mswaHasItem = true
        tooltip:Show()
    end

    local function OnTooltipUpdate(tooltip)
        -- v2: Fast exit when both already processed (zero overhead)
        if tooltip._mswaHasSpell and tooltip._mswaHasItem then return end
        if not tooltip._mswaHasSpell then AddSpellInfo(tooltip) end
        if not tooltip._mswaHasItem  then AddItemInfo(tooltip) end
    end

    local hookFrame = CreateFrame("Frame")
    hookFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    hookFrame:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")

        local function HookTooltip(tt)
            if not tt or not tt.HookScript then return end
            tt:HookScript("OnShow", ResetFlags)
            tt:HookScript("OnUpdate", OnTooltipUpdate)
            tt:HookScript("OnTooltipCleared", ResetFlags)
        end

        HookTooltip(GameTooltip)
        HookTooltip(ItemRefTooltip)
    end)
end
