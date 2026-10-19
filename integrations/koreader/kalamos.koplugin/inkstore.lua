-- Handwriting-only persistence. Keep book IDs and annotation paths compatible with saved ink.
local rapidjson = require("rapidjson")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local LEGACY_ROOT = "/sdcard/Kalamos/BookData"
local InkStore = { root = LEGACY_ROOT }

-- Explicit advanced setting only: no automatic move, merge or change to existing book IDs.
function InkStore.configure(root)
    if root == nil then root = LEGACY_ROOT end
    if type(root) ~= "string" or root:sub(1, 1) ~= "/" or root:find("%c") then
        return nil, "Handwriting storage must be an absolute directory path without control characters"
    end
    InkStore.root = root:gsub("/+$", "")
    if InkStore.root == "" then InkStore.root = "/" end
    return true
end

local function array(values)
    -- Decoded objects share RapidJSON's object metatable. array(decodedTable)
    -- mutates that metatable and can turn unrelated objects into JSON arrays.
    local out = {}
    for i, value in ipairs(values or {}) do out[i] = value end
    return rapidjson.array(out)
end
local function write_atomic(path, value)
    -- Encode before opening a temporary file; a serialization failure must leave saved ink intact.
    local encoded, payload = pcall(rapidjson.encode, value, { pretty = true })
    if not encoded or type(payload) ~= "string" then
        return nil, "Could not encode ink annotations: " .. tostring(payload)
    end
    local tmp = path .. ".tmp"
    local file, err = io.open(tmp, "wb")
    if not file then return nil, err end
    local wrote, write_err = file:write(payload)
    local flushed, flush_err
    if wrote then flushed, flush_err = file:flush() end
    local closed, close_err = file:close()
    -- Disk-full errors may surface only at flush/close. Never rename a partial sidecar over saved ink.
    if not wrote or not flushed or not closed then
        os.remove(tmp)
        return nil, write_err or flush_err or close_err or "Could not write ink annotations"
    end
    local ok, rename_err = os.rename(tmp, path)
    if not ok then os.remove(tmp); return nil, rename_err end
    return true
end
-- A failed read must never be mistaken for a new notebook. Keep the original sidecar in place
-- and block writes until a subsequent explicit load successfully reads a repaired/restored file.
local blocked = {}
local function read_json(path, fallback)
    local file, err, code = io.open(path, "rb")
    if not file then
        if code == 2 then return fallback end -- ENOENT on Android/Linux: first use, not corruption.
        return nil, err or "Could not open saved ink annotations"
    end
    local raw, read_err = file:read("*a")
    file:close()
    if type(raw) ~= "string" then return nil, read_err or "Could not read saved ink annotations" end
    local ok, value = pcall(rapidjson.decode, raw)
    if not ok or type(value) ~= "table" then return nil, "Saved ink annotations contain invalid JSON" end
    return value
end
local function validate(document, book_id)
    if document.schema ~= nil and document.schema ~= "kalamos.ink-annotations/v1" then
        return nil, "Unsupported saved ink annotation schema"
    end
    if document.bookId ~= nil and document.bookId ~= book_id then
        return nil, "Saved ink annotations belong to another book"
    end
    if type(document.entries) ~= "table" then return nil, "Saved ink annotations have no entry list" end
    local count = 0
    for key, entry in pairs(document.entries) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(entry) ~= "table"
            or (entry.anchor ~= nil and type(entry.anchor) ~= "table")
            or (entry.strokes ~= nil and type(entry.strokes) ~= "table")
            or (entry.kind ~= nil and type(entry.kind) ~= "string") then
            return nil, "Saved ink annotations contain invalid entries"
        end
        count = count + 1
    end
    for index = 1, count do
        if document.entries[index] == nil then return nil, "Saved ink annotation entries are incomplete" end
    end
    return document
end
local function ensure(path)
    local ok, err = pcall(util.makePath, path)
    return ok and lfs.attributes(path, "mode") == "directory", err
end

function InkStore.bookId(path)
    local digest = util.partialMD5(path)
    if not digest then digest = require("ffi/sha2").md5(path) end
    return "book-" .. digest:sub(1, 32)
end

function InkStore.directory(book_id)
    return InkStore.root .. "/" .. book_id
end

function InkStore.current(ui)
    local path = ui and ui.document and ui.document.file
    if not path or path == "" then return nil, "Open an EPUB or PDF first" end
    return { path = path, bookId = InkStore.bookId(path) }
end

function InkStore.annotations(book_id)
    local fallback = { schema = "kalamos.ink-annotations/v1", bookId = book_id, entries = array({}) }
    local path = InkStore.directory(book_id) .. "/ink-annotations.json"
    local document, err = read_json(path, fallback)
    if document then document, err = validate(document, book_id) end
    blocked[path] = err
    return document, err
end

function InkStore.writeAnnotations(book_id, document)
    local dir = InkStore.directory(book_id)
    if blocked[dir .. "/ink-annotations.json"] then return nil, blocked[dir .. "/ink-annotations.json"] end
    local ok, err = ensure(dir); if not ok then return nil, err end
    document.schema = "kalamos.ink-annotations/v1"
    document.bookId = book_id
    document.entries = document.entries or array({})
    return write_atomic(dir .. "/ink-annotations.json", document)
end

function InkStore.appendInk(book_id, entry)
    local document, err = InkStore.annotations(book_id)
    if not document then return nil, err end
    document.entries = document.entries or array({})
    document.entries[#document.entries + 1] = entry
    return InkStore.writeAnnotations(book_id, document)
end

-- Separate versioned layout document: an older handwriting-only writer cannot erase gaps.
local function denseArray(value)
    if type(value) ~= "table" then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
    end
    for i = 1, count do if value[i] == nil then return false end end
    return true
end
local function finite(value) return type(value) == "number" and value == value and math.abs(value) < math.huge end
local function validateSpaces(document, book_id)
    if document.schema ~= "kalamos.writing-spaces/v1" or document.bookId ~= book_id
        or type(document.spaces) ~= "table" then return nil, "Unsupported writing-space document" end
    local ids, anchors, count = {}, {}, 0
    for key, space in pairs(document.spaces) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(space) ~= "table"
            or type(space.id) ~= "string" or #space.id > 128 or ids[space.id]
            or type(space.anchor) ~= "string" or #space.anchor > 4096 or anchors[space.anchor]
            or type(space.height) ~= "number" or space.height ~= space.height
            or space.height < 48 or space.height > 1200
            or type(space.collapsed) ~= "boolean" or not denseArray(space.strokes)
            or (space.basisWidth ~= nil and (not finite(space.basisWidth) or space.basisWidth <= 0 or space.basisWidth > 16000))
            or (space.basisHeight ~= nil and (not finite(space.basisHeight) or space.basisHeight <= 0 or space.basisHeight > 16000))
            or ((space.basisWidth == nil) ~= (space.basisHeight == nil)) then
            return nil, "Invalid or duplicate writing space"
        end
        ids[space.id], anchors[space.anchor], count = true, true, count + 1
        for _, stroke in ipairs(space.strokes) do
            if type(stroke) ~= "table" or not denseArray(stroke.points)
                or (stroke.width ~= nil and (not finite(stroke.width) or stroke.width <= 0 or stroke.width > 200))
                or (stroke.opacity ~= nil and (not finite(stroke.opacity) or stroke.opacity < 0 or stroke.opacity > 1)) then
                return nil, "Invalid space ink"
            end
            for _, point in ipairs(stroke.points) do
                if type(point) ~= "table" or type(point[1]) ~= "number" or type(point[2]) ~= "number"
                    or point[1] ~= point[1] or point[2] ~= point[2]
                    or math.abs(point[1]) > 2 or math.abs(point[2]) > 2 then return nil, "Invalid space coordinates" end
            end
        end
    end
    for index = 1, count do if not document.spaces[index] then return nil, "Incomplete space list" end end
    return document
end

function InkStore.spaces(book_id)
    local path = InkStore.directory(book_id) .. "/writing-spaces.json"
    local document, err = read_json(path, {schema = "kalamos.writing-spaces/v1", bookId = book_id, spaces = array({})})
    if document then document, err = validateSpaces(document, book_id) end
    blocked[path] = err
    return document, err
end

function InkStore.writeSpaces(book_id, document)
    local dir = InkStore.directory(book_id)
    if blocked[dir .. "/writing-spaces.json"] then return nil, blocked[dir .. "/writing-spaces.json"] end
    local valid, err = validateSpaces(document, book_id)
    if not valid then return nil, err end
    local ok; ok, err = ensure(dir); if not ok then return nil, err end
    local encoded = {}
    for key, value in pairs(document) do encoded[key] = value end
    encoded.spaces = array(document.spaces)
    return write_atomic(dir .. "/writing-spaces.json", encoded)
end

return InkStore
