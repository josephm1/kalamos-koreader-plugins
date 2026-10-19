-- Execute the actual action-tab branch from the pinned reader when available.
local reader=os.getenv('KOREADER_SOURCE') or 'artifacts/koreader-upstream-ready/koreader'
local file=io.open(reader..'/frontend/ui/widget/touchmenu.lua','r')
if file then
 local source=file:read('*a');file:close()
 local first=assert(source:find('function TouchMenu:switchMenuTab(tab_num)',1,true))
 local last=assert(source:find('    if self.tab_item_table[tab_num].remember',first,true))
 local sequence,queued={},nil
 local env={TouchMenu={},UIManager={tickAfterNext=function(_,fn)queued=fn end}}
 setmetatable(env,{__index=_G})
 local chunk=source:sub(first,last-1)..'\nend\nreturn TouchMenu'
 local loaded
 if _VERSION=='Lua 5.1' then loaded=assert(loadstring(chunk));setfenv(loaded,env)
 else loaded=assert(load(chunk,'actual-action-tab','t',env))end
 local menu=loaded()
 local owner={tab_item_table={{activate_callback=function()sequence[#sequence+1]='activate' end}},
  touch_menu_callback=function()sequence[#sequence+1]='close-bottom' end,
  onClose=function()sequence[#sequence+1]='close-top' end}
 menu.switchMenuTab(owner,1)
 assert(table.concat(sequence,',')=='close-bottom,close-top' and queued)
 queued();assert(table.concat(sequence,',')=='close-bottom,close-top,activate')
 owner.touch_menu_callback=nil;menu.switchMenuTab(owner,1);assert(queued)
 print('Actual action tab: bottom config and top menu close before deferred Kalamos activation; missing callback compatible passed')
end
