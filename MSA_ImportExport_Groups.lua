-- MidnightSimpleAuras/MSA_ImportExport_Groups.lua
-- Group export/import that includes full group settings + aura instances + per-instance settings.
-- Secret-safe: touches only SavedVariables tables; does not read restricted/secret gameplay values.

local ADDON, MSA = ...

local LibDeflate = LibStub and LibStub("LibDeflate", true)
local AceSerializer = LibStub and LibStub("AceSerializer-3.0", true)

local EXPORT_PREFIX_GROUP = "MSA:GROUP:"

-- ------------------------------------------------------------
-- Utils
-- ------------------------------------------------------------

local function _isPlainKey(k)
  local tk = type(k)
  return (tk == "string" or tk == "number")
end

local function DeepCopyStripPrivate(v, seen)
  local tv = type(v)
  if tv ~= "table" then return v end
  if seen and seen[v] then return seen[v] end

  seen = seen or {}
  local out = {}
  seen[v] = out

  for k, val in pairs(v) do
    if _isPlainKey(k) then
      -- Strip runtime/private keys by convention
      if not (type(k) == "string" and k:sub(1, 1) == "_") then
        local tval = type(val)
        if tval ~= "function" and tval ~= "userdata" and tval ~= "thread" then
          out[k] = DeepCopyStripPrivate(val, seen)
        end
      end
    end
  end

  return out
end

local function _arrayCopy(arr)
  if type(arr) ~= "table" then return {} end
  local out, n = {}, 0
  for i = 1, #arr do
    local v = arr[i]
    if v ~= nil then
      n = n + 1
      out[n] = v
    end
  end
  return out
end

local function _detectNumericKeyedSet(t)
  if type(t) ~= "table" then return false end
  for k, _ in pairs(t) do
    if type(k) == "number" then return true end
    break
  end
  return false
end

local function _ensureTable(root, key)
  local t = root[key]
  if type(t) ~= "table" then
    t = {}
    root[key] = t
  end
  return t
end

local function _allocId(db, counterKey)
  local n = tonumber(db[counterKey]) or 0
  n = n + 1
  db[counterKey] = n
  return n
end

local function _serializePayload(payload)
  if not (LibDeflate and AceSerializer) then
    return nil, "LibDeflate oder AceSerializer-3.0 fehlt."
  end
  local ok, serialized = AceSerializer:Serialize(payload)
  if not ok then
    return nil, "AceSerializer Serialize failed."
  end
  local compressed = LibDeflate:CompressDeflate(serialized)
  local encoded = LibDeflate:EncodeForPrint(compressed)
  return EXPORT_PREFIX_GROUP .. encoded
end

local function _deserializePayload(str)
  if type(str) ~= "string" then return nil, "Kein String." end
  if str:sub(1, #EXPORT_PREFIX_GROUP) ~= EXPORT_PREFIX_GROUP then
    return nil, "Kein MSA Group Export String."
  end
  if not (LibDeflate and AceSerializer) then
    return nil, "LibDeflate oder AceSerializer-3.0 fehlt."
  end

  local body = str:sub(#EXPORT_PREFIX_GROUP + 1)
  local decoded = LibDeflate:DecodeForPrint(body)
  if not decoded then return nil, "Decode failed." end
  local decompressed = LibDeflate:DecompressDeflate(decoded)
  if not decompressed then return nil, "Decompress failed." end

  local ok, payload = AceSerializer:Deserialize(decompressed)
  if not ok then return nil, "Deserialize failed." end
  return payload
end

-- ------------------------------------------------------------
-- API
-- ------------------------------------------------------------

-- Exports ONE group including all its aura/instance members + per-instance settings.
-- Returns exportString or nil,error
local function ExportGroupFull(db, groupId)
  if type(db) ~= "table" then return nil, "db nil" end
  if groupId == nil then return nil, "groupId nil" end

  local groups = db.groups
  if type(groups) ~= "table" or type(groups[groupId]) ~= "table" then
    return nil, "Gruppe nicht gefunden."
  end

  local groupMembers = (type(db.groupMembers) == "table") and db.groupMembers[groupId] or nil
  local members = _arrayCopy(groupMembers)

  -- Collect per-member settings
  local spellSettings = type(db.spellSettings) == "table" and db.spellSettings or {}
  local customNames  = type(db.customNames) == "table" and db.customNames or {}

  local instances = {}
  local names = {}

  for i = 1, #members do
    local instId = members[i]
    if instId ~= nil then
      local s = spellSettings[instId]
      if s == nil and type(instId) == "number" then
        s = spellSettings[tostring(instId)]
      end
      if type(s) == "table" then
        instances[instId] = DeepCopyStripPrivate(s)
      else
        instances[instId] = {}
      end

      local cn = customNames[instId]
      if cn == nil and type(instId) == "number" then
        cn = customNames[tostring(instId)]
      end
      if type(cn) == "string" then
        names[instId] = cn
      end
    end
  end

  -- Tracking subsets so imported group actually spawns/updates
  local trackedSpells = type(db.trackedSpells) == "table" and db.trackedSpells or {}
  local trackedItems  = type(db.trackedItems)  == "table" and db.trackedItems  or {}
  local trackedSpellsNumericKeyed = _detectNumericKeyedSet(trackedSpells)
  local trackedItemsNumericKeyed  = _detectNumericKeyedSet(trackedItems)

  local trackedSpellsSubset = {}
  local trackedItemsSubset  = {}

  for instId, instSettings in pairs(instances) do
    if trackedSpellsNumericKeyed then
      if trackedSpells[instId] then trackedSpellsSubset[instId] = true end
    else
      -- best effort: add by spellID if present
      local sid = instSettings and (instSettings.spellID or instSettings.spellId)
      if type(sid) == "number" and trackedSpells[sid] then trackedSpellsSubset[sid] = true end
    end

    if trackedItemsNumericKeyed then
      if trackedItems[instId] then trackedItemsSubset[instId] = true end
    else
      local iid = instSettings and (instSettings.itemID or instSettings.itemId)
      if type(iid) == "number" and trackedItems[iid] then trackedItemsSubset[iid] = true end
    end
  end

  local payload = {
    kind = "group",
    schema = 1,
    addon = "MidnightSimpleAuras",
    exportedAt = time and time() or 0,

    group = {
      oldId = groupId,
      settings = DeepCopyStripPrivate(groups[groupId]),
      members = members,
    },

    instances = instances,
    customNames = names,

    tracked = {
      spellsNumericKeyed = trackedSpellsNumericKeyed,
      itemsNumericKeyed = trackedItemsNumericKeyed,
      spells = trackedSpellsSubset,
      items  = trackedItemsSubset,
    },
  }

  return _serializePayload(payload)
end

-- Imports ONE group export string, creates a NEW group + NEW instance ids,
-- appends to groupOrder, returns newGroupId or nil,error.
local function ImportGroupFull(db, exportString)
  if type(db) ~= "table" then return nil, "db nil" end

  local payload, err = _deserializePayload(exportString)
  if not payload then return nil, err end
  if type(payload) ~= "table" or payload.kind ~= "group" then
    return nil, "Payload ist kein Group Export."
  end

  local g = payload.group
  if type(g) ~= "table" or type(g.settings) ~= "table" or type(g.members) ~= "table" then
    return nil, "Group payload beschädigt."
  end

  local groups = _ensureTable(db, "groups")
  local groupMembers = _ensureTable(db, "groupMembers")
  local spellSettings = _ensureTable(db, "spellSettings")
  local customNames  = _ensureTable(db, "customNames")
  local trackedSpells = _ensureTable(db, "trackedSpells")
  local trackedItems  = _ensureTable(db, "trackedItems")
  local groupOrder    = _ensureTable(db, "groupOrder")

  -- Allocate new group id
  local newGroupId = _allocId(db, "_groupCounter")
  groups[newGroupId] = DeepCopyStripPrivate(g.settings)

  -- Remap members to new instance IDs
  local newMembers = {}

  local instances = type(payload.instances) == "table" and payload.instances or {}
  local names = type(payload.customNames) == "table" and payload.customNames or {}

  for i = 1, #g.members do
    local oldInst = g.members[i]
    if oldInst ~= nil then
      local newInst = _allocId(db, "_instanceCounter")
      newMembers[#newMembers + 1] = newInst

      local s = instances[oldInst]
      if s == nil and type(oldInst) == "number" then
        s = instances[tostring(oldInst)]
      end

      if type(s) == "table" then
        local copied = DeepCopyStripPrivate(s)
        -- Optional: keep id fields consistent if present in settings
        if type(copied.instanceID) == "number" then copied.instanceID = newInst end
        if type(copied.instanceId) == "number" then copied.instanceId = newInst end
        spellSettings[newInst] = copied
      else
        spellSettings[newInst] = {}
      end

      local cn = names[oldInst]
      if cn == nil and type(oldInst) == "number" then
        cn = names[tostring(oldInst)]
      end
      if type(cn) == "string" then
        customNames[newInst] = cn
      end

      -- Ensure tracking exists so these instances actually run
      local track = payload.tracked
      if type(track) == "table" then
        if track.spellsNumericKeyed then
          local flagged = track.spells and (track.spells[oldInst] or (type(oldInst)=="number" and track.spells[tostring(oldInst)]))
          if flagged then
            trackedSpells[newInst] = true
          end
        else
          local ss = spellSettings[newInst]
          local sid = ss and (ss.spellID or ss.spellId)
          if type(sid) == "number" then
            trackedSpells[sid] = true
          end
        end

        if track.itemsNumericKeyed then
          local flagged = track.items and (track.items[oldInst] or (type(oldInst)=="number" and track.items[tostring(oldInst)]))
          if flagged then
            trackedItems[newInst] = true
          end
        else
          local ss = spellSettings[newInst]
          local iid = ss and (ss.itemID or ss.itemId)
          if type(iid) == "number" then
            trackedItems[iid] = true
          end
        end
      else
        local ss = spellSettings[newInst]
        local sid = ss and (ss.spellID or ss.spellId)
        local iid = ss and (ss.itemID or ss.itemId)
        if type(sid) == "number" then trackedSpells[sid] = true end
        if type(iid) == "number" then trackedItems[iid] = true end
      end
    end
  end

  groupMembers[newGroupId] = newMembers
  groupOrder[#groupOrder + 1] = newGroupId

  return newGroupId
end

-- Export as globals AND on addon table (best compatibility)
_G.MSA_ExportGroupFull = ExportGroupFull
_G.MSA_ImportGroupFull = ImportGroupFull

if type(MSA) == "table" then
  MSA.ExportGroupFull = ExportGroupFull
  MSA.ImportGroupFull = ImportGroupFull
end

