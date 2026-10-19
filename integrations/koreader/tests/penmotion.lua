local PenMotion=require('penmotion')
local sent
local bridge={penMotion=function(payload) sent=payload;return {ok=true} end}
local lib={
 AMotionEvent_getAction=function() return 2 end,
 AMotionEvent_getPointerCount=function() return 2 end,
 AMotionEvent_getToolType=function(_,i) return i==1 and 2 or 1 end,
 AMotionEvent_getHistorySize=function() return 1 end,
 AMotionEvent_getHistoricalX=function(_,i,h) assert(i==1 and h==0);return 11 end,
 AMotionEvent_getHistoricalY=function() return 21 end,
 AMotionEvent_getHistoricalPressure=function() return .3 end,
 AMotionEvent_getHistoricalEventTime=function() return 10000000 end,
 AMotionEvent_getX=function(_,i) assert(i==1);return 12 end,
 AMotionEvent_getY=function() return 22 end,
 AMotionEvent_getPressure=function() return .7 end,
 AMotionEvent_getEventTime=function() return 20000000 end,
 AMotionEvent_getDownTime=function() return 5000000 end,
}
assert(PenMotion.forward(lib,{},bridge).ok)
assert(sent.action==2 and sent.downTime==5 and #sent.samples==2)
assert(sent.samples[1][1]==11 and sent.samples[1][4]==10)
assert(sent.samples[2][1]==12 and sent.samples[2][4]==20 and sent.samples[2][3]==.7)
sent=nil;lib.AMotionEvent_getToolType=function() return 1 end
assert(PenMotion.forward(lib,{},bridge)==nil and sent==nil)
print('Generic pen transport preserves stylus identity, coalesced order, pressure and timestamps')
