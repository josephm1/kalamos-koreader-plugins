local shown, closed, full, cleared, saved = {}, {}, 0, 0, 0
package.preload['ui/widget/buttondialog'] = function()return {new=function(_,value)return value end}end
package.preload['ui/uimanager'] = function()return {
 show=function(_,value)shown[#shown+1]=value end,close=function(_,value)closed[#closed+1]=value end,
}end
package.preload.device=function()return {screen={getWidth=function()return 600 end,getHeight=function()return 800 end,scaleBySize=function(_,x)return x end}}end
package.preload.gettext=function()return function(x)return x end end
local Plugin={};require('selectionui')(Plugin)
local original=function()full=full+1 end
local h={onShowHighlightMenu=original,selected_text={text='Example',sboxes={{x=40,y=90,w=100,h=20}}},
 ui={},clear=function()cleared=cleared+1 end,saveHighlight=function()saved=saved+1 end,
 onClose=function()cleared=cleared+1 end}
local plugin=setmetatable({ui={highlight=h}}, {__index=Plugin})
plugin:installCompactSelection();h:onShowHighlightMenu()
assert(#shown==1 and #shown[1].buttons==1 and #shown[1].buttons[1]==4 and full==0)
assert(shown[1].buttons[1][1].icon=='kalamos-highlight' and shown[1].buttons[1][2].icon=='kalamos-note')
shown[1].buttons[1][4].callback();assert(full==1 and cleared==0 and not h.highlight_dialog)
h:onShowHighlightMenu();shown[#shown].buttons[1][1].callback();assert(saved==1 and cleared==1)
local note_index;plugin.makeStickyHighlight=function(_,owner,index)assert(owner==h);note_index=index or true end
h:onShowHighlightMenu(7);shown[#shown].buttons[1][2].callback();assert(note_index==7)
-- A stray selection/palm cannot interrupt Pen or show a menu over live ink.
plugin.ink_mode={kind='space'}
local before_shown=#shown
h:onShowHighlightMenu();assert(#shown==before_shown)
plugin.pending_canvas_start={id='opening'};plugin.ink_mode=nil
h:onShowHighlightMenu();assert(#shown==before_shown)
plugin.pending_canvas_start=nil;plugin.ink_mode=nil
h:onShowHighlightMenu();assert(#shown==before_shown+1)
shown[#shown].buttons[1][4].callback()
-- Later wrappers remain valid when this reader retires; stale hooks delegate.
local ours=h.onShowHighlightMenu;local later=function(...)return ours(...)end;h.onShowHighlightMenu=later
plugin:restoreCompactSelection();assert(h.onShowHighlightMenu==later)
h:onShowHighlightMenu();assert(full==3)
print('Compact selection: four actions, full menu on More, preserved selection, note identity and composable teardown passed')
