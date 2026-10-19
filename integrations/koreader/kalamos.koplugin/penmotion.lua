-- NativeActivity input is not dispatched to Java Views. Preserve coalesced stylus samples and
-- hand each event to the selected standard Android controller; Bigme never enters this path.
local PenMotion = {}
function PenMotion.forward(lib, event, bridge)
    local action = tonumber(lib.AMotionEvent_getAction(event)) % 256
    if action ~= 0 and action ~= 1 and action ~= 2 and action ~= 3 then return end
    local count = tonumber(lib.AMotionEvent_getPointerCount(event))
    local index
    for i = 0, count - 1 do
        if tonumber(lib.AMotionEvent_getToolType(event, i)) == 2 then index = i; break end
    end
    if not index then return end
    local samples = {}
    for h = 0, tonumber(lib.AMotionEvent_getHistorySize(event)) - 1 do
        samples[#samples + 1] = {
            tonumber(lib.AMotionEvent_getHistoricalX(event,index,h)),
            tonumber(lib.AMotionEvent_getHistoricalY(event,index,h)),
            tonumber(lib.AMotionEvent_getHistoricalPressure(event,index,h)),
            math.floor(tonumber(lib.AMotionEvent_getHistoricalEventTime(event,h)) / 1000000),
        }
    end
    samples[#samples + 1] = {
        tonumber(lib.AMotionEvent_getX(event,index)), tonumber(lib.AMotionEvent_getY(event,index)),
        tonumber(lib.AMotionEvent_getPressure(event,index)),
        math.floor(tonumber(lib.AMotionEvent_getEventTime(event)) / 1000000),
    }
    return bridge.penMotion({ action=action,
        downTime=math.floor(tonumber(lib.AMotionEvent_getDownTime(event)) / 1000000), samples=samples })
end
return PenMotion
