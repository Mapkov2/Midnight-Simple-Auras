-- ########################################################
-- MSA_ProfileIO.lua
-- Compact import/export codec for MidnightSimpleAuras
--
-- Modeled after MSUF's proven compact codec.
--
-- New export format (preferred):
--   MSA2: base64(compress?(CBOR(table)))   using Blizzard C_EncodingUtil
--
-- Legacy import format supported:
--   MSA_EXPORT:1\nreturn { ... }           old Lua-table format (v0.90 and earlier)
--
-- Design goals:
--   * Export always uses Blizzard (MSA2) when C_EncodingUtil is available.
--   * Import accepts MSA2 + legacy MSA_EXPORT:1 automatically.
--   * Never fall back to loadstring() for MSA2 prefix strings.
--   * Exports are ~60-80% smaller than the old Lua table format.
-- ########################################################

local ADDON_NAME, ns = ...

do
    ---------------------------------------------------------------------------
    -- Blizzard C_EncodingUtil helpers
    ---------------------------------------------------------------------------
    local function GetEncodingUtil()
        local E = _G.C_EncodingUtil
        if type(E) ~= "table" then return nil end
        if type(E.SerializeCBOR) ~= "function" then return nil end
        if type(E.DeserializeCBOR) ~= "function" then return nil end
        if type(E.EncodeBase64) ~= "function" then return nil end
        if type(E.DecodeBase64) ~= "function" then return nil end
        return E
    end

    local function GetDeflateEnum()
        local Enum = _G.Enum
        if Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate then
            return Enum.CompressionMethod.Deflate
        end
        return nil
    end

    local function StripWS(s)
        return (s:gsub("%s+", ""))
    end

    ---------------------------------------------------------------------------
    -- Compress / Decompress wrappers
    ---------------------------------------------------------------------------
    local function TryBlizzardCompress(E, plain)
        if not E or type(plain) ~= "string" then return nil end
        if type(E.CompressString) ~= "function" then return nil end

        local method = GetDeflateEnum()
        local ok, res

        if method ~= nil then
            ok, res = pcall(E.CompressString, plain, method, 9)
            if ok and type(res) == "string" then return res end
            ok, res = pcall(E.CompressString, plain, method)
            if ok and type(res) == "string" then return res end
        end

        ok, res = pcall(E.CompressString, plain)
        if ok and type(res) == "string" then return res end
        return nil
    end

    local function TryBlizzardDecompress(E, compressed)
        if not E or type(compressed) ~= "string" then return nil end
        if type(E.DecompressString) ~= "function" then return nil end

        local method = GetDeflateEnum()
        local ok, res

        if method ~= nil then
            ok, res = pcall(E.DecompressString, compressed, method)
            if ok and type(res) == "string" then return res end
        end

        ok, res = pcall(E.DecompressString, compressed)
        if ok and type(res) == "string" then return res end
        return nil
    end

    ---------------------------------------------------------------------------
    -- Deserialize: CBOR (primary), then loadstring table literal (last resort)
    ---------------------------------------------------------------------------
    local function TryDeserialize(E, payload)
        if not E or type(payload) ~= "string" then return nil end

        -- 1) CBOR via Blizzard
        local ok, tbl = pcall(E.DeserializeCBOR, payload)
        if ok and type(tbl) == "table" then
            return tbl
        end

        -- 2) Very old legacy: Lua table literal (only if it looks like a table)
        local trimmed = payload:match("^%s*(.-)%s*$")
        if trimmed and trimmed:sub(1, 1) == "{" and trimmed:sub(-1) == "}" then
            local fn = loadstring and loadstring("return " .. trimmed)
            if fn then
                if setfenv then setfenv(fn, {}) end
                local ok2, t = pcall(fn)
                if ok2 and type(t) == "table" then
                    return t
                end
            end
        end

        return nil
    end

    ---------------------------------------------------------------------------
    -- Encode: table -> "MSA2:<base64>"
    ---------------------------------------------------------------------------
    local function MSA_EncodeCompactTable(tbl)
        local E = GetEncodingUtil()
        if not E then return nil end

        local ok1, bin = pcall(E.SerializeCBOR, tbl)
        if not ok1 or type(bin) ~= "string" then return nil end

        -- Prefer smaller output when compression is available
        local payload = TryBlizzardCompress(E, bin) or bin

        local ok2, b64 = pcall(E.EncodeBase64, payload)
        if not ok2 or type(b64) ~= "string" then return nil end

        return "MSA2:" .. b64
    end

    ---------------------------------------------------------------------------
    -- Decode: "MSA2:<base64>" -> table
    ---------------------------------------------------------------------------
    local function MSA_TryDecodeCompactString(str)
        if type(str) ~= "string" then return nil end

        local E = GetEncodingUtil()
        if not E then return nil end

        local s = str:match("^%s*(.-)%s*$")
        if not s then return nil end

        -- MSA2: base64(CBOR) [optionally compressed]
        local b64 = s:match("^MSA2:%s*(.+)$")
        if not b64 then return nil end

        b64 = StripWS(b64)

        local ok1, blob = pcall(E.DecodeBase64, b64)
        if not ok1 or type(blob) ~= "string" then return nil end

        local plain = TryBlizzardDecompress(E, blob) or blob

        local t = TryDeserialize(E, plain)
        if t then return t end

        return nil
    end

    ---------------------------------------------------------------------------
    -- Install globals (safe for any load order)
    ---------------------------------------------------------------------------
    _G.MSA_EncodeCompactTable    = _G.MSA_EncodeCompactTable    or MSA_EncodeCompactTable
    _G.MSA_TryDecodeCompactString = _G.MSA_TryDecodeCompactString or MSA_TryDecodeCompactString

    if type(ns) == "table" then
        ns.MSA_EncodeCompactTable    = ns.MSA_EncodeCompactTable    or MSA_EncodeCompactTable
        ns.MSA_TryDecodeCompactString = ns.MSA_TryDecodeCompactString or MSA_TryDecodeCompactString
    end
end
