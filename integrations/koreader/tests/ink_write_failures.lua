-- Exercise real store control flow with failing filesystem stages, preserving the old sidecar.
local stage, saved, temporary, opened, renamed
package.preload.rapidjson = function() return {
    array = function(value) return value end,
    encode = function()
        if stage == 'encode' then error('encoding failed') end
        return 'new ink'
    end,
} end
package.preload.util = function() return {makePath = function() end} end
package.preload['libs/libkoreader-lfs'] = function() return {
    attributes = function() return 'directory' end,
} end
io.open = function(_, mode)
    assert(mode == 'wb'); opened = true
    if stage == 'open' then return nil, 'open failed' end
    return {
        write = function()
            temporary = 'partial'
            if stage == 'write' then return nil, 'write failed' end
            temporary = 'new ink'; return true
        end,
        flush = function()
            if stage == 'flush' then return nil, 'flush failed' end
            return true
        end,
        close = function()
            if stage == 'close' then return nil, 'close failed' end
            return true
        end,
    }
end
os.remove = function() temporary = nil; return true end
os.rename = function()
    renamed = true
    if stage == 'rename' then return nil, 'rename failed' end
    saved, temporary = temporary, nil; return true
end
local store = require('inkstore')
for _, failure in ipairs({'encode', 'open', 'write', 'flush', 'close', 'rename', 'success'}) do
    stage, saved, temporary, opened, renamed = failure, 'old ink', nil, false, false
    local ok, err = store.writeAnnotations('book-test', {entries = {}})
    if failure == 'success' then
        assert(ok and saved == 'new ink' and renamed)
    else
        assert(not ok and err, failure .. ' must report failure')
        assert(saved == 'old ink' and not temporary, failure .. ' must preserve saved ink')
        if failure == 'encode' then assert(not opened) end
        if failure ~= 'rename' then assert(not renamed) end
    end
end
print('Passed 7 annotation persistence scenarios')
