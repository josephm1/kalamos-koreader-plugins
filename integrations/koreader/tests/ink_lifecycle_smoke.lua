local current_page = 1
local next_batch = { strokes = {} }
local entries = {}
local starts = {}
local notices = {}
local scheduled = {}
local annotation_reads = 0
local annotation_writes = 0
local pauses = 0
local stops = 0
local reader_menu_order = {
    ["KOMenu:menu_buttons"] = { "navi", "typeset", "setting", "tools", "search", "filemanager", "main" },
}

package.preload["androidbridge"] = function()
    return {
        startInk = function(bounds) starts[#starts + 1] = bounds; return { ok = true } end,
        drainInk = function() return next_batch end,
        pauseInk = function() pauses = pauses + 1; return next_batch end,
        stopInk = function() stops = stops + 1; return next_batch end,
        isPenInputActive = function() return false end,
    }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255, colorFromString = function() return 0 end }
end
package.preload["inkstore"] = function()
    return {
        current = function() return { bookId = "book", title = "Book", toc = {} } end,
        configure = function() return true end,
        spaces = function() return { schema = "kalamos.writing-spaces/v1", bookId = "book", spaces = {} } end,
        annotations = function()
            annotation_reads = annotation_reads + 1
            return { entries = entries }
        end,
        appendInk = function(_, entry) entries[#entries + 1] = entry; return true end,
        writeAnnotations = function()
            annotation_writes = annotation_writes + 1
            return true
        end,
    }
end
local device = {
    isAndroid = function() return false end,
    screen = { getWidth = function() return 1072 end, getHeight = function() return 1448 end },
    input = { gesture_detector = { adjustGesCoordinate = function() end } },
}
package.preload["device"] = function() return device end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, _, action) scheduled[#scheduled + 1] = action end,
        tickAfterNext = function(_, action)
            scheduled[#scheduled + 1] = function() scheduled[#scheduled + 1] = action end
        end,
        show = function(_, widget) notices[#notices + 1] = widget.text end,
        close = function() end,
        isWidgetShown = function() return true end,
        setDirty = function() end,
    }
end
package.preload["logger"] = function() return { info = function() end, warn = function() end } end
package.preload["ui/elements/reader_menu_order"] = function() return reader_menu_order end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(_, value) return value end }
end
package.preload["gettext"] = function() return function(value) return value end end
for _, name in ipairs({
    "ui/widget/buttondialog", "ui/event", "apps/filemanager/filemanager",
    "ui/widget/infomessage", "ui/widget/notification", "ui/widget/menu",
    "ui/widget/filechooser", "ui/widget/iconwidget",
}) do
    package.preload[name] = function() return { new = function(_, value) return value end } end
end

local plugin = require("main")
plugin.ui = {
    getCurrentPage = function() return current_page end,
    document = { getXPointer = function() return "xp-" .. current_page end },
}

local menu_items = {}
plugin:addToMainMenu(menu_items)
assert(reader_menu_order["KOMenu:menu_buttons"][5] == "kalamos", "Kalamos tab must follow Tools")
assert(menu_items.kalamos.icon == "kalamos", "Kalamos tab must use its own icon")
assert(#reader_menu_order.kalamos == 1, "Kalamos tab is a direct writing action with one key-menu fallback")
assert(menu_items.kalamos.activate_callback and menu_items.kalamos.remember == false)
assert(menu_items.kalamos.icon_func() == "kalamos")
for _, id in ipairs(reader_menu_order.kalamos) do
    assert(menu_items[id], "missing Kalamos top-bar feature: " .. id)
end

local function run_until_started(count)
    local guard = 0
    while #starts < count do
        guard = guard + 1
        assert(guard < 20 and #scheduled > 0, "scheduled ink attach did not run")
        table.remove(scheduled, 1)()
    end
end

plugin:startInk("full-page")
run_until_started(1)
assert(#starts == 1 and #starts[1].strokes == 0, "first page should start clean")
assert(starts[1].pageTransition == false, "initial attach must not force a page-transition refresh")

local page_one_stroke = { { 10, 20, 1, 1 }, { 30, 40, 1, 2 } }
next_batch = { strokes = { page_one_stroke } }
current_page = 2
plugin:onPageUpdate(2)
run_until_started(2)
assert(entries[1].anchor.page == 0, "departing ink must retain the old zero-based page")
assert(#starts == 2 and #starts[2].strokes == 0, "new page must not inherit old page ink")
assert(starts[2].pageTransition == true, "blank destination must receive a full transition refresh")

local page_two_stroke = { { 50, 60, 1, 3 }, { 70, 80, 1, 4 } }
next_batch = { strokes = { page_two_stroke } }
current_page = 1
plugin:onPageUpdate(1)
run_until_started(3)
assert(entries[2].anchor.page == 1, "second page ink must be stored under page two")
assert(#starts == 3 and #starts[3].strokes == 1, "returning page must replay its saved ink")
assert(starts[3].pageTransition == true, "returning page replay must reconcile the full panel")
assert(starts[3].strokes[1][1][1] == 10, "returning page replayed another page's stroke")
assert(annotation_reads == 1, "active handwriting must load its annotation document only once")
assert(annotation_writes == 2, "each departing page batch must persist through the cached document")
assert(pauses == 2, "full-page transitions must reuse the bound surface")
assert(stops == 0, "full-page transitions must not destroy the surface")

local hold_calls, pan_calls, release_calls = 0, 0, 0
plugin.ink_mode = nil
plugin.ui.view = { screenToPageTransform = function(_, pos) return pos end }
plugin.ui.document.getWordFromPosition = function() return { word = "test" } end
plugin.ui.highlight = {
    view = { highlight = { disabled = true } },
    onHold = function(self)
        assert(self.view.highlight.disabled == false, "pen selection must override generic long-press disabling")
        hold_calls = hold_calls + 1
        return true
    end,
    onHoldPan = function(self)
        assert(self.view.highlight.disabled == false, "pen selection drag must stay enabled")
        pan_calls = pan_calls + 1
    end,
    onHoldRelease = function(self)
        assert(self.long_hold_reached == true, "pen selection must request the selection menu")
        release_calls = release_calls + 1
    end,
}
plugin.pen_contact_active = true
assert(plugin:handleReadingPenGesture({ ges = "hold", pos = { x = 10, y = 20 } }))
assert(plugin:handleReadingPenGesture({ ges = "hold_pan", pos = { x = 30, y = 20 } }))
plugin.pen_contact_active = false
plugin.pen_release_pending = true
assert(plugin:handleReadingPenGesture({ ges = "hold_release", pos = { x = 30, y = 20 } }))
plugin.pen_release_pending = true
assert(plugin:handleReadingPenGesture({
    ges = "swipe", pos = { x = 10, y = 20 }, end_pos = { x = 50, y = 20 },
}))
assert(hold_calls == 2 and pan_calls == 2 and release_calls == 2,
    "pen gestures must be routed only through text selection: " ..
    hold_calls .. "/" .. pan_calls .. "/" .. release_calls)
assert(plugin.ui.highlight.view.highlight.disabled == true,
    "pen selection must restore the user's generic long-press setting")

local sticky_factory
plugin.ui.highlight.addToHighlightDialog = function(_, id, factory)
    assert(id == "08_kalamos_handwritten_sticky" or id == "09_kalamos_writing_space", "unexpected writing action id")
    if id == "08_kalamos_handwritten_sticky" then sticky_factory = factory end
end
plugin:addToHighlightDialog()
assert(sticky_factory and sticky_factory(plugin.ui.highlight).text == "Handwritten sticky note",
    "selection menu must expose handwritten sticky notes")

local annotation_event = false
plugin.ui.annotation = { annotations = {} }
plugin.ui.handleEvent = function() annotation_event = true end
plugin.ui.highlight.selected_text = { text = "selected phrase", pos0 = "xp-a", pos1 = "xp-b" }
plugin.ui.highlight.saveHighlight = function(self)
    plugin.ui.annotation.annotations[1] = {
        text = self.selected_text.text,
        color = self.selected_text.color,
        drawer = self.selected_text.drawer,
    }
    return 1
end
plugin.ui.highlight.onClose = function() end
local opened_sticky
plugin.openStickyEditor = function(_, item) opened_sticky = item end
plugin:makeStickyHighlight(plugin.ui.highlight)
local sticky_annotation = plugin.ui.annotation.annotations[1]
assert(sticky_annotation.color == "blue" and sticky_annotation.drawer == "lighten",
    "handwritten sticky anchor must use the distinct high-contrast blue highlight")
assert(sticky_annotation.kalamosSticky.schema == "kalamos.handwritten-sticky/v1"
    and sticky_annotation.kalamosSticky.id, "sticky anchor metadata must be persisted")
assert(annotation_event, "sticky metadata must emit an annotation update")
table.remove(scheduled)()
table.remove(scheduled)()
assert(opened_sticky == sticky_annotation,
    "choosing handwritten sticky note must open its writing canvas immediately")

local painted = 0
plugin:paintTo({
    getInverse = function() return 0 end,
    paintCircle = function() painted = painted + 1 end,
}, 0, 0)
assert(painted > 0, "saved page strokes must remain visible in normal reading mode")

-- Android background release must preserve the last completed batch and retire
-- Lua's old watcher without attempting another native attach or page replay.
plugin.ink_mode = nil
plugin.ink_session = nil
next_batch = { strokes = {} }
plugin:startInk("full-page")
run_until_started(#starts + 1)
local saved_before, started_before, stopped_before = annotation_writes, #starts, stops
next_batch = { strokes = { { { 91, 92, 1, 1 }, { 93, 94, 1, 2 } } }, suspended = true }
assert(plugin:checkpointInkPage())
assert(annotation_writes == saved_before + 1, "background handoff must save completed strokes")
assert(entries[#entries].anchor.page == current_page - 1, "background ink must retain its page")
assert(plugin.ink_mode == nil and plugin.ink_session == nil, "background handoff must retire the session")
assert(#starts == started_before and stops == stopped_before, "suspended checkpoint must not touch the released daemon")
local pending = scheduled
scheduled = {}
for _, action in ipairs(pending) do action() end
assert(#starts == started_before, "retired watchers must not reattach background ink")
print("KOReader page-scoped ink lifecycle smoke passed")

-- A failed annotation load must not attach the daemon or display another book's cached ink.
local store = require("inkstore")
local original_annotations = store.annotations
store.annotations = function() return nil, "Saved ink annotations contain invalid JSON" end
plugin.ink_mode, plugin.ink_session = nil, nil
local before_starts, before_notices, before_scheduled = #starts, #notices, #scheduled
plugin:onReaderReady()
assert(plugin.ink_annotations == nil and plugin.ink_annotation_index == nil)
assert(#notices == before_notices + 1 and notices[#notices]:find("preserved", 1, true))
assert(not plugin:startInk("full-page"))
assert(plugin.ink_mode == nil and #starts == before_starts and #scheduled == before_scheduled)
assert(#notices == before_notices + 2)
store.annotations = original_annotations
assert(plugin:startInk("full-page"), "restored annotations must permit a later handwriting session")
print("KOReader corrupt-sidecar reader guard passed")

-- Initial capability negotiation must precede every reader/input mutation.
local bridge = require("androidbridge")
local registrations, hooks = 0, 0
local function host()
    return setmetatable({ui = {
        menu = {registerToMainMenu = function() registrations = registrations + 1 end},
        view = {registerViewModule = function() registrations = registrations + 1 end},
        document = {},
    }, installPenSuppression = function() hooks = hooks + 1 end,
       activatePenSuppression = function() hooks = hooks + 1 end}, {__index = plugin})
end
for _, response in ipairs({false, true, "legacy", {}, {ok=true}, {ok=true,apiVersion=2,inkAvailable=true},
    {ok=true,apiVersion=1,inkAvailable=false}}) do
    device.isAndroid = function() return true end
    bridge.ping = function() return response end
    local unsupported = host()
    unsupported:init();unsupported:onReaderReady();unsupported:addToMainMenu({})
    assert(unsupported.ink_available == false and registrations == 0 and hooks == 0)
end
bridge.ping = function() error("missing JNI bridge") end
local absent = host();absent:init()
assert(not absent.ink_available and registrations == 0 and hooks == 0)
device.isAndroid = function() return false end
local non_android = host();non_android:init()
assert(not non_android.ink_available and registrations == 0 and hooks == 0)
device.isAndroid = function() return true end
bridge.ping = function() return {ok=true,apiVersion=1,inkAvailable=true} end
local supported = host();supported:init()
assert(supported.ink_available and registrations == 2 and hooks == 2)
print("KOReader unsupported-device/bridge capability scenarios passed")

-- Input ownership composes with earlier/later plugins and lasts through the gesture boundary.
local previous_calls = 0
local previous = function() previous_calls = previous_calls + 1;return true,2 end
local installed = previous
local backend = {getMotionEventFilter=function() return installed end,
    setMotionEventFilter=function(callback) installed=callback end}
device.input = {input=backend}
package.preload.android = function() return {lib={
    AInputEvent_getDeviceId=function(event) return event.device end,
    AMotionEvent_getAction=function(event) return event.action end,
}} end
bridge.isPenInputDevice = function(id) return id==99 end
plugin.ink_mode=nil
local owner=setmetatable({ink_mode={},pen_input_installed=false}, {__index=plugin})
plugin.activatePenSuppression(owner)
local ours=installed
local consumed,tool=ours({device=1,action=0})
assert(consumed and tool==2 and previous_calls==1, "finger events must reach the previous owner")
assert(ours({device=99,action=0})==true)
owner.ink_mode=nil
assert(ours({device=99,action=2})==true and ours({device=99,action=1})==true,
    "closing writing must not release the pen's UP to navigation")
local reading,pen=ours({device=99,action=0})
assert(reading==false and pen==1)
owner.ink_mode={}
assert(ours({device=99,action=2})==false, "a reading gesture retains ownership until its boundary")
assert(ours({device=99,action=3})==false)
assert(ours({device=99,action=0})==true)
assert(ours({device=99,action=3})==true)
local later=function(event) return ours(event) end
installed=later
plugin.deactivatePenSuppression(owner)
assert(installed==later, "closing must not overwrite a later plugin's hook")
assert(later({device=1,action=0})==true and previous_calls==2,
    "closed wrappers must safely delegate rather than access cleared caches")
print("KOReader input hook composition and gesture ownership scenarios passed")

local original_taps,sticky_opens=0,0
local highlight={ui={annotation={annotations={{kalamosSticky={id='saved-sticky'}}}}},
    showHighlightNoteOrDialog=function() original_taps=original_taps+1;return 'stock' end}
local sticky_owner=setmetatable({ui={highlight=highlight},
    openStickyEditor=function() sticky_opens=sticky_opens+1 end},{__index=plugin})
plugin.installStickyHighlightTap(sticky_owner)
local sticky_wrapper=highlight.showHighlightNoteOrDialog
assert(sticky_wrapper(highlight,1)==true and sticky_opens==1)
local later_highlight=function(...) return sticky_wrapper(...) end
highlight.showHighlightNoteOrDialog=later_highlight
plugin.restoreStickyHighlightTap(sticky_owner)
assert(highlight.showHighlightNoteOrDialog==later_highlight)
assert(later_highlight(highlight,1)=='stock' and original_taps==1 and sticky_opens==1)
print('KOReader sticky-highlight wrapper composition check passed')
