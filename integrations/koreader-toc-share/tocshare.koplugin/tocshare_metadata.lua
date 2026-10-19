-- A small, optional metadata envelope. The shared text remains ordinary EXTRA_TEXT.
local Metadata = { EXTRA = "org.koreader.extra.EXCERPT_METADATA" }
local function label(value)
    value = tostring(value or "")
    if #value <= 300 then return value end
    local last = 300
    while last > 0 do
        local byte = value:byte(last + 1)
        if not byte or byte < 128 or byte >= 192 then break end
        last = last - 1
    end
    return value:sub(1, last)
end
function Metadata.build(ui, title)
    local props = ui.doc_props or {}
    local metadata = { schema = "org.koreader.excerpt/v1", title = label(title),
        bookTitle = label(props.display_title or props.title),
        authors = label(props.authors) }
    -- Thumbnail is optional. Failure to decode a cover must never prevent text sharing.
    local cover, scaled, filename
    local ok, encoded = pcall(function()
        if not ui.document.getCoverPageImage then return end
        cover = ui.document:getCoverPageImage()
        if not cover then return end
        local width, height = cover:getWidth(), cover:getHeight()
        local factor = math.min(1, 160 / width, 220 / height)
        scaled = cover:scale(math.max(1, math.floor(width * factor)), math.max(1, math.floor(height * factor)))
        -- Android has no writable /tmp. Use KOReader's own cache for the delayed system preview.
        local cache = require("datastorage"):getDataDir() .. "/cache"
        require("util").makePath(cache)
        -- The system sheet reads after this call returns. Keep owned previews for 24 hours.
        local lfs = require("libs/libkoreader-lfs")
        for name in lfs.dir(cache) do
            if name:match("^tocshare%-cover%-%d+%.jpg$") then
                local attributes = lfs.attributes(cache .. "/" .. name)
                if attributes and attributes.mode == "file" and os.time() - attributes.modification > 86400 then
                    os.remove(cache .. "/" .. name)
                end
            end
        end
        filename = cache .. "/tocshare-cover-" .. tostring(math.random(1, 2147483647)) .. ".jpg"
        assert(scaled:writeToFile(filename, "jpg", 75))
        local file = assert(io.open(filename, "rb"))
        local data = file:read(90001); file:close()
        if #data > 90000 then return end
        return require("mime").b64(data)
    end)
    if filename and (not ok or not encoded) then os.remove(filename); filename = nil end
    if scaled and scaled ~= cover then pcall(scaled.free, scaled) end
    if cover then pcall(cover.free, cover) end
    if ok and encoded then metadata.thumbnailBase64 = encoded end
    return metadata, filename
end
return Metadata
