-- ########################################################
-- MSA_Anchors.lua
-- Group anchor frames (master anchors) + helper utilities
-- Ensures groups can be anchored by any global frame name (/fstack),
-- and icons inside a group anchor to the group's frame.
-- ########################################################

local MSWA = _G.MSWA
if type(MSWA) ~= "table" then return end

local UIParent = UIParent
local pairs, type, tostring = pairs, type, tostring

-- Internal storage: gid -> Frame
MSWA._groupAnchorFrames = MSWA._groupAnchorFrames or {}

local function SanitizeGroupID(gid)
    if type(gid) == "string" then
        local n = gid:match("^GROUP:(%d+)$")
        if n then return n end
        return (gid:gsub("[^%w]", "_"))
    end
    return tostring(gid or "0")
end

-- Public: returns (and creates) a stable named anchor frame for a group.
-- Name format: MSWA_GroupAnchor_<n> (so it is easy to see in /fstack).
function MSWA_GetOrCreateGroupAnchorFrame(gid)
    local frames = MSWA._groupAnchorFrames
    local f = frames and frames[gid]
    if f then return f end

    local suffix = SanitizeGroupID(gid)
    local name = "MSWA_GroupAnchor_" .. suffix

    f = _G[name]
    if not f then
        f = CreateFrame("Frame", name, UIParent)
    end

    f:SetSize(1, 1)
    f:Hide()

    frames[gid] = f
    return f
end

-- Public: apply group anchoring (master anchor) and show the group frame.
-- group fields used:
--   anchorFrame (string global frame name or nil)
--   point / relPoint (optional, default CENTER)
--   x / y offsets
function MSWA_ApplyGroupAnchorFrame(gid, group)
    local f = MSWA_GetOrCreateGroupAnchorFrame(gid)
    if not f then return nil end

    f:ClearAllPoints()

    local anchorName = group and group.anchorFrame or nil
    local anchorFrame

    if type(MSWA_GetAnchorFrame) == "function" then
        -- Use the same resolver as per-aura anchoring (but without IsShown gating).
        anchorFrame = MSWA_GetAnchorFrame({ anchorFrame = anchorName })
    else
        anchorFrame = (anchorName and _G[anchorName]) or nil
        if not anchorFrame then anchorFrame = UIParent end
    end

    if not anchorFrame then anchorFrame = UIParent end

    local p  = (group and group.point) or "CENTER"
    local rp = (group and group.relPoint) or p
    local x  = (group and group.x) or 0
    local y  = (group and group.y) or 0

    f:SetPoint(p, anchorFrame, rp, x, y)
    f:Show()
    return f
end

-- Public: hide all group frames that are not used this update tick.
function MSWA_HideUnusedGroupAnchorFrames(usedMap)
    local frames = MSWA._groupAnchorFrames
    if not frames then return end
    for gid, f in pairs(frames) do
        if f and (not usedMap or not usedMap[gid]) then
            f:Hide()
        end
    end
end
