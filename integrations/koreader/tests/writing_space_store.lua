local copy=require('inktools').copy
local path='/sdcard/Kalamos/BookData/book/writing-spaces.json'
local encoded, raw, fail, removed, writes
package.preload.rapidjson=function()return {
 array=function(t)return t end, encode=function(value)encoded=copy(value);return 'encoded'end,
 decode=function()return copy(raw)end,
}end
package.preload.util=function()return {makePath=function()end}end
package.preload['libs/libkoreader-lfs']=function()return {attributes=function()return 'directory'end}end
io.open=function(name,mode)
 assert(name==path or name==path..'.tmp','no legacy or generated data access')
 if mode=='rb' then if not raw then return nil,'missing',2 end;return {read=function()return 'source'end,close=function()return true end}end
 return {write=function()writes=(writes or 0)+1;return true end,flush=function()if fail then return nil,'disk full'end;return true end,close=function()return true end}
end
os.rename=function()raw=copy(encoded);return true end
os.remove=function()removed=true;return true end
local store=require('inkstore')
local doc=assert(store.spaces('book'));assert(#doc.spaces==0)
doc.spaces={{id='gap',anchor='paragraph',height=150,collapsed=false,strokes={{points={{.1,.2,1,2}},width=3}},basisWidth=400,basisHeight=150}}
assert(store.writeSpaces('book',doc));assert(store.spaces('book').spaces[1].strokes[1].points[1][2]==.2)
local original=copy(raw)
fail=true;doc.spaces[1].height=200;assert(not store.writeSpaces('book',doc));assert(raw.spaces[1].height==150 and removed)
fail=false
for _,mutate in ipairs({
 function(d)d.schema='future/v3'end,
 function(d)d.spaces[1].height=0/0 end,
 function(d)d.spaces[1].basisWidth=-1 end,
 function(d)d.spaces[1].strokes[1].points={{[1]=.2,[2]=math.huge}}end,
 function(d)d.spaces[2]=copy(d.spaces[1])end,
 function(d)d.spaces[1].strokes[1].points={bad='not an array'}end,
})do
 raw=copy(original);mutate(raw);assert(not store.spaces('book'))
 local before=writes;assert(not store.writeSpaces('book',doc));assert(writes==before,'failed load must block replacement')
end
raw=copy(original);assert(store.spaces('book'));assert(store.writeSpaces('book',doc))
print('Writing-space store: atomic failure, numeric/schema/identity validation and failed-load write guard passed')
