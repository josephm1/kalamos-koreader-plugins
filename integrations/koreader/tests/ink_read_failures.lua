-- Reads must distinguish a new book from inaccessible, truncated or unsupported saved ink.
local source, decoded, open_code, read_error, write_count
package.preload.rapidjson = function() return {
    array = function(value) return value end,
    decode = function()
        if decoded == 'throw' then error('malformed JSON') end
        return decoded
    end,
    encode = function() return 'saved ink' end,
} end
package.preload.util = function() return {makePath = function() end} end
package.preload['libs/libkoreader-lfs'] = function() return {
    attributes = function() return 'directory' end,
} end
io.open = function(_, mode)
    if mode == 'rb' then
        if open_code then return nil, 'cannot open', open_code end
        return {read = function() return source, read_error end, close = function() return true end}
    end
    write_count = write_count + 1
    return {write = function() return true end, flush = function() return true end,
        close = function() return true end}
end
os.rename = function() return true end
local store = require('inkstore')
local cases = {
    {'JSON exception', 'throw'},
    {'decoder returns nil', nil},
    {'JSON scalar', false},
    {'missing entry list', {}},
    {'wrong entry list type', {entries = 'damaged'}},
    {'non-array entry list', {entries = {wrong = {}}}},
    {'sparse entry list', {entries = {[2] = {}}}},
    {'invalid entry', {entries = {false}}},
    {'invalid anchor', {entries = {{anchor = 42}}}},
    {'invalid strokes', {entries = {{strokes = false}}}},
    {'invalid kind', {entries = {{kind = {}}}}},
    {'future schema', {schema = 'kalamos.ink-annotations/v99', entries = {}}},
    {'wrong book', {bookId = 'another-book', entries = {}}},
    {'permission denied', {}, 13},
    {'read error', {}, nil, true},
}
for _, case in ipairs(cases) do
    local name = case[1]
    source, decoded, open_code, read_error, write_count = 'original bytes', case[2], case[3], nil, 0
    if case[4] then source, read_error = nil, 'read failed' end
    local original = source
    local document, err = store.annotations('book-test')
    assert(not document and err, name .. ': must report the read failure')
    assert(not store.appendInk('book-test', {}), name .. ': append must fail')
    assert(not store.writeAnnotations('book-test', {entries = {}}), name .. ': writes must stay blocked')
    assert(write_count == 0 and source == original, name .. ': preserve original bytes')
    -- A successfully restored file explicitly loaded by the reader permits writing again.
    source, decoded, open_code = 'restored bytes', {entries = {}}, nil
    assert(store.annotations('book-test'))
    assert(store.writeAnnotations('book-test', {entries = {}}))
    assert(write_count == 1)
end
open_code = 2
local fresh = assert(store.annotations('book-new'))
assert(#fresh.entries == 0 and fresh.schema == 'kalamos.ink-annotations/v1')
assert(store.appendInk('book-new', {kind = 'full-page', strokes = {}}))
print('Passed 16 saved-ink read/recovery scenarios')

local legacy = store.root
for _, invalid in ipairs({false, true, 42, "relative/path", "/tmp/bad\npath", "/tmp/bad\0path"}) do
    assert(not store.configure(invalid) and store.root == legacy)
end
assert(store.configure("/tmp/explicit-reader-ink///") and store.directory('book-test') == '/tmp/explicit-reader-ink/book-test')
assert(store.configure(nil) and store.root == legacy)
print('Saved-ink explicit storage configuration checks passed; legacy default retained')
