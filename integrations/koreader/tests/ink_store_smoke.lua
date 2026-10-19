-- An existing handwritten annotation must work without a TOC, map or source extraction.
local path = '/sdcard/Kalamos/BookData/book-0123456789abcdef0123456789abcdef/ink-annotations.json'
local existing = { schema = 'kalamos.ink-annotations/v1', entries = { { id = 'old-stroke', strokes = { { 1, 2 } } } } }
local stored, decoded, writes = { [path] = 'existing-ink' }, { ['existing-ink'] = existing }, {}
local reads = {}
package.preload.rapidjson = function() return {
    array = function(value) return value end,
    decode = function(raw) return assert(decoded[raw]) end,
    encode = function(value) decoded.saved = value; return 'saved' end,
} end
package.preload.util = function() return {
    partialMD5 = function() return '0123456789abcdef0123456789abcdef' end,
    makePath = function() end,
} end
package.preload['libs/libkoreader-lfs'] = function() return {
    attributes = function() return 'directory' end,
} end
io.open = function(name, mode)
    if mode == 'rb' then
        reads[#reads + 1] = name
        if not stored[name] then return nil end
        return { read = function() return stored[name] end, close = function() end }
    end
    assert(mode == 'wb' and name == path .. '.tmp', 'only annotations may be written')
    return { write = function(_, value) stored[name] = value; writes[#writes+1] = name; return true end,
        flush = function() return true end, close = function() return true end }
end
os.rename = function(from, to) stored[to] = stored[from]; stored[from] = nil; return true end
local store = require('inkstore')
local ui = { document = { file = '/books/example.epub',
    getToc = function() error('handwriting must not extract a TOC') end,
    getTextFromXPointers = function() error('handwriting must not extract prose') end } }
local book = assert(store.current(ui))
assert(book.bookId == 'book-0123456789abcdef0123456789abcdef')
assert(store.annotations(book.bookId).entries[1].id == 'old-stroke')
assert(store.appendInk(book.bookId, { id = 'new-stroke' }))
local saved = store.annotations(book.bookId)
assert(#saved.entries == 2 and saved.entries[1].id == 'old-stroke' and saved.entries[2].id == 'new-stroke')
assert(saved.schema == 'kalamos.ink-annotations/v1' and saved.bookId == book.bookId)
assert(#writes == 1)
for _, read in ipairs(reads) do assert(read == path, 'must not read generated map/evidence files') end
print('KOReader saved-ink compatibility smoke passed')
