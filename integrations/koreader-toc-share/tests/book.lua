local root = assert(arg[1]); package.path = root .. '/?.lua;' .. package.path
local Range = require('tocshare_range')
local checks, closed, current, fail = 0, 0
local function doc(text)
    local d = {file='book.epub'}
    function d:compareXPointers(a,b) a,b=tonumber(a),tonumber(b); return a==b and 0 or (a<b and 1 or -1) end
    function d:getPageCount() return 2 end
    function d:getPageXPointer(page) return page == 1 and '0' or tostring(math.max(0,#text-3)) end
    function d:getNextVisibleChar(p) local n=tonumber(p); if n<#text then return tostring(n+1) end end
    function d:getTextFromXPointers(a,b) return text:sub(tonumber(a)+1,tonumber(b)) end
    function d:setupDefaultView() self.defaults=true end
    function d:loadDocument() return not fail end
    function d:render() self.been_rendered=true end
    function d:getProps() return {title='Book Title', authors='Book Author'} end
    function d:close() closed=closed+1 end
    return d
end
local function check(name, fn) fn(); checks=checks+1; print('ok '..checks..' - '..name) end
check('whole text does not depend on a TOC and keeps the last character',function()
    assert(Range.extractBook(doc('Front matter\nChapter one\nChapter two\n最後！'))=='Front matter\nChapter one\nChapter two\n最後！')
end)
check('exact 256 KiB text is accepted without dropping bytes',function()
    local text=string.rep('x',256*1024)
    assert(Range.extractBook(doc(text))==text)
end)
check('oversized books are refused without truncation',function()
    local limit=Range.MAX_SHARE_BYTES;Range.MAX_SHARE_BYTES=1024
    local text,err=Range.extractBook(doc(string.rep('x',Range.MAX_SHARE_BYTES+1)))
    assert(not text and err:find('Nothing was truncated',1,true));Range.MAX_SHARE_BYTES=limit
end)
check('four MiB whole-book extraction retains its final bytes',function()
    local text=string.rep('x',4*1024*1024-4)..'END!'
    assert(Range.extractBook(doc(text))==text)
end)
check('empty books and engine failures are contained',function()
    assert(not Range.extractBook(doc('   ')))
    local d=doc('text');d.getTextFromXPointers=function() error('bad epub') end
    assert(not Range.extractBook(d))
end)
package.preload['document/documentregistry']=function() return {openDocument=function(_,file) assert(file=='book.epub');return current end} end
package.preload.tocshare_metadata=function() return {build=function(ui,title)
    assert(ui.document==current and ui.doc_props.authors=='Book Author')
    return {title=title,bookTitle=ui.doc_props.title,authors=ui.doc_props.authors,thumbnailBase64='cover'},'/preview.jpg'
end} end
local Book=require('tocshare_book')
check('temporary book closes after extracting metadata and cover',function()
    current=doc('Complete book!');local text,metadata,cover=Book.prepare('book.epub')
    assert(text=='Complete book!' and metadata.title=='Book Title' and metadata.bookTitle=='Book Title' and metadata.thumbnailBase64=='cover' and cover=='/preview.jpg')
    assert(closed==1 and current.been_rendered and current.defaults)
end)
check('failed load still closes temporary registry reference',function()
    fail=true;current=doc('text');assert(not Book.prepare('book.epub'));assert(closed==2);fail=false
end)
check('extraction and metadata failures release temporary document',function()
    current=doc('text');current.getProps=function() error('bad props') end
    assert(not Book.prepare('book.epub'));assert(closed==3)
end)
-- Exercise the public file-manager row hook and the shared sender, without Android UI.
local queued, sent, registered = {}, {}
local device={canShareText=function() return true end,doShareText=function(_,text,reason,title) sent[#sent+1]={text,reason,title} end}
package.preload.device=function() return device end
package.preload.gettext=function() return function(s) return s end end
for _,name in ipairs({'buttondialog','infomessage'}) do package.preload['ui/widget/'..name]=function() return {new=function(_,v)return v end} end end
package.preload['ui/widget/container/widgetcontainer']=function() return {extend=function(_,v)return v end} end
package.preload['ui/uimanager']=function() return {show=function()end,close=function()end,nextTick=function(_,fn)queued[#queued+1]=fn end} end
local Plugin=require('main')
local ui={file_chooser={},addFileDialogButtons=function(_,id,fn) assert(id=='tocshare_book');registered=fn end}
local plugin=setmetatable({ui=ui},{__index=Plugin})
check('registers only EPUB file actions; holding never extracts',function()
    current=doc('Complete book!');plugin:init()
    assert(registered and not registered('folder.epub',false) and not registered('book.pdf',true))
    assert(registered('BOOK.EPUB',true)[1].text=='Share book text' and #sent==0 and #queued==0)
end)
check('explicit book action reuses sender with book title and complete text',function()
    registered('book.epub',true)[1].callback()
    assert(#sent==0)
    while #queued>0 do local fn=table.remove(queued,1);fn() end
    assert(#sent==1 and sent[1][1]=='Complete book!' and sent[1][2]=='Share book text' and sent[1][3]=='Book Title')
end)
print('Passed '..checks..' whole-book tests')
