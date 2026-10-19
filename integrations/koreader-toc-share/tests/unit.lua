package.preload.logger=function() return {warn=function() end} end
local plugin_root = assert(arg[1], 'plugin path required')
package.path = plugin_root .. '/?.lua;' .. package.path
local Range = require('tocshare_range')
local tests = 0
local function test(name, action)
    action()
    tests = tests + 1
    print('ok ' .. tests .. ' - ' .. name)
end
local function row(title, level, offset, page)
    return {title = title, depth = level, xpointer = 'x' .. offset, page = page or 1}
end
local function document(text, last_page_start)
    local calls = {}
    local doc = { file = 'example.epub', calls = calls }
    local function offset(xp)
        local value = type(xp) == 'string' and tonumber(xp:match('^x(%d+)$'))
        if value and value <= #text then return value end
    end
    function doc:compareXPointers(a, b)
        a, b = offset(a), offset(b)
        if not a or not b then return nil end
        return b == a and 0 or b > a and 1 or -1
    end
    function doc:getTextFromXPointers(a, b, draw)
        calls[#calls + 1] = { a, b, draw }
        return text:sub(assert(offset(a)) + 1, assert(offset(b)))
    end
    function doc:getPageCount(internal) assert(internal == true); return 2 end
    function doc:getPageXPointer(page, internal)
        assert(page == 2 and internal == true)
        return 'x' .. (last_page_start or math.max(0, #text - 3))
    end
    function doc:getNextVisibleChar(xp)
        local value = assert(offset(xp))
        if value < #text then return 'x' .. (value + 1) end
    end
    return doc
end
local text = 'One\nAA\nBB\nTwo\nCC\nThree\n最後！'
local toc = {row('One', 1, 0),row('AA', 2, 4),row('BB', 2, 7),row('Two', 1, 10),row('CC', 2, 14),row('Three', 1, 17)}
test('chapter includes subsections and excludes the next chapter on the same page', function()
    local doc = document(text)
    assert(Range.extract(doc, toc, toc[1]) == 'One\nAA\nBB\n')
    assert(doc.calls[1][1] == 'x0' and doc.calls[1][2] == 'x10' and doc.calls[1][3] == false)
end)
test('a subsection stops before its sibling', function()
    assert(Range.extract(document(text), toc, toc[2]) == 'AA\n')
end)
test('last subsection stops before the following ancestor-level entry', function()
    assert(Range.extract(document(text), toc, toc[3]) == 'BB\n')
end)
test('copied filtered menu entries use the full TOC, not visible row numbers', function()
    local item = row('Two', 1, 10); item.index = 1
    assert(Range.extract(document(text), toc, item) == 'Two\nCC\n')
end)
test('final chapter includes its final page, Unicode and punctuation', function()
    assert(Range.extract(document(text), toc, toc[6]) == 'Three\n最後！')
end)
test('one-entry EPUB shares its full text', function()
    local single = {row('Whole', 1, 0)}
    assert(Range.extract(document('Only one!'), single, single[1]) == 'Only one!')
end)
test('section beginning on the final page still reaches the exact end', function()
    assert(Range.extract(document(text, 10), toc, toc[6]) == 'Three\n最後！')
end)
test('missing next boundary never expands to the whole book', function()
    local doc = document(text)
    local items = {row('One',1,0),{title='Two',depth=1}}
    assert(Range.extract(doc, items, items[1]) == nil and #doc.calls == 0)
end)
test('reversed and equal boundaries are refused before the engine can sort them', function()
    for _, finish in ipairs({0, 4}) do
        local doc = document(text)
        local items = {row('A',1,4),row('B',1,finish)}
        assert(Range.extract(doc, items, items[1]) == nil and #doc.calls == 0)
    end
end)
test('malformed hierarchy and unknown entries are refused', function()
    local items = {row('A',1,0),row('B',0,10)}
    assert(Range.extract(document(text), items, items[1]) == nil)
    assert(Range.extract(document(text), toc, row('Unknown',1,0)) == nil)
    assert(Range.extract(document(text), toc, nil) == nil)
end)
test('ambiguous copied entries cannot select a different chapter', function()
    local items = {row('A',1,0),row('A',1,0)}
    assert(Range.extract(document(text), items, row('A',1,0)) == nil)
end)
test('broken and non-progressing EOF traversal refuses to share', function()
    local doc = document(text)
    doc.getNextVisibleChar = function(_, xp) return xp end
    assert(Range.extract(doc, toc, toc[6]) == nil)
    doc.getPageXPointer = function() return '' end
    assert(Range.extract(doc, toc, toc[6]) == nil)
end)
test('EOF traversal has a bound and never returns a partial section', function()
    local limit = Range.MAX_END_STEPS
    Range.MAX_END_STEPS = 1
    assert(Range.extract(document(text, 18), toc, toc[6]) == nil)
    Range.MAX_END_STEPS = limit
end)
test('large sections and whitespace-only sections are refused without truncation', function()
    local limit=Range.MAX_SHARE_BYTES;Range.MAX_SHARE_BYTES=1024
    local value = string.rep('a',Range.MAX_SHARE_BYTES + 1) .. 'B'
    local items = {row('A',1,0),row('B',1,#value-1)}
    local result, err = Range.extract(document(value), items, items[1])
    assert(result == nil and err:find('Nothing was truncated',1,true))
    local spaces = {row('A',1,0),row('B',1,3)}
    assert(Range.extract(document('   B'), spaces, spaces[1]) == nil)
    Range.MAX_SHARE_BYTES=limit
end)
test('engine exceptions are contained', function()
    local doc = document(text)
    doc.getTextFromXPointers = function() error('broken document') end
    assert(Range.extract(doc, toc, toc[1]) == nil)
end)

-- Reader/menu adapter harness. Do not mock the range implementation.
local queued, notices, shared, events, dialogs = {}, {}, {}, {}, {}
local device = {supported=true, touch=true}
function device:canShareText() return self.supported end
function device:isTouchDevice() return self.touch end
function device:doShareText(value, reason, title, mime)
    shared[#shared+1] = {value,reason,title,mime}; events[#events+1] = 'share'
end
package.preload.device = function() return device end
package.preload['ui/widget/buttondialog'] = function() return {new=function(_, value) return value end} end
package.preload['ui/widget/infomessage'] = function() return {new=function(_, value) return value end} end
package.preload['ui/uimanager'] = function() return {
    show=function(_, value)
        if value.buttons then dialogs[#dialogs+1] = value else notices[#notices+1] = value.text end
    end,
    close=function() end,
    nextTick=function(_, callback) queued[#queued+1] = callback end,
} end
package.preload['ui/widget/container/widgetcontainer'] = function() return {extend=function(_,value) return value end} end
package.preload.gettext = function() return function(value) return value end end
local Plugin = require('main')
local function reader(file)
    local ui = {document=document(text),rolling={},handmade={}}
    ui.document.file = file or 'example.epub'
    ui.toc = {toc=toc}
    function ui.toc:onShowToc()
        self.toc_menu = {onMenuHold=function() events[#events+1]='original'; return 'original' end,
            close_callback=function() events[#events+1]='close' end}
        return 'shown'
    end
    local plugin = setmetatable({ui=ui},{__index=Plugin})
    return plugin, ui
end
local function flush()
    local pending = queued; queued = {}
    for _, callback in ipairs(pending) do callback() end
end
local function share_hold(menu, item)
    local result = menu:onMenuHold(item)
    if dialogs[#dialogs] then dialogs[#dialogs].buttons[1][1].callback() end
    return result
end
test('EPUB hold closes TOC before the next-tick Android share, with exact text', function()
    local plugin, ui = reader('EXAMPLE.EPUB')
    plugin:init(); assert(ui.toc:onShowToc() == 'shown')
    local before = #shared
    assert(share_hold(ui.toc.toc_menu, toc[4]) == true)
    assert(#shared == before and events[#events] == 'close')
    flush()
    assert(#shared == before+1 and events[#events] == 'share')
    local last = shared[#shared]
    assert(last[1] == 'Two\nCC\n' and last[2] == 'Share excerpt' and last[3] == 'Two' and last[4] == 'text/plain')
    plugin:onCloseDocument()
end)
test('repeated opening and reader-ready do not stack hooks; taps stay untouched', function()
    local plugin, ui = reader()
    local original = ui.toc.onShowToc
    plugin:init(); local wrapper = ui.toc.onShowToc; plugin:onReaderReady()
    assert(ui.toc.onShowToc == wrapper)
    ui.toc:onShowToc(); local old = ui.toc.toc_menu
    ui.toc:onShowToc(); assert(old.onMenuHold ~= plugin.hold_wrapper)
    plugin:onCloseDocument(); assert(ui.toc.onShowToc == original)
end)
test('PDF and devices without sharing keep standard TOC behavior', function()
    for _, name in ipairs({'book.pdf','book.txt'}) do
        local plugin,ui = reader(name); local original=ui.toc.onShowToc
        plugin:init(); assert(ui.toc.onShowToc==original)
    end
    device.supported=false
    local plugin,ui=reader(); local original=ui.toc.onShowToc
    plugin:init(); assert(ui.toc.onShowToc==original)
    device.supported=true
end)
test('older device APIs without canShareText retain normal TOC behavior', function()
    local capability = device.canShareText
    device.canShareText = nil
    local plugin, ui = reader()
    local original = ui.toc.onShowToc
    plugin:init()
    assert(ui.toc.onShowToc == original)
    device.canShareText = capability
end)
test('hidden-flow editing and non-touch navigation retain the original hold action', function()
    local plugin,ui=reader(); plugin:init();ui.toc:onShowToc()
    ui.handmade.isHandmadeHiddenFlowsEnabled=function() return true end
    ui.handmade.isHandmadeHiddenFlowsEditEnabled=function() return true end
    assert(ui.toc.toc_menu:onMenuHold(toc[1])=='original')
    ui.handmade={};device.touch=false
    assert(ui.toc.toc_menu:onMenuHold(toc[1])=='original')
    device.touch=true;plugin:onCloseDocument()
end)
test('invalid ranges show an error without sharing or closing the TOC', function()
    local plugin,ui=reader();plugin:init();ui.toc:onShowToc()
    local before, history=#shared,#events
    share_hold(ui.toc.toc_menu, {title='Unknown'})
    flush(); assert(#shared==before and #events==history and #notices>0)
    plugin:onCloseDocument()
end)
test('closing a book cancels a queued share and releases menu hooks', function()
    local plugin,ui=reader();plugin:init();ui.toc:onShowToc()
    local menu,original=ui.toc.toc_menu,plugin.original_hold
    local before=#shared
    share_hold(menu, toc[1]);plugin:onCloseDocument();flush()
    assert(#shared==before and menu.onMenuHold==original)
end)
test('later plugins wrapping the reader handler are not overwritten on close', function()
    local plugin,ui=reader();plugin:init()
    local current=ui.toc.onShowToc
    local another=function(...) return current(...) end
    ui.toc.onShowToc=another;plugin:onCloseDocument()
    assert(ui.toc.onShowToc==another)
end)
test('a repeated hold queues only one share', function()
    local plugin,ui=reader();plugin:init();ui.toc:onShowToc()
    local before=#shared
    share_hold(ui.toc.toc_menu, toc[1]);share_hold(ui.toc.toc_menu, toc[1])
    flush();assert(#shared==before+1)
    plugin:onCloseDocument()
end)
test('a Lua/native sharing exception shows an error without leaving a pending operation', function()
    local plugin,ui=reader();plugin:init();ui.toc:onShowToc()
    local original=device.doShareText
    device.doShareText=function() error('native failure') end
    local before=#notices
    share_hold(ui.toc.toc_menu, toc[1]);flush()
    assert(#notices==before+1 and plugin.pending_share==false)
    device.doShareText=original;plugin:onCloseDocument()
end)
test('holding a TOC row does not extract or share until the action is chosen', function()
    local plugin,ui=reader();plugin:init();ui.toc:onShowToc()
    local before, calls=#shared,#ui.document.calls
    ui.toc.toc_menu:onMenuHold(toc[1]);flush()
    assert(#shared==before and #ui.document.calls==calls)
    plugin:onCloseDocument()
end)
test('the full-title action delegates to the stock handler without sharing', function()
    local plugin,ui=reader();plugin:init();ui.toc:onShowToc()
    local before=#shared
    ui.toc.toc_menu:onMenuHold(toc[1])
    dialogs[#dialogs].buttons[2][1].callback();flush()
    assert(events[#events]=='original' and #shared==before)
    plugin:onCloseDocument()
end)
test('an action from a closed reader cannot share or invoke an old title handler', function()
    local plugin,ui=reader();plugin:init();ui.toc:onShowToc()
    ui.toc.toc_menu:onMenuHold(toc[1]);local dialog=dialogs[#dialogs]
    plugin:onCloseDocument();local before,history=#shared,#events
    dialog.buttons[1][1].callback();dialog.buttons[2][1].callback();flush()
    assert(#shared==before and #events==history)
end)
test('a failed large-file sender never falls back to inline Android text',function()
    local plugin=reader();local before=#shared
    device.isAndroid=function() return true end
    package.loaded.tocshare_android={send=function() error('file grant failure') end}
    plugin:sendText(string.rep('x',256*1024+1),'Share','Book',{},nil);flush()
    assert(#shared==before and not plugin.pending_share)
    device.isAndroid=nil;package.loaded.tocshare_android=nil
end)
print('Passed ' .. tests .. ' TOC-sharing tests')
