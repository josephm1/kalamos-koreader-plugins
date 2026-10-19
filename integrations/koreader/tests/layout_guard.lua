local pending={};local starts,reloads,icons=0,0,0
package.preload['ui/uimanager']=function()return {
 scheduleIn=function(_,delay,fn)assert(delay==1);pending[fn]=true end,
 unschedule=function(_,fn)pending[fn]=nil end,
}end
local Plugin={};require('layoutguard')(Plugin)
local states={PARTIALLY_RERENDERED=1,FULL_RENDERING_IN_BACKGROUND=2,FULL_RENDERING_READY=3,RELOADING_DOCUMENT=4}
local rolling={RENDERING_STATE=states}
local original_step
local function setup(self)
 if self._stepRerenderingAutomation then return end
 original_step=function(next_step)
  if next_step then self.rendering_state=next_step
  elseif self.rendering_state==states.FULL_RENDERING_READY or self.rendering_state==states.RELOADING_DOCUMENT then reloads=reloads+1 end
  if next_step==states.FULL_RENDERING_IN_BACKGROUND then starts=starts+1 end
 end
 self._stepRerenderingAutomation=original_step
end
rolling.setupRerenderingAutomation=setup
local flipping={getRollingRenderingStateIconWidget=function()icons=icons+1;return 'status' end}
local p=setmetatable({ui={rolling=rolling,view={flipping=flipping}}},{__index=Plugin})
p:installWritingLayoutGuard();rolling:setupRerenderingAutomation()
local wrapper=rolling._stepRerenderingAutomation
p.pending_canvas_start={id='c'}
wrapper(states.PARTIALLY_RERENDERED);wrapper(states.FULL_RENDERING_IN_BACKGROUND)
assert(starts==1,'background worker must still run while canvas is active')
p.pending_canvas_start=nil;p.ink_mode={kind='space'}
wrapper(states.FULL_RENDERING_READY)
assert(rolling.rendering_state==states.FULL_RENDERING_READY)
for _=1,100 do wrapper()end
assert(reloads==0 and pending[wrapper],'prepared layout waits without retiring native capture')
assert(flipping:getRollingRenderingStateIconWidget()==nil and icons==0)
p.ink_mode=nil;wrapper();assert(reloads==1)
assert(flipping:getRollingRenderingStateIconWidget()=='status')
-- New stylesheet changes must reach upstream so it cancels/replaces its old worker.
p.ink_mode={kind='space'};wrapper(states.PARTIALLY_RERENDERED)
assert(rolling.rendering_state==states.PARTIALLY_RERENDERED)
wrapper(states.RELOADING_DOCUMENT);assert(rolling.rendering_state==states.PARTIALLY_RERENDERED)
p:restoreWritingLayoutGuard()
assert(rolling.setupRerenderingAutomation==setup and rolling._stepRerenderingAutomation==original_step)
assert(not pending[wrapper]);wrapper();assert(reloads==1,'retired callbacks must do nothing')
-- Teardown may already have removed the upstream automation before plugin close.
p:installWritingLayoutGuard();rolling._stepRerenderingAutomation=nil;p:restoreWritingLayoutGuard()
assert(rolling._stepRerenderingAutomation==nil)
print('Background layout guard: worker runs during ink, reload waits through writing, icons hidden, replacement and close fences passed')
-- Exercise the real pinned ReaderRolling state machine when its checkout is available.
local reader=os.getenv('KOREADER_SOURCE') or 'artifacts/koreader-upstream-ready/koreader'
local file=io.open(reader..'/frontend/apps/reader/modules/readerrolling.lua','r')
if file then
 local source=file:read('*a');file:close()
 local first=assert(source:find('function ReaderRolling:setupRerenderingAutomation()',1,true))
 local last=assert(source:find('function ReaderRolling:tearDownRerenderingAutomation()',first,true))
 local clock=0;local shared={[1]=0,[2]=0};local workers,commits=0,0
 local manager=require('ui/uimanager')
 manager.preventStandby=function()end;manager.getTime=function()return clock end
 manager.event_hook={register=function()end};manager.setDirty=function()end
 local reader_widget={name='ReaderUI'};manager.getTopmostVisibleWidget=function()return reader_widget end
 local env={ReaderRolling={},UIManager=manager,time={s=function(x)return x end},
  logger={dbg=function()end},shared_state=shared}
 setmetatable(env,{__index=_G})
 local chunk=source:sub(first,last-1)..'\nreturn ReaderRolling'
 local loaded
 if _VERSION=='Lua 5.1' then loaded=assert(loadstring(chunk));setfenv(loaded,env)
 else loaded=assert(load(chunk,'actual-reader-automation','t',env))end
 local real=loaded();real.RENDERING_STATE=states;states.DO_RELOAD_DOCUMENT=5
 real._rerenderInBackground=function()workers=workers+1;return 99 end
 real._waitOrKillCurrentRerenderingSubprocess=function(self,wait,kill)
  if wait then self._current_rerendering_pid=nil;return true end
  return false
 end
 real.ui={highlight={},document={},reloadDocument=function()commits=commits+1 end}
 real.view={dialog={},flipping={getRefreshRegion=function()return {}end}}
 local live=setmetatable({ui={rolling=real,view={}}},{__index=Plugin})
 live:installWritingLayoutGuard();live.pending_canvas_start={id='fast'}
 real:setupRerenderingAutomation();real._stepRerenderingAutomation(states.PARTIALLY_RERENDERED)
 real._stepRerenderingAutomation();clock=4;real._stepRerenderingAutomation()
 assert(workers==1 and real.rendering_state==states.FULL_RENDERING_IN_BACKGROUND)
 shared[1]=1;real._stepRerenderingAutomation()
 assert(real.rendering_state==states.FULL_RENDERING_READY)
 live.pending_canvas_start=nil;live.ink_mode={kind='space'}
 for _=1,30 do clock=clock+10;real._stepRerenderingAutomation()end
 assert(commits==0 and shared[2]==0,'real worker must not commit/reload while ink owns geometry')
 live.ink_mode=nil;real._stepRerenderingAutomation();real._stepRerenderingAutomation()
 assert(commits==1 and shared[2]==1)
 live:restoreWritingLayoutGuard()
 print('Actual ReaderRolling: background worker finishes during native writing, cache/reload waits until writer releases layout passed')
end
