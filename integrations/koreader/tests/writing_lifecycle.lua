local copy = require('inktools').copy
local saved = {entries = {}}
local next_batch, failure, starts, stopped = {strokes = {}}, false, {}, 0
package.preload.androidbridge = function() return {
    startInk = function(bounds) starts[#starts+1] = bounds; return {ok = true} end,
    isPenInputActive = function() return false end,
    drainInk = function() local value=next_batch; next_batch={strokes={}}; return value end,
    pauseInk = function() local value=next_batch; next_batch={strokes={}}; return value end,
    stopInk = function() stopped=stopped+1; local value=next_batch; next_batch={strokes={}}; return value end,
} end
local store = {
    current = function() return {bookId='book',path='book.epub'} end,
    annotations = function() return copy(saved) end,
    writeAnnotations = function(_, value) if failure then return nil,'disk full' end; saved=copy(value);return true end,
    spaces = function() return {schema='kalamos.writing-spaces/v1',bookId='book',spaces={}} end,
}
package.preload.inkstore = function() return store end
package.preload['ffi/blitbuffer'] = function() return {COLOR_BLACK=0,colorFromString=function()return 0 end} end
package.preload.device = function() return {screen={getWidth=function()return 600 end,getHeight=function()return 800 end}} end
package.preload['ui/uimanager'] = function() return {
    tickAfterNext=function()end,scheduleIn=function()end,setDirty=function()end,show=function()end,close=function()end,
} end
package.preload['ui/widget/container/widgetcontainer'] = function() return {extend=function(_,v)return v end} end
package.preload['ui/elements/reader_menu_order'] = function()return {['KOMenu:menu_buttons']={'tools'}}end
package.preload.gettext = function()return function(t)return t end end
package.preload.logger = function()return {warn=function()end,info=function()end}end
for _,n in ipairs({'ui/event','ui/widget/buttondialog','ui/widget/infomessage'}) do
 package.preload[n]=function()return {new=function(_,v)return v end}end
end
local Plugin = require('main')
local hash, closed = 1, 0
local function host()
 return setmetatable({ui={document={file='book.epub', getXPointer=function()return 'view' end,
     getDocumentRenderingHash=function()return hash end}, getCurrentPage=function()return 1 end,
     onClose=function()closed=closed+1 end, view={}},
     ink_available=true}, {__index=Plugin})
end
local function attach(p,kind,target,bounds)
 assert(p:startInk(kind,target,bounds));p:attachInkPage(target or p:inkTarget(),false)
end
local pen={points={{10,20,1,1},{30,40,1,2}},width=3,color=0xff000000}
local p=host();attach(p,'full-page')
assert(starts[#starts].toolBar and starts[#starts].context=='full-page')
local menu={};p:addToMainMenu(menu);assert(menu.kalamos.icon_func()=='kalamos-active')
next_batch={strokes={copy(pen)}};failure=true
assert(not p:finishInk());assert(p.ink_mode and p.ink_mode.pending_batch and not p.ink_session)
assert(#saved.entries==0 and #p.ink_mode.pending_batch.strokes==1)
failure=false;assert(p:finishInk());assert(not p.ink_mode and #saved.entries==1)
assert(menu.kalamos.icon_func()=='kalamos')
-- A font/layout change cannot replay new page ink at the same view key.
assert(#p:strokesForTarget('full-page',p:inkTarget())==1);hash=2
assert(#p:strokesForTarget('full-page',p:inkTarget())==0)
hash=1
-- Ordinary book-close is vetoed on a failed save; the next close retries without duplication.
p=host();attach(p,'full-page');p:installWritingCloseGuard()
next_batch={strokes={copy(pen)}};failure=true;p.ui:onClose()
assert(closed==0 and p.ink_mode and p.ink_mode.pending_batch)
failure=false;p.ui:onClose();assert(closed==1 and not p.ink_mode and #saved.entries==2)
-- Cancel rolls autosaved sticky edits back to the original note, never page ink.
p=host();local target=p:inkTarget();target.stickyId='sticky';attach(p,'sticky',target,{left=0,top=0,right=300,bottom=300})
local old_count=#saved.entries
next_batch={strokes={copy(pen)}};assert(p:checkpointInkPage());assert(#saved.entries==old_count+1)
p:cancelStickyInk();assert(not p.ink_mode and #saved.entries==old_count)
-- Background closes the sticky UI and retires resume flags.
p=host();target=p:inkTarget();target.stickyId='sticky';attach(p,'sticky',target,{left=0,top=0,right=300,bottom=300})
p.sticky_widget={};p.resume_page_writing=true;p.awaiting_sticky=true
next_batch={strokes={},suspended=true};p.deactivatePenSuppression=function()end
assert(p:checkpointInkPage());assert(not p.sticky_widget and not p.resume_page_writing and not p.awaiting_sticky)
-- Final close must save space vectors while its store still exists.
p=host();p.deactivatePenSuppression=function()end;p.restoreStickyHighlightTap=function()end
local alive, writes = true,0
p.writing_spaces={saved={spaces={}},find=function()return {strokes={}}end,
 strokes=function()return {}end, saveInk=function()assert(alive);writes=writes+1;return true end,
 close=function()alive=false end}
target=p:inkTarget();target.spaceId='space';attach(p,'space',target,{left=0,top=0,right=300,bottom=300})
next_batch={strokes={copy(pen)}};p:onCloseDocument();assert(writes==1 and not alive)
-- Direct teardown bypassing onClose retains failed strokes across book reopen in this process.
p=host();attach(p,'full-page');p.deactivatePenSuppression=function()end;p.restoreStickyHighlightTap=function()end
next_batch={strokes={copy(pen)}};failure=true;p:onCloseDocument()
local before=#saved.entries;failure=false
local reopened=host();reopened.setPenSelectionColor=function()end;reopened:onReaderReady()
assert(#saved.entries==before+1 and not reopened.ink_mode)
print('Writing lifecycle: checked toggle, failed-save retry/close veto/recovery, layout fence, sticky cancel/background, final space drain passed')
-- A successful pcall is insufficient: metadata flush can fail without throwing.
p=host();attach(p,'sticky',{stickyId='conversion',viewKey='view'},{left=0,top=0,right=300,bottom=300})
p.ink_mode.converting_space='source';local removed=0
p.writing_spaces={remove=function()removed=removed+1;return true end}
p.ui.handleEvent=function()end;p.ui.doc_settings={flush=function()return nil end}
assert(not p:finishInk());assert(removed==0 and p.ink_mode)
p.ui.doc_settings.flush=function()return '/successful-sidecar'end
assert(p:finishInk());assert(removed==1)
-- Undo/reconversion cannot reuse a previous sticky identity and overwrite edited notes.
p=host();p.writing_spaces={find=function()return {strokes={}}end,info=function()return {anchor='a',tail='b'}end}
local identities={};p.ui.annotation={addItem=function(_,item)identities[#identities+1]=item.kalamosSticky.id;return #identities end}
p.ui.handleEvent=function()end;p.openStickyEditor=function()end
p:keepSpaceAsSticky('space');p:keepSpaceAsSticky('space');assert(identities[1]~=identities[2])
-- Entering space management from a sticky consumes page-resume intent before finishing it.
p=host();p.resume_page_writing=true;p.ink_mode={kind='sticky'}
p.finishInk=function(self)assert(not self.resume_page_writing);self.ink_mode=nil;return true end
p.loadWritingSpaces=function(self)self.writing_spaces={supported=function()return false end};return true end
p:showWritingSpaces();assert(not p.ink_mode)
-- Editing one writing space must not hide another space on the same rendered page.
p=host();p.ink_mode={kind='space'};p.ink_session={target={spaceId='one'}}
p.writing_spaces={saved={spaces={{id='one'},{id='two'}}},bounds=function()return {left=0,top=0,right=100,bottom=100}end,
 strokes=function()return {{points={{10,20,1,1}},width=3}}end}
p.spaceMarker=function()return nil end
local painted=0;p:paintTo({paintRect=function()end,paintCircle=function()painted=painted+1 end,getInverse=function()return 0 end},0,0)
assert(painted==1,'only the active space is omitted from background replay')
print('Writing review regressions: metadata flush, conversion IDs, modal ownership and other-space replay passed')
-- Cancel remains available after native capture stopped and metadata Save failed silently.
p=host();attach(p,'sticky',{stickyId='failed-conversion',viewKey='view'},{left=0,top=0,right=300,bottom=300})
p.ink_mode.converting_space='original-space';p.sticky_widget={}
p.ui.handleEvent=function()end;p.ui.doc_settings={flush=function()return nil end}
p.ui.annotation={annotations={{kalamosSticky={id='failed-conversion'}}}}
local deleted=false;p.ui.highlight={deleteHighlight=function()deleted=true end}
assert(not p:finishInk() and not p.ink_session)
p:cancelStickyInk();assert(not p.ink_mode and not p.sticky_widget and deleted)
print('Writing conversion: failed metadata Save can still Cancel and preserve source passed')
-- Direct Canvas placement resolves the touched paragraph, carries drag height and never
-- stores the placement gesture as handwriting. Blank margins and stale tool events do nothing.
p=host();attach(p,'full-page');p.ink_mode.placement='canvas'
p.ui.document.getWordFromPosition=function(_,pos,no_selection)
 assert(no_selection);if pos.y>100 then return nil end
 return {pos0='paragraph-word',pos1='word-end',word='Example'}
end
local inserted
p.insertWritingSpace=function(_,anchor,height)inserted={anchor=anchor,height=height}end
p:placeWritingTool({name='place-sticky',x=100,y=100});assert(not inserted)
p:placeWritingTool({name='place-canvas',x=100,y=110,endY=310})
assert(inserted.anchor=='paragraph-word' and inserted.height==200)
p.ink_mode.placement=nil;inserted=nil
p:placeWritingTool({name='place-canvas',x=100,y=100});assert(not inserted)
-- The event batch first activates placement and then hands off its coordinate action.
p=host();attach(p,'full-page');local handed;local previous_count=#p:strokesForTarget('full-page',p:inkTarget())
p.writingAction=function(_,event)handed=event end
next_batch={strokes={},events={{kind='action',name='canvas-mode'},
 {kind='action',name='place-canvas',x=100,y=120,endY=250}}}
assert(p:checkpointInkPage());assert(p.ink_mode.placement=='canvas' and handed.x==100 and handed.endY==250)
assert(#p:strokesForTarget('full-page',p:inkTarget())==previous_count)
-- Existing canvases reopen directly; changing size saves the final batch before changing layout.
p=host();local stopped_first=false;local space={id='s',anchor='paragraph',height=100,strokes={}}
p.ink_mode={kind='space',target={spaceId='s'}}
p.finishInk=function(self)stopped_first=true;self.ink_mode=nil;space.strokes={{points={{1,2}}}};return true end
p.writing_spaces={find=function()return space end,change=function(_,id,height,collapsed)
 assert(stopped_first and #space.strokes==1);assert(id=='s' and height==148 and not collapsed);return true end}
local reopened_id;p.writeInSpace=function(_,id)reopened_id=id end
p:adjustActiveSpace('space-larger');assert(reopened_id=='s')
print('Direct writing tools: paragraph hit-testing, stale-contact fence, ordered placement handoff and save-before-resize passed')
-- PDF Note uses page-transformed geometry and KOReader's existing highlight-save path.
p=host();p.ui.paging={};local pagepos={page=7,rotation=90,x=30,y=40,zoom=1.5}
p.ui.view.screenToPageTransform=function(_,pos)assert(pos.x==100 and pos.y==120);return copy(pagepos)end
p.ui.document.getWordFromPosition=function(_,pos)assert(pos.page==7 and pos.x==30);return {word='PDF word',pos=pos,pbox={x=1},sbox={x=2}}end
p.ink_mode={placement='sticky'};p.finishInk=function(self)self.ink_mode=nil;return true end
p.ui.highlight={};local selected
p.makeStickyHighlight=function(self,h)
 selected=h.selected_text;assert(self.creating_placement_sticky and self.resume_page_writing)
end
p:placeWritingTool({name='place-sticky',x=100,y=120})
assert(selected.pos0.page==7 and selected.pos1.rotation==90 and selected.pboxes[1].x==1 and selected.sboxes[1].x==2)
assert(not p.creating_placement_sticky)
print('Direct PDF Note: page transform, native position/box normalization and normal highlight save handoff passed')
-- A quick finger tap immediately after selecting Canvas drains the native choice first.
p=host();attach(p,'full-page');local page_tap;local placed_fast=false
p.ui.registerTouchZones=function(_,zones)for _,zone in ipairs(zones)do if zone.id=='kalamos_writing_space' then page_tap=zone.handler end end end
p.placeWritingTool=function(_,event)assert(event.name=='place-canvas');placed_fast=true end
p:registerSpaceMarkers();next_batch={strokes={},events={{kind='action',name='canvas-mode'}}}
assert(page_tap({pos={x=120,y=150}}) and placed_fast)
print('Direct Canvas finger tap: preceding native tool choice is drained before page navigation passed')
-- A canvas at the end of a long paragraph reveals its end, never its first page.
p=host();local reveal;local tick=require('ui/uimanager').tickAfterNext
require('ui/uimanager').tickAfterNext=function(_,fn)fn()end
p.ui.handleEvent=function(_,event)reveal=event end
package.loaded['ui/event'].new=function(_,kind,anchor)return {kind=kind,anchor=anchor}end
local canvas={id='long',anchor='paragraph-start',tail='paragraph-tail',height=140,strokes={}}
p.writing_spaces={saved={spaces={canvas}},find=function()return canvas end,info=function()return {tail='resolved-paragraph-end'}end,
 bounds=function()return {left=0,top=100,right=500,bottom=240}end}
p.startInk=function(_,kind,target,bounds)assert(kind=='space' and target.spaceId=='long' and bounds.top==100);return true end
p:writeInSpace('long');assert(reveal.anchor=='resolved-paragraph-end')
require('ui/uimanager').tickAfterNext=tick
-- The reusable spacing handle changes the same canvas instead of guessing nearby text
-- or adding a second space. Save completes before its height is changed.
p=host();p.ink_mode={placement='canvas'};canvas={id='same',height=140,strokes={}}
local finished=false;local reopened
p.writing_spaces={saved={spaces={canvas}},bounds=function()return {left=20,top=100,right=500,bottom=240}end,
 find=function()return canvas end,change=function(_,id,height)assert(finished and id=='same' and height==200);return true end}
p.finishInk=function(self)finished=true;self.ink_mode=nil;return true end
p.writeInSpace=function(_,id)reopened=id end
p:placeWritingTool({name='place-canvas',x=250,y=238,endY=298});assert(reopened=='same')
print('Notes-style canvas: reveal paragraph tail and reuse moving-edge handle with save-before-resize passed')
-- A book with page handwriting is allowed to create a canvas; no erase-first dialog.
p=host();p.ink_annotations=copy(saved);assert(p:hasPageInk())
local before_ink=copy(saved);local inserted_id;local open_id
p.ui.handleEvent=function()end;p.loadWritingSpaces=function()return true end
p.writing_spaces={saved={spaces={}},info=function()return {anchor='source',tail='tail'}end,
 change=function(_,id,height,collapsed,candidate)assert(candidate=='source' and height==120);inserted_id=id;return true end}
p.writeInSpace=function(_,id)open_id=id end
p:insertWritingSpace('source',120);assert(inserted_id==open_id)
assert(#saved.entries==#before_ink.entries and saved.entries[1].strokes[1].points[1][1]==before_ink.entries[1].strokes[1].points[1][1])
-- Original-layout action preserves the canvas model and restores the marked reading view.
p=host();p.ink_annotations={entries={{kind='full-page',anchor={fragment='marked-page',canvasLayout={{anchor='p',height=120}}},strokes={copy(pen)}}}}
local original_mode, original_recipe;local position
p.writing_spaces={saved={spaces={{id='s'}}},setOriginalView=function(self,value,recipe)original_mode=value;original_recipe=recipe;self.original_view=value end}
p.ui.handleEvent=function(_,event)position=event.anchor end
p.startInk=function(_,kind)assert(kind=='full-page');return true end
p:toggleOriginalPageInk();assert(original_mode and original_recipe[1].height==120 and position=='marked-page')
p:toggleOriginalPageInk();assert(not original_mode and position=='view')
-- Finger drags on the visible lower handle resize instead of scrolling the book.
p=host();local handlers={};local resized
p.ui.registerTouchZones=function(_,zones)for _,zone in ipairs(zones)do handlers[zone.id]=zone.handler end end
p.writing_spaces={saved={spaces={{id='existing'}}},bounds=function()return {left=20,top=100,right=500,bottom=240}end}
p.resizeWritingSpace=function(_,id,delta)resized={id,delta}end
p:registerSpaceMarkers()
assert(handlers.kalamos_canvas_pan({start_pos={x=250,y=238},pos={x=250,y=270}}))
assert(handlers.kalamos_canvas_pan_release({pos={x=250,y=320}}))
assert(resized[1]=='existing' and resized[2]==82)
assert(not handlers.kalamos_canvas_pan({start_pos={x=250,y=150},pos={x=250,y=180}}))
print('Canvas blocker fixed: existing page ink retained, original-view recovery and direct finger handle resizing passed')
-- CREngine cache identities may change across a stylesheet round trip while actual
-- geometry stays identical. Recognize only observed equivalent layouts; edited
-- geometry stays fenced, and old engine-keyed strokes remain erasable on restoration.
p=host();local stable_hash,calls=100,0;local settings={}
p.ui.doc_settings={readSetting=function(_,key)return settings[key]end,saveSetting=function(_,key,value)settings[key]=value end}
p.ui.document._document={getWritingLayoutHash=function()calls=calls+1;return stable_hash end}
hash=101;local initial=p:inkTarget();local second=p:inkTarget();assert(calls==1 and initial.layout==second.layout)
p.ink_annotation_index={['full-page\0layout:'..initial.engineLayout..'\0view\0view']={copy(pen)}}
-- Use the actual view key, whose source fragment is stable across the layout switch.
p.ink_annotation_index={['full-page\0layout:'..initial.engineLayout..'\0view\0'..initial.viewKey]={copy(pen)}}
assert(#p:strokesForTarget('full-page',initial)==1)
hash=102;stable_hash=200;assert(#p:strokesForTarget('full-page',p:inkTarget())==0)
hash=103;stable_hash=100;local restored=p:inkTarget();assert(restored.layout==initial.layout and #p:strokesForTarget('full-page',restored)==1)
assert(settings.kalamos_ink_layout_aliases[initial.engineLayout]==initial.layout)
assert(calls==3)
hash=1
print('Layout compatibility: cached geometry fingerprint, engine-hash round trip, old ink replay and changed-layout fence passed')

-- Departing a scoped canvas returns to full-page tools rather than silently disabling them.
p=host();p.ink_mode={kind='space'};p.ink_session={target={viewKey='old'}}
p.saveInkPage=function()return true end
local returned
p.startInk=function(_,kind)returned=kind end
p:changeInkPage(2);assert(returned=='full-page')
print('Persistent toolbar: canvas turns retain tools passed')

local manager=require('ui/uimanager')
-- Canvas palm gestures cannot select text, scroll the reader, resize from a distant edge,
-- or repeatedly detach/reopen a canvas that already owns the native writer.
p=host();handlers={};resized=nil
p.ui.registerTouchZones=function(_,zones)for _,zone in ipairs(zones)do handlers[zone.id]=zone.handler end end
p.writing_spaces={saved={spaces={{id='c'}}},bounds=function()return {left=20,top=100,right=500,bottom=240}end}
p.ink_mode={kind='space',target={spaceId='c'},bounds={left=20,top=100,right=500,bottom=240}}
p:registerSpaceMarkers()
assert(handlers.kalamos_writing_hold())
assert(handlers.kalamos_writing_space({pos={x=100,y=150}}))
assert(handlers.kalamos_canvas_pan({start_pos={x=450,y=238},pos={x=450,y=300}}))
assert(not p.canvas_finger_drag)
assert(handlers.kalamos_canvas_swipe({pos={x=150,y=150},end_pos={x=150,y=200}}))
p.finishInk=function()error('same-canvas contact must not detach the daemon')end
assert(p:writeInSpace('c'))
p.ink_mode=nil;assert(not handlers.kalamos_writing_hold())
print('Canvas input ownership: palm holds/pans/swipes cannot become text selection or edge resizes; active canvas entry is idempotent passed')

-- A pending canvas claims input before the deferred render, and close cancels the callback.
p=host();local deferred;local old_tick=manager.tickAfterNext
manager.tickAfterNext=function(_,fn)deferred=fn end
p.ui.handleEvent=function()end
p.writing_spaces={find=function()return {id='pending',anchor='a'}end,info=function()return {tail='b'}end}
p.startInk=function()error('Cancelled canvas must not acquire a native writer')end
p:writeInSpace('pending');assert(p.pending_canvas_start)
p:toggleWriting();assert(not p.pending_canvas_start);deferred()
manager.tickAfterNext=old_tick
-- Repainting a completed highlighter/erase batch waits until the next live stroke has ended.
p=host();attach(p,'full-page');local scheduled;local old_schedule=manager.scheduleIn
local bridge=require('androidbridge');local old_active=bridge.isPenInputActive
bridge.isPenInputActive=function()return true end
manager.scheduleIn=function(_,_,fn)scheduled=fn end
local old_starts=#starts;p:replayEditedInk(p.ink_session)
assert(scheduled and #starts==old_starts and p.ink_mode.replay_scheduled)
bridge.isPenInputActive=function()return false end;scheduled();assert(#starts==old_starts+1)
manager.scheduleIn=old_schedule;bridge.isPenInputActive=old_active
print('Canvas handoffs: pending entry is cancellable and reconciliation waits for pen idle passed')

-- Canvas-local ownership never scans/fingerprints the whole rendered book, and is
-- unaffected by another chapter's engine-cache hash changing in the background.
p=host();p.pending_canvas_start={id='fast'};p.writing_spaces={saved={spaces={}},layout_revision=4,layoutSnapshot=function()return {}end}
p.ui.document._document={getWritingLayoutHash=function()error('whole-DOM scan blocks canvas entry')end}
local local_bottom=200
p.writing_spaces.find=function()return {anchor='current'}end
p.writing_spaces.info=function()return {left=20,top=100,right=500,bottom=local_bottom,visible=true}end
local fast=p:inkTarget();hash=hash+1;assert(p:inkTarget().layout==fast.layout)
local_bottom=220;assert(p:inkTarget().layout~=fast.layout);local_bottom=200
p.writing_spaces.layout_revision=5;assert(p:inkTarget().layout~=fast.layout)
print('Canvas-local layout fence: no whole-book fingerprint or unrelated chapter-hash interruption passed')

-- Exit is the same save/disable path as the top toggle, including scoped sticky notes.
p=host();attach(p,'full-page');next_batch={strokes={copy(pen)},events={{kind='action',name='exit-kalamos'}}}
local exit_count=#saved.entries;assert(p:checkpointInkPage())
assert(not p.ink_mode and #saved.entries==exit_count+1 and not p:isWritingLayoutPinned())
p=host();target=p:inkTarget();target.stickyId='exit-sticky'
attach(p,'sticky',target,{left=0,top=0,right=300,bottom=300});p.resume_page_writing=true
assert(p:exitKalamosMode());assert(not p.ink_mode and not p.resume_page_writing)
p=host();attach(p,'full-page');next_batch={strokes={copy(pen)}};failure=true
assert(not p:exitKalamosMode() and p.ink_mode and p.ink_mode.pending_batch)
failure=false;assert(p:exitKalamosMode() and not p.ink_mode)
print('Exit Kalamos: saves final strokes, disables tools/layout pin, sticky exit cannot reopen page mode, failed Save retains recovery passed')

-- A palm tap/pan/swipe during ordinary writing must not turn the page and clear its ink.
p=host();handlers={};p.ui.registerTouchZones=function(_,zones)for _,z in ipairs(zones)do handlers[z.id]=z.handler end end
p:registerSpaceMarkers();p.ink_mode={kind='full-page'}
local native=require('androidbridge');local old=native.isPenInputActive
native.isPenInputActive=function()return true end
assert(handlers.kalamos_writing_space({pos={x=550,y=200}}))
assert(handlers.kalamos_canvas_pan({start_pos={x=200,y=200},pos={x=220,y=220}}))
assert(handlers.kalamos_canvas_swipe({pos={x=200,y=200},end_pos={x=450,y=200}}))
native.isPenInputActive=function()return false end
assert(not handlers.kalamos_canvas_swipe({pos={x=200,y=200},end_pos={x=450,y=200}}))
native.isPenInputActive=old
print('Page writing: palm tap/pan/swipe blocked during pen contact; intentional idle page turn remains available passed')
