-- Run with KOReader's bundled LuaJIT, with cwd at its runtime directory.
local plugin_root, fixture_root = assert(arg[1]), assert(arg[2])
require('setupkoenv')
package.path = plugin_root .. '/?.lua;' .. package.path
local Range = require('tocshare_range')
local cre = require('libs/libkoreader-cre')
cre.registerFont('fonts/noto/NotoSerif-Regular.ttf')
local function contains(value, expected) assert(value:find(expected,1,true), 'missing: ' .. expected) end
local function excludes(value, unexpected) assert(not value:find(unexpected,1,true), 'leaked: ' .. unexpected) end
local checks=0
local function open(name, size)
    local raw=cre.newDocView(600,800,1)
    raw:setStringProperty('font.face.default','Noto Serif')
    raw:setIntProperty('font.size',size or 24)
    assert(raw:loadDocument(fixture_root .. '/' .. name))
    raw:renderDocument()
    -- The plugin calls only these public CreDocument APIs, forwarded to the real engine.
    local doc=setmetatable({file=name,getPageCount=function(_,internal) return raw:getPages(internal) end},
        {__index=function(_,key) return function(_,...) return raw[key](raw,...) end end})
    return raw,doc,raw:getToc()
end
for _,size in ipairs({16,36}) do
    local raw,doc,toc=open('nested.epub',size)
    assert(#toc==6)
    local position=raw:getXPointer()
    local whole,wholeErr=Range.extractBook(doc);assert(whole,wholeErr)
    contains(whole,'BEFORE_TOC_FRONT_MATTER');contains(whole,'ONE_ONLY');contains(whole,'TWO_ONLY')
    contains(whole,'FINAL_END café Ελληνικά 中文！');checks=checks+1
    local chapter=assert(Range.extract(doc,toc,toc[1]))
    contains(chapter,'ONE_ONLY');contains(chapter,'A_ONLY');contains(chapter,'B_ONLY')
    excludes(chapter,'TWO_ONLY');excludes(chapter,'Chapter Two')
    checks=checks+1
    local subsection=assert(Range.extract(doc,toc,toc[2]))
    contains(subsection,'A_ONLY');contains(subsection,'café')
    excludes(subsection,'ONE_ONLY');excludes(subsection,'B_ONLY')
    checks=checks+1
    local two=assert(Range.extract(doc,toc,toc[4]))
    contains(two,'TWO_ONLY');contains(two,'C_ONLY');excludes(two,'THREE_ONLY')
    excludes(two,'Chapter Three');checks=checks+1
    local last,err=Range.extract(doc,toc,toc[6]);assert(last,err)
    contains(last,'THREE_ONLY');contains(last,'paragraph 99');contains(last,'FINAL_END café Ελληνικά 中文！')
    excludes(last,'TWO_ONLY')
    assert(raw:getXPointer()==position, 'extraction navigated the reader')
    checks=checks+1
    raw:close()
end
local raw,doc,toc=open('split.epub')
assert(#toc==2)
local whole,wholeErr=Range.extractBook(doc);assert(whole,wholeErr)
contains(whole,'SPINE_ONE_ONLY');contains(whole,'SPINE_TWO_ONLY');contains(whole,'SPLIT_FINAL_END!');checks=checks+1
local first=assert(Range.extract(doc,toc,toc[1]))
contains(first,'SPINE_ONE_ONLY');contains(first,'CHAPTER_ONE_CONTINUED');excludes(first,'SPINE_TWO_ONLY')
checks=checks+1
local second=assert(Range.extract(doc,toc,toc[2]))
contains(second,'SPINE_TWO_ONLY');contains(second,'SPLIT_FINAL_END!');excludes(second,'CHAPTER_ONE_CONTINUED')
checks=checks+1
raw:close()
raw,doc,toc=open('single.epub')
assert(#toc==1)
local single,err=Range.extract(doc,toc,toc[1]);assert(single,err)
contains(single,'SINGLE_START');contains(single,'paragraph 99');contains(single,'SINGLE_FINAL_END！')
checks=checks+1
raw:close()
raw,doc,toc=open('no-toc.epub')
local untabled,untabledErr=Range.extractBook(doc);assert(untabled,untabledErr)
contains(untabled,'UNTABLED_START');contains(untabled,'UNTABLED_END！');checks=checks+1
raw:close()
raw,doc,toc=open('large.epub')
local large,largeErr=Range.extractBook(doc);assert(large,largeErr)
assert(#large>4*1024*1024, 'large real EPUB did not exceed the transaction buffer')
contains(large,'LARGE_START');contains(large,'LARGE_FINAL_END！');checks=checks+1
raw:close()
print('Passed ' .. checks .. ' actual KOReader engine scenarios (EPUB 2/3, nested/same-page, split spine, final page, Unicode, two font sizes)')

-- Exercise real BlitBuffer scaling, JPEG compression and Base64 with no display server.
local BB=require("ffi/blitbuffer")
local coverMetadata=require("tocshare_metadata").build({doc_props={title="A book",authors="Author"},
    document={getCoverPageImage=function()
        local image=BB.new(640,960,BB.TYPE_BBRGB32)
        image:fill(BB.COLOR_WHITE)
        return image
    end}}, "Chapter 2")
assert(coverMetadata.thumbnailBase64, "Actual cover encoding produced no thumbnail")
local coverBytes=require("mime").unb64(coverMetadata.thumbnailBase64)
assert(coverBytes:sub(1,3)=="\255\216\255" and #coverBytes<90000)
print("Passed real KOReader BlitBuffer resize/JPEG/Base64 thumbnail scenario")
