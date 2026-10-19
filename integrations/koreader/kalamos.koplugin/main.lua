local AndroidBridge = require("androidbridge")
local InkStore = require("inkstore")
local InkTools = require("inktools")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

-- Last-resort ownership for teardown paths that bypass the ordinary close guard.
-- Disk failure cannot guarantee process-death durability; preserve the batch across book close.
local recoveries = {}

local KALAMOS_SELECTION_COLOR = "#FF8800"
local KALAMOS_STICKY_HIGHLIGHT_COLOR = "blue"

local Kalamos = WidgetContainer:extend{
    name = "kalamos",
    is_doc_only = true,
    ink_session = nil,
    ink_mode = nil,
    ink_generation = 0,
    ink_watch_generation = 0,
}

local KALAMOS_MENU_IDS = { "kalamos_handwriting" }

local function ensureKalamosMenuOrder()
    local order = require("ui/elements/reader_menu_order")
    local buttons = order["KOMenu:menu_buttons"]
    local found = false
    local tools_index = #buttons
    for index, id in ipairs(buttons) do
        if id == "kalamos" then found = true end
        if id == "tools" then tools_index = index end
    end
    if not found then table.insert(buttons, tools_index + 1, "kalamos") end
    order.kalamos = KALAMOS_MENU_IDS
end

local function message(text)
    UIManager:show(InfoMessage:new{ text = text })
end

local function callPenHighlight(highlight, method, gesture)
    -- Pen selection is an explicit Kalamos mode and must still work when KOReader's generic
    -- finger long-press action is configured as "Do nothing".
    local disabled = highlight.view.highlight.disabled
    highlight.view.highlight.disabled = false
    local ok, result = pcall(highlight[method], highlight, nil, gesture)
    highlight.view.highlight.disabled = disabled
    if not ok then error(result) end
    return result
end

function Kalamos:init()
    -- Probe before installing hooks or changing reader/highlight state. Stock KOReader and
    -- unsupported devices must retain their normal input, menus and selection colors.
    self.ink_available = false
    if not Device:isAndroid() then return end
    local called, result, err = pcall(AndroidBridge.ping)
    if not called or type(result) ~= "table" or not result.ok or result.apiVersion ~= 1 or not result.inkAvailable then
        logger.warn("Kalamos handwriting unavailable:", err or type(result) == "table" and result.err or "unsupported bridge/device")
        return
    end
    local configured_root = G_reader_settings and G_reader_settings:readSetting("kalamos_ink_directory")
    local configured, config_err = InkStore.configure(configured_root)
    if not configured then
        message(_("Handwriting storage could not be configured.") .. "\n" .. tostring(config_err))
        return
    end
    self.motion_forwarding = result.motionForwarding == true
    self.ink_available = true
    logger.warn("Kalamos JNI bridge ready via", result.activity)
    self.ui.menu:registerToMainMenu(self)
    self:installWritingCloseGuard()
    self:installWritingLayoutGuard()
    if self.document and self.ui.highlight then
        self:addToHighlightDialog()
        self:installStickyHighlightTap()
    end
    if self.ui.view and self.ui.view.registerViewModule then
        self.ui.view:registerViewModule("kalamos_saved_ink", self)
    end
    self:installPenSuppression()
    self:activatePenSuppression()
end

function Kalamos:installWritingCloseGuard()
    if self.close_guard or not self.ui.onClose then return end
    local previous = self.ui.onClose
    self.previous_close = previous
    self.close_guard = function(ui, ...)
        local resume = self.resume_page_writing
        if self.writing_spaces then self.writing_spaces:cancelPreview() end
        self.resume_page_writing = nil
        if self.ink_mode and not self:finishInk(true) then
            self.resume_page_writing = resume
            return true -- Keep the book and pending batch alive until Save succeeds.
        end
        return previous(ui, ...)
    end
    self.ui.onClose = self.close_guard
end

function Kalamos:setPenSelectionColor()
    local document = self.ui and self.ui.document
    local engine = document and document._document
    if self.ui and self.ui.rolling and engine and engine.setStringProperty then
        engine:setStringProperty("crengine.highlight.selection.color", KALAMOS_SELECTION_COLOR)
    end
end

function Kalamos:installPenSuppression()
    local input = Device.input
    if Kalamos.pen_gesture_hook_installed or not input or
        not input.registerGestureAdjustHook then return end
    Kalamos.pen_gesture_hook_installed = true
    input:registerGestureAdjustHook(function(_, gesture)
        local owner = Kalamos.pen_suppression_owner
        if owner and owner:handleReadingPenGesture(gesture) then
            gesture.ges = "none"
        elseif owner and (owner.pending_canvas_start or owner.ink_mode) and AndroidBridge.isPenInputActive() then
            logger.warn("Kalamos suppressed mirrored pen gesture", tostring(gesture.ges))
            gesture.ges = "none"
        end
    end)
end

function Kalamos:handleReadingPenGesture(gesture)
    if self.pending_canvas_start or self.ink_mode or not (self.pen_contact_active or self.pen_release_pending) then
        return false
    end

    local name = gesture.ges
    if name == "tap" and gesture.pos and self.writing_spaces then
        Device.input.gesture_detector:adjustGesCoordinate(gesture)
        for _, space in ipairs(self.writing_spaces.saved.spaces) do
            local bounds = self.writing_spaces:bounds(space)
            local p = gesture.pos
            if bounds and p.x >= bounds.left and p.x <= bounds.right and p.y >= bounds.top and p.y <= bounds.bottom then
                self.pen_release_pending = false
                self:writeInSpace(space.id)
                return true
            end
        end
    end
    local highlight = self.ui and self.ui.highlight
    if name == "tap" and highlight and highlight.highlight_dialog then
        -- The pen may operate the one UI it was allowed to open: the text-selection popup.
        self.pen_release_pending = false
        return false
    end

    local function beginSelection(pos)
        if not (highlight and pos) then return false end
        self:setPenSelectionColor()
        local selection_gesture = { pos = pos }
        local page_pos = self.ui.view:screenToPageTransform(pos)
        local ok, word = false
        if page_pos then
            ok, word = pcall(self.ui.document.getWordFromPosition, self.ui.document, page_pos)
        end
        self.pen_selection_active = ok and word and
            callPenHighlight(highlight, "onHold", selection_gesture) == true
        logger.warn(self.pen_selection_active and "Kalamos pen text selection started"
            or "Kalamos ignored pen hold outside text")
        return self.pen_selection_active
    end
    local function extendSelection(pos)
        if self.pen_selection_active and highlight and pos then
            callPenHighlight(highlight, "onHoldPan", { pos = pos })
        end
    end
    local function finishSelection()
        if not (self.pen_selection_active and highlight) then return end
        -- Always show the selection menu for pen selection. This avoids the configurable
        -- single-word dictionary action and provides the handwritten sticky-note command.
        highlight.long_hold_reached = true
        highlight:onHoldRelease()
        self.pen_selection_active = false
    end

    if name == "hold" and gesture.pos then
        -- Gesture handlers normally receive screen-adjusted coordinates. We invoke the text
        -- selection module directly so this pen gesture cannot reach links, images, touch zones,
        -- menus, or page navigation.
        Device.input.gesture_detector:adjustGesCoordinate(gesture)
        beginSelection(gesture.pos)
    elseif name == "hold_pan" then
        Device.input.gesture_detector:adjustGesCoordinate(gesture)
        extendSelection(gesture.pos)
    elseif name == "hold_release" then
        finishSelection()
    elseif name == "pan" then
        -- A pen stroke across text is selection too; it must never become reader scrolling.
        Device.input.gesture_detector:adjustGesCoordinate(gesture)
        if not self.pen_selection_active then beginSelection(gesture.start_pos or gesture.pos) end
        extendSelection(gesture.pos)
    elseif name == "pan_release" then
        finishSelection()
    elseif name == "swipe" then
        -- Very quick strokes may be recognized directly as a swipe without an intermediate pan.
        Device.input.gesture_detector:adjustGesCoordinate(gesture)
        if beginSelection(gesture.pos) then extendSelection(gesture.end_pos or gesture.pos) end
        finishSelection()
    else
        logger.warn("Kalamos suppressed non-selection pen gesture", tostring(name))
    end

    if self.pen_release_pending and not self.pen_contact_active then
        self.pen_release_pending = false
        if name ~= "hold_release" then self.pen_selection_active = false end
    end
    return true
end

function Kalamos:activatePenSuppression()
    local input = Device.input
    Kalamos.pen_suppression_owner = self
    if self.pen_input_installed or not input then return end
    self.pen_input_installed = true

    -- Bigme reports fts_ts_pen contacts as Android TOOL_TYPE_FINGER. Claim that dedicated input
    -- device in KOReader's native queue before it can become a tap, hold, selection, or swipe.
    local backend = input.input
    if backend and backend.setMotionEventFilter then
        local android = require("android")
        self.previous_motion_filter = backend.getMotionEventFilter and backend.getMotionEventFilter()
        self.pen_input_devices = {}
        self.pen_claimed_devices = {}
        local previous_filter = self.previous_motion_filter
        local function delegate(event)
            if previous_filter then return previous_filter(event) end
            return false
        end
        self.pen_motion_filter = function(event)
            -- A later plugin may still wrap this closure after our reader closes.
            if not self.pen_input_installed then return delegate(event) end
            local device_id = tonumber(android.lib.AInputEvent_getDeviceId(event))
            local is_pen = self.pen_input_devices[device_id]
            if is_pen == nil then
                is_pen = AndroidBridge.isPenInputDevice(device_id)
                self.pen_input_devices[device_id] = is_pen
                logger.warn("Kalamos classified Android input device", device_id,
                    is_pen and "as pen" or "as touch")
            end
            -- Generic devices may report finger + pen through the same input device. Classify the
            -- contact itself; never turn a finger into a pen merely because its device has a stylus.
            if self.motion_forwarding then is_pen = tonumber(android.lib.AMotionEvent_getToolType(event, 0)) == 2 end
            if not is_pen then return delegate(event) end
            -- Full-page handwriting belongs exclusively to the low-latency Bigme surface.
            -- In normal reading, preserve the event but correct Bigme's TOOL_TYPE_FINGER report
            -- so KOReader sends it through the stylus callback and the restricted selection path.
            local action = tonumber(android.lib.AMotionEvent_getAction(event)) % 256
            local claimed = self.pen_claimed_devices[device_id]
            if action == 0 or claimed == nil then claimed = self.pending_canvas_start ~= nil or self.ink_mode ~= nil end
            self.pen_claimed_devices[device_id] = claimed
            if action == 1 or action == 3 then self.pen_claimed_devices[device_id] = nil end
            -- Own the complete gesture through UP/CANCEL even if the writing tool closes first.
            if claimed then
                if self.motion_forwarding then
                    require("penmotion").forward(android.lib, event, AndroidBridge)
                end
                return true
            end
            return false, 1
        end
        backend.setMotionEventFilter(self.pen_motion_filter)
        logger.warn("Kalamos native pen motion filter installed")
    end

    if input.registerStylusCallback then
        self.previous_stylus_callback = input.stylus_callback
        self.pen_suppression_callback = function(_, slot)
            local down = slot.id and slot.id >= 0
            if self.pending_canvas_start or self.ink_mode then
                if down and not self.pen_callback_down then
                    logger.warn("Kalamos consuming KOReader stylus contact", tostring(slot.slot),
                        "tool", tostring(slot.tool))
                end
                self.pen_callback_down = down
                return true
            end
            if down and not self.pen_contact_active then
                logger.warn("Kalamos routing KOReader stylus contact to text selection", tostring(slot.slot),
                    "tool", tostring(slot.tool))
            end
            self.pen_contact_active = down
            if not down then self.pen_release_pending = true end
            return false
        end
        input:registerStylusCallback(self.pen_suppression_callback)
    end
end

function Kalamos:deactivatePenSuppression()
    local input = Device.input
    local backend = input and input.input
    if backend and backend.getMotionEventFilter and
        backend.getMotionEventFilter() == self.pen_motion_filter then
        backend.setMotionEventFilter(self.previous_motion_filter)
    end
    self.previous_motion_filter = nil
    self.pen_motion_filter = nil
    self.pen_input_devices = nil
    self.pen_claimed_devices = nil
    if input and input.stylus_callback == self.pen_suppression_callback then
        if self.previous_stylus_callback then
            input:registerStylusCallback(self.previous_stylus_callback)
        elseif input.unregisterStylusCallback then
            input:unregisterStylusCallback()
        end
    end
    self.previous_stylus_callback = nil
    self.pen_suppression_callback = nil
    self.pen_input_installed = false
    self.pen_callback_down = false
    self.pen_contact_active = false
    self.pen_release_pending = false
    self.pen_selection_active = false
    if Kalamos.pen_suppression_owner == self then Kalamos.pen_suppression_owner = nil end
end

function Kalamos:addToHighlightDialog()
    self:installCompactSelection()
    self.ui.highlight:addToHighlightDialog("08_kalamos_handwritten_sticky", function(highlight, index)
        return {
            text = _("Handwritten sticky note"),
            callback = function()
                self:makeStickyHighlight(highlight, index)
            end,
        }
    end)
    self.ui.highlight:addToHighlightDialog("09_kalamos_writing_space", function(highlight, index)
        return { text = _("Insert writing space after paragraph"),
            enabled = self.ui.rolling ~= nil,
            callback = function()
                local item = index and self.ui.annotation.annotations[index] or highlight.selected_text
                local anchor = item and item.pos0
                if type(anchor) ~= "string" then return end
                highlight:onClose()
                UIManager:tickAfterNext(function() self:editWritingSpace(nil, anchor) end)
            end }
    end)
end

function Kalamos:makeStickyHighlight(highlight, index)
    local sticky_id = "sticky-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
    local item
    if index then
        item = self.ui.annotation.annotations[index]
        if not item then return end
        highlight:writePdfAnnotation("delete", item)
        item.drawer = "lighten"
        item.color = KALAMOS_STICKY_HIGHLIGHT_COLOR
        highlight:writePdfAnnotation("save", item)
    else
        if not highlight.selected_text then return end
        highlight.selected_text.drawer = "lighten"
        highlight.selected_text.color = KALAMOS_STICKY_HIGHLIGHT_COLOR
        index = highlight:saveHighlight()
        item = index and self.ui.annotation.annotations[index]
        if not item then return end
    end
    item.kalamosSticky = { schema = "kalamos.handwritten-sticky/v1", id = sticky_id }
    if self.creating_placement_sticky then self.new_placement_sticky = sticky_id end
    self.ui:handleEvent(Event:new("AnnotationsModified", { item, index_modified = index }))
    logger.warn("Kalamos sticky anchor saved", sticky_id, "annotation", tostring(index))
    highlight:onClose()
    UIManager:setDirty(self.ui.dialog, "ui")
    -- Close KOReader's selection dialog first, then replace it with the bounded writing canvas.
    -- The saved highlight remains the durable anchor and can reopen the same canvas later.
    UIManager:tickAfterNext(function()
        self:openStickyEditor(item)
    end)
end

function Kalamos:installStickyHighlightTap()
    local highlight = self.ui.highlight
    if self.sticky_highlight_tap or not highlight.showHighlightNoteOrDialog then return end
    local previous = highlight.showHighlightNoteOrDialog
    self.previous_highlight_tap = previous
    local wrapper
    wrapper = function(this, index)
        -- A later plugin may retain this wrapper after our reader hook has been retired.
        if self.sticky_highlight_tap ~= wrapper then return previous(this, index) end
        local item = this.ui.annotation.annotations[index]
        if item and item.kalamosSticky and item.kalamosSticky.id then
            self:openStickyEditor(item)
            return true
        end
        return previous(this, index)
    end
    self.sticky_highlight_tap = wrapper
    highlight.showHighlightNoteOrDialog = wrapper
end

function Kalamos:restoreStickyHighlightTap()
    local highlight = self.ui and self.ui.highlight
    if highlight and highlight.showHighlightNoteOrDialog == self.sticky_highlight_tap then
        highlight.showHighlightNoteOrDialog = self.previous_highlight_tap
    end
    self.previous_highlight_tap = nil
    self.sticky_highlight_tap = nil
end

function Kalamos:book()
    local book, err = InkStore.current(self.ui)
    if not book then message(err); return nil end
    return book
end

function Kalamos:target(node)
    if node and node.wholeBook then return {} end
    if node then
        return { nodeId = node.id, label = node.title, page = node.page, fragment = node.xpointer }
    end
    local page = self.ui and self.ui.getCurrentPage and self.ui:getCurrentPage()
    return { page = type(page) == "number" and math.max(0, page - 1) or nil,
        fragment = self.ui and self.ui.document and self.ui.document.getXPointer and self.ui.document:getXPointer() or nil }
end

function Kalamos:inkTarget()
    local target = self:target()
    local document = self.ui and self.ui.document
    target.position = document and document.getCurrentPos and document:getCurrentPos() or nil
    -- Fixed-layout documents are visually page-scoped. Reflowable EPUB views may advance through
    -- XPointer/scroll positions while ReaderUI:getCurrentPage() retains the same coarse page value.
    if self.ui and self.ui.paging and target.page ~= nil then
        target.viewKey = "page:" .. tostring(target.page)
    elseif target.fragment then
        target.viewKey = "fragment:" .. tostring(target.fragment)
    elseif target.position ~= nil then
        target.viewKey = "position:" .. tostring(target.position)
    elseif target.page ~= nil then
        target.viewKey = "page:" .. tostring(target.page)
    end
    -- New direct-page ink is replayed only on its original rendered layout. A view key alone
    -- cannot distinguish font/margin/viewport changes. Legacy marks retain their old behavior.
    if document and document.getDocumentRenderingHash then
        local scoped_space = self.pending_canvas_start and self.pending_canvas_start.id
            or self.ink_mode and self.ink_mode.kind == "space" and self.ink_mode.target and self.ink_mode.target.spaceId
        local viewport = tostring(Device.screen:getWidth()) .. "x" .. tostring(Device.screen:getHeight())
        target.engineLayout = tostring(document:getDocumentRenderingHash(true)) .. ":" .. viewport
        target.layout = target.engineLayout
        local native = document._document
        if scoped_space then
            -- Canvas vectors are local to this space. A whole-DOM fingerprint both
            -- delays entry and lets unrelated chapter render hashes retire capture.
            local spaces = self.writing_spaces
            local space = spaces and spaces.find and spaces:find(scoped_space)
            local info = space and spaces.info and spaces:info(space.anchor)
            local geometry = info and info.left and info.top and info.right and info.bottom and
                table.concat({info.left, info.top, info.right, info.bottom,
                tostring(info.visible)}, ":") or "unavailable"
            target.layout = "canvas-v1:" .. scoped_space .. ":" ..
                tostring(spaces and spaces.layout_revision or 0) .. ":" .. viewport .. ":" .. geometry
        elseif native and native.getWritingLayoutHash then
            self.layout_fingerprints = self.layout_fingerprints or {}
            local stable = self.layout_fingerprints[target.engineLayout]
            if not stable then
                stable = "writing-v1:" .. tostring(native:getWritingLayoutHash()) .. ":" .. viewport
                self.layout_fingerprints[target.engineLayout] = stable
            end
            target.layout = stable
            local settings = self.ui.doc_settings
            if not self.ink_layout_aliases then
                self.ink_layout_aliases = settings and settings.readSetting and settings:readSetting("kalamos_ink_layout_aliases") or {}
            end
            if self.ink_layout_aliases[target.engineLayout] ~= stable then
                self.ink_layout_aliases[target.engineLayout] = stable
                if settings and settings.saveSetting then settings:saveSetting("kalamos_ink_layout_aliases", self.ink_layout_aliases) end
            end
            target.compatibleLayouts = {stable}
            for previous, fingerprint in pairs(self.ink_layout_aliases) do
                if fingerprint == stable then target.compatibleLayouts[#target.compatibleLayouts + 1] = previous end
            end
        end
    end
    target.legacyCompatible = (not self.writing_spaces or
        self.writing_spaces.original_view and #(self.writing_spaces.original_layout or {}) == 0 or
        not self.writing_spaces.original_view and #self.writing_spaces.saved.spaces == 0)
        and (not self.legacy_layout or self.legacy_layout == target.layout or self.legacy_layout == target.engineLayout
            or self.ink_layout_aliases and self.ink_layout_aliases[self.legacy_layout] == target.layout)
    if self.writing_spaces and self.writing_spaces.layoutSnapshot then
        -- Store the geometry recipe with new page ink so later canvas resizes can
        -- recover its original layout without rewriting or guessing its vectors.
        target.canvasLayout = self.writing_spaces:layoutSnapshot()
    end
    return target
end

function Kalamos:inkBounds(kind, strokes, page_transition, requested_bounds)
    local width, height = Device.screen:getWidth(), Device.screen:getHeight()
    local margin = kind == "sticky" and math.floor(math.min(width, height) * 0.12) or 0
    local bounds = requested_bounds or (kind == "sticky"
        and { left = margin, top = math.floor(height * 0.25), right = width - margin, bottom = math.floor(height * 0.72) }
        or { left = 0, top = 0, right = width, bottom = height })
    bounds.width = 5
    bounds.toolBar = true
    bounds.context = kind
    bounds.originalInkAvailable = self:hasPageInk() and self.writing_spaces ~= nil
        and #self.writing_spaces.saved.spaces > 0
    bounds.originalInkView = self.writing_spaces and self.writing_spaces.original_view == true or false
    bounds.stickyHeader = kind == "sticky" and self.sticky_widget and self.sticky_widget.getHeaderBounds and self.sticky_widget:getHeaderBounds() or nil
    bounds.canvasAvailable = self.ui.rolling and self.writing_spaces and self.writing_spaces:supported() and true or false
    bounds.initialTool = self.ink_mode and self.ink_mode.initial_tool
    bounds.strokes = strokes or {}
    bounds.pageTransition = page_transition == true
    bounds.selection = nil
    return bounds
end

local function annotationKey(kind, anchor)
    anchor = anchor or {}
    if kind == "sticky" and anchor.stickyId then
        return kind .. "\0sticky\0" .. tostring(anchor.stickyId)
    end
    if kind == "full-page" and anchor.layout then kind = kind .. "\0layout:" .. anchor.layout end
    if anchor.viewKey then return kind .. "\0view\0" .. tostring(anchor.viewKey) end
    if anchor.page ~= nil then return kind .. "\0page\0" .. tostring(anchor.page) end
    if anchor.fragment then return kind .. "\0fragment\0" .. tostring(anchor.fragment) end
end

local function indexAnnotations(document)
    local index = {}
    for _, entry in ipairs(document.entries or {}) do
        local key = annotationKey(entry.kind, entry.anchor)
        if key then
            local bucket = index[key] or {}
            index[key] = bucket
            for _, stroke in ipairs(entry.strokes or {}) do bucket[#bucket + 1] = stroke end
        end
    end
    return index
end

local function paintStroke(bb, offset_x, offset_y, stroke, width)
    local points = InkTools.points(stroke)
    if #points == 0 then return end
    local base_width = stroke.width or width or 5
    local argb = stroke.color or -16777216
    if argb < 0 then argb = argb + 4294967296 end
    local red = math.floor(argb / 65536) % 256
    local green = math.floor(argb / 256) % 256
    local blue = argb % 256
    local alpha = math.floor(255 * (stroke.opacity or 1))
    local color = bb:getInverse() == 1 and Blitbuffer.COLOR_WHITE or
        Blitbuffer.colorFromString(string.format("#%02X%02X%02X%02X", red, green, blue, alpha))
    local previous = points[1]
    local function dot(point_x, point_y, pressure)
        local actual_width = stroke.pen == "Brush" and
            base_width * (0.3 + 1.7 * math.max(0, math.min(1, pressure or 0.5))) or base_width
        local radius = math.max(1, math.floor(actual_width / 2))
        local cx, cy = math.floor(offset_x + point_x + 0.5), math.floor(offset_y + point_y + 0.5)
        if alpha < 255 then
            local bw, bh = bb:getWidth(), bb:getHeight()
            for dy = -radius, radius do
                for dx = -radius, radius do
                    if dx * dx + dy * dy <= radius * radius and
                        cx + dx >= 0 and cy + dy >= 0 and cx + dx < bw and cy + dy < bh then
                        bb:setPixelBlend(cx + dx, cy + dy, color)
                    end
                end
            end
        else
            bb:paintCircle(cx, cy, radius, color)
        end
    end
    dot(previous[1], previous[2], previous[3])
    for index = 2, #points do
        local point = points[index]
        local dx, dy = point[1] - previous[1], point[2] - previous[2]
        local distance = math.sqrt(dx * dx + dy * dy)
        local steps = math.max(1, math.ceil(distance / math.max(1, base_width / 2)))
        for step = 1, steps do
            local ratio = step / steps
            local pressure = (previous[3] or 0.5) + ((point[3] or 0.5) - (previous[3] or 0.5)) * ratio
            dot(previous[1] + dx * ratio, previous[2] + dy * ratio, pressure)
        end
        previous = point
    end
end

function Kalamos:strokesForTarget(kind, target)
    local mode = self.ink_mode
    local index = mode and mode.annotation_index or self.ink_annotation_index or {}
    if kind == "space" then return mode and mode.space_strokes or {} end
    local strokes, keys = {}, {}
    local original_kind = kind
    if kind == "sticky" and target.stickyId then
        keys[1] = kind .. "\0sticky\0" .. tostring(target.stickyId)
    else
        local layouts = kind == "full-page" and target.layout and (target.compatibleLayouts or {target.layout}) or {false}
        for _, layout in ipairs(layouts) do
            local scoped = layout and kind .. "\0layout:" .. layout or kind
            if target.viewKey then keys[#keys + 1] = scoped .. "\0view\0" .. tostring(target.viewKey) end
            if target.page ~= nil then keys[#keys + 1] = scoped .. "\0page\0" .. tostring(target.page) end
            if target.fragment then keys[#keys + 1] = scoped .. "\0fragment\0" .. tostring(target.fragment) end
        end
    end
    if original_kind == "full-page" and target.layout and target.legacyCompatible then
        if target.viewKey then keys[#keys + 1] = original_kind .. "\0view\0" .. target.viewKey end
        if target.page ~= nil then keys[#keys + 1] = original_kind .. "\0page\0" .. tostring(target.page) end
        if target.fragment then keys[#keys + 1] = original_kind .. "\0fragment\0" .. target.fragment end
    end
    for _, key in ipairs(keys) do
        for _, stroke in ipairs(index[key] or {}) do strokes[#strokes + 1] = stroke end
    end
    return strokes
end

function Kalamos:paintTo(bb, x, y)
    -- The daemon surface is authoritative while editing. Outside handwriting mode, this view
    -- module keeps saved vector strokes visible as part of KOReader's normal page repaint.
    if self.writing_spaces and not self.writing_spaces.original_view then
        for _, space in ipairs((self.writing_spaces.preview_document or self.writing_spaces.saved).spaces) do
            local marker = self:spaceMarker(space)
            if marker then
                bb:paintRect(x + marker.left, y + marker.top, marker.right - marker.left, 2, Blitbuffer.COLOR_BLACK)
                bb:paintRect(x + marker.left, y + marker.top, 2, marker.bottom - marker.top, Blitbuffer.COLOR_BLACK)
                bb:paintRect(x + marker.right - 2, y + marker.top, 2, marker.bottom - marker.top, Blitbuffer.COLOR_BLACK)
                bb:paintRect(x + marker.left, y + marker.bottom - 2, marker.right - marker.left, 2, Blitbuffer.COLOR_BLACK)
            end
            local bounds = self.writing_spaces:bounds(space)
            if bounds then
                -- Paper boundary stays visible while its native writer owns the live ink.
                local edge = Blitbuffer.COLOR_BLACK
                local thickness = Device.screen.scaleBySize and Device.screen:scaleBySize(2) or 3
                thickness = math.max(3, math.floor(thickness))
                local width, height = bounds.right - bounds.left, bounds.bottom - bounds.top
                bb:paintRect(x + bounds.left, y + bounds.top, width, thickness, edge)
                bb:paintRect(x + bounds.left, y + bounds.bottom - thickness, width, thickness, edge)
                bb:paintRect(x + bounds.left, y + bounds.top, thickness, height, edge)
                bb:paintRect(x + bounds.right - thickness, y + bounds.top, thickness, height, edge)
                local grip_width = math.min(80, math.floor(width * .2))
                bb:paintRect(x + math.floor((bounds.left + bounds.right - grip_width) / 2),
                    y + bounds.bottom - thickness - 3, grip_width, thickness + 3, edge)
            end
            if bounds and not (self.ink_mode and self.ink_mode.kind == "space" and
                self.ink_session and self.ink_session.target.spaceId == space.id) then
                bb:paintRect(x + bounds.left, y + bounds.top, 8, 3, Blitbuffer.COLOR_BLACK)
                for _, stroke in ipairs(self.writing_spaces:strokes(space, bounds, false)) do
                    paintStroke(bb, x, y, stroke, 5)
                end
            end
        end
    end
    if self.ink_mode and self.ink_mode.kind == "full-page" or not self.ink_annotation_index then return end
    local target = self:inkTarget()
    for _, stroke in ipairs(self:strokesForTarget("full-page", target)) do
        paintStroke(bb, x, y, stroke, 5)
    end
end

function Kalamos:showSavedInk()
    if self.ui and self.ui.view then UIManager:setDirty(self.ui.view, "partial") end
end

function Kalamos:indexInkEntry(entry)
    local mode = self.ink_mode
    local key = mode and annotationKey(entry.kind, entry.anchor)
    if not key then return end
    local bucket = mode.annotation_index[key] or {}
    mode.annotation_index[key] = bucket
    for _, stroke in ipairs(entry.strokes or {}) do bucket[#bucket + 1] = stroke end
end

function Kalamos:removeIndexedInkEntry(entry)
    local mode = self.ink_mode
    local key = mode and annotationKey(entry.kind, entry.anchor)
    local bucket = key and mode.annotation_index[key]
    if not bucket then return end
    for _ = 1, #(entry.strokes or {}) do bucket[#bucket] = nil end
    if #bucket == 0 then mode.annotation_index[key] = nil end
end

function Kalamos:loadInkAnnotations(book_id)
    local document, err = InkStore.annotations(book_id)
    if not document then
        self.ink_book_id, self.ink_annotations, self.ink_annotation_index = nil, nil, nil
        return nil, err
    end
    document.entries = document.entries or {}
    local index = indexAnnotations(document)
    self.ink_book_id = book_id
    self.ink_annotations = document
    self.ink_annotation_index = index
    return document, index
end

function Kalamos:attachInkPage(target, page_transition)
    local mode = self.ink_mode
    if not mode or self.ink_session then return end
    local strokes = self:strokesForTarget(mode.kind, target)
    if mode.pending_batch then
        for _, stroke in ipairs(mode.pending_batch.strokes or {}) do strokes[#strokes + 1] = stroke end
    end
    logger.warn("Kalamos ink attach", tostring(target.viewKey), "replay strokes", #strokes)
    local result, err = AndroidBridge.startInk(self:inkBounds(mode.kind, strokes,
        page_transition, mode.bounds))
    if not result or result.err then
        self.ink_mode = nil
        self:closeStickyEditor()
        self:showSavedInk()
        message(err or result and result.err or _("Bigme pen engine unavailable"))
        return
    end
    self.ink_session = { kind = mode.kind, book = mode.book, target = target }
    mode.pending_view_key, mode.initial_tool = nil, nil
end

function Kalamos:scheduleInkPage(target, page_transition)
    self.ink_generation = self.ink_generation + 1
    local generation = self.ink_generation
    local mode = self.ink_mode
    if mode then mode.pending_view_key = target and target.viewKey end
    -- Cross the pending repaint boundary, then require the rendered view anchor to remain stable
    -- across two samples. Reflowed documents may publish an intermediate XPointer while settling.
    local last_view_key, stable_samples
    local function attachWhenStable()
        if not self.ink_mode or self.ink_generation ~= generation then return end
        local current = self:inkTarget()
        if current.viewKey then
            current.selectionText = target and target.selectionText
            current.selectionFragment = target and target.selectionFragment
            current.stickyId = target and target.stickyId
            current.spaceId = target and target.spaceId
            target = current
        end
        local view_key = target and target.viewKey
        if stable_samples == nil or view_key ~= last_view_key then
            last_view_key, stable_samples = view_key, 1
        else
            stable_samples = stable_samples + 1
        end
        if stable_samples < 2 then
            UIManager:scheduleIn(0.05, attachWhenStable)
            return
        end
        self:attachInkPage(target, page_transition)
    end
    UIManager:tickAfterNext(attachWhenStable)
end

function Kalamos:startInkPageWatch()
    self.ink_watch_generation = self.ink_watch_generation + 1
    local generation = self.ink_watch_generation
    local checkpoint_ticks = 0
    local function poll()
        if not self.ink_mode or self.ink_watch_generation ~= generation then return end
        if self.ink_session then
            local current = self:inkTarget()
            local active = self.ink_session.target or {}
            local changed = current.viewKey and (current.viewKey ~= active.viewKey or current.layout ~= active.layout)
            if changed then
                logger.warn("Kalamos ink watcher view change", tostring(active.viewKey), "to", tostring(current.viewKey))
                self:changeInkPage(current.page and current.page + 1 or nil)
            else
                checkpoint_ticks = checkpoint_ticks + 1
                if checkpoint_ticks >= 5 then
                    checkpoint_ticks = 0
                    self:checkpointInkPage()
                end
            end
        end
        UIManager:scheduleIn(0.10, poll)
    end
    UIManager:scheduleIn(0.10, poll)
end

function Kalamos:appendInkStrokes(session, strokes)
    if #strokes == 0 then return true end
    local mode = self.ink_mode
    if session.kind == "space" then
        local before = InkTools.copy(mode.space_strokes)
        local next_strokes = InkTools.copy(before)
        for _, stroke in ipairs(strokes) do next_strokes[#next_strokes + 1] = stroke end
        local ok, err = self:replaceInkPage(session, next_strokes)
        if not ok then return nil, err end
        mode.undo[#mode.undo + 1] = before; mode.redo = {}; mode.selection = {}
        return true
    end
    local old_undo, old_redo, old_selection
    if mode then
        old_undo, old_redo, old_selection = InkTools.copy(mode.undo), InkTools.copy(mode.redo), InkTools.copy(mode.selection)
        local before = InkTools.copy(self:strokesForTarget(session.kind, session.target))
        for _, stroke in ipairs(strokes) do
            mode.undo[#mode.undo + 1] = InkTools.copy(before)
            before[#before + 1] = stroke
        end
        mode.redo = {}
        mode.selection = {}
    end
    logger.warn("Kalamos ink save", tostring(session.target.viewKey), "strokes", #strokes)
    local entry = { id = "ink-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)),
        kind = session.kind, createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ"), anchor = session.target,
        strokes = strokes }
    local document = mode and mode.annotations
    if not document then return InkStore.appendInk(session.book.bookId, entry) end
    document.entries[#document.entries + 1] = entry
    self:indexInkEntry(entry)
    local ok, save_err = InkStore.writeAnnotations(session.book.bookId, document)
    if not ok then
        document.entries[#document.entries] = nil
        self:removeIndexedInkEntry(entry)
        mode.undo, mode.redo, mode.selection = old_undo, old_redo, old_selection
    end
    if ok and self.ink_mode then self.ink_mode.saved = (self.ink_mode.saved or 0) + #strokes end
    return ok, save_err
end

local function inkTargetKeys(kind, target)
    local keys = {}
    local original_kind = kind
    if kind == "sticky" and target.stickyId then
        keys[kind .. "\0sticky\0" .. tostring(target.stickyId)] = true
    else
        local layouts = kind == "full-page" and target.layout and (target.compatibleLayouts or {target.layout}) or {false}
        for _, layout in ipairs(layouts) do
            local scoped = layout and kind .. "\0layout:" .. layout or kind
            if target.viewKey then keys[scoped .. "\0view\0" .. tostring(target.viewKey)] = true end
            if target.page ~= nil then keys[scoped .. "\0page\0" .. tostring(target.page)] = true end
            if target.fragment then keys[scoped .. "\0fragment\0" .. tostring(target.fragment)] = true end
        end
    end
    if original_kind == "full-page" and target.layout and target.legacyCompatible then
        if target.viewKey then keys[original_kind .. "\0view\0" .. target.viewKey] = true end
        if target.page ~= nil then keys[original_kind .. "\0page\0" .. tostring(target.page)] = true end
        if target.fragment then keys[original_kind .. "\0fragment\0" .. target.fragment] = true end
    end
    return keys
end

function Kalamos:replaceInkPage(session, strokes)
    local mode = self.ink_mode
    if not mode then return nil, "No handwriting session" end
    if session.kind == "space" then
        local ok, err = self.writing_spaces:saveInk(session.target.spaceId, mode.bounds, strokes)
        if not ok then return nil, err end
        mode.space_strokes = InkTools.copy(strokes)
        return true
    end
    local old_entries = mode.annotations.entries
    local retained, target_keys = {}, inkTargetKeys(session.kind, session.target)
    for _, entry in ipairs(old_entries) do
        if entry.kind ~= session.kind or not target_keys[annotationKey(entry.kind, entry.anchor)] then
            retained[#retained + 1] = entry
        end
    end
    if #strokes > 0 then
        retained[#retained + 1] = {
            id = "ink-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)),
            kind = session.kind, createdAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            anchor = session.target, strokes = strokes,
        }
    end
    mode.annotations.entries = retained
    local ok, err = InkStore.writeAnnotations(session.book.bookId, mode.annotations)
    if not ok then mode.annotations.entries = old_entries; return nil, err end
    mode.annotation_index = indexAnnotations(mode.annotations)
    self.ink_annotation_index = mode.annotation_index
    self:showSavedInk()
    return true
end

function Kalamos:applyInkToolEvent(session, event)
    local mode = self.ink_mode
    if not mode then return false end
    local old_undo, old_redo, old_selected = InkTools.copy(mode.undo), InkTools.copy(mode.redo), InkTools.copy(mode.selection)
    local current = self:strokesForTarget(session.kind, session.target)
    local old_selection = InkTools.selectionBounds(current, mode.selection)
    local next_strokes
    if event.kind == "action" then
        if event.name == "finish" then return false, true end
        if event.name == "exit-kalamos" then
            mode.pending_action = event
            return false
        end
        if event.name == "canvas-mode" or event.name == "sticky-mode" then
            mode.placement = event.name == "canvas-mode" and "canvas" or "sticky"
            return false
        elseif event.name == "placement-cancel" then
            mode.placement, mode.initial_tool = nil, nil
            return false
        end
        if event.name == "page" or event.name == "sticky" or event.name == "space"
            or event.name == "place-canvas" or event.name == "place-sticky" or event.name == "cancel-sticky" or event.name == "sticky-text" or event.name == "original-ink"
            or event.name:match("^space%-") then
            mode.pending_action = event
            return false
        end
        if event.name == "undo" then
            next_strokes = table.remove(mode.undo)
            if next_strokes then mode.redo[#mode.redo + 1] = InkTools.copy(current); mode.selection = {} end
        elseif event.name == "redo" then
            next_strokes = table.remove(mode.redo)
            if next_strokes then mode.undo[#mode.undo + 1] = InkTools.copy(current); mode.selection = {} end
        elseif event.name == "erase-all" then
            next_strokes = {}
            mode.selection = {}
        elseif event.name == "delete-selection" then
            next_strokes = InkTools.delete(current, mode.selection)
            mode.selection = {}
        end
    elseif event.kind == "eraser" then
        next_strokes = InkTools.erase(current, event.points or {}, event.mode, event.width)
        mode.selection = {}
    elseif event.kind == "lasso" then
        if event.mode == "move" or event.mode == "resize" then
            next_strokes = InkTools.transform(current, mode.selection, event.points or {}, event.mode, event.handle)
        else
            mode.selection = InkTools.select(current, event.points or {}, event.mode or "lasso")
            -- A pen-drawn selection mark was presented by the daemon but is not saved ink.
            return true
        end
    end
    if not next_strokes then return false end
    local dirty = old_selection
    if event.kind == "eraser" then
        local points = event.points or {}
        if #points > 0 then
            local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
            for _, point in ipairs(points) do
                left, top = math.min(left, point[1]), math.min(top, point[2])
                right, bottom = math.max(right, point[1]), math.max(bottom, point[2])
            end
            local pad = math.max(12, event.width or 18) + 20
            dirty = { left = left - pad, top = top - pad, right = right + pad, bottom = bottom + pad }
            if event.mode ~= "track" then
                local remaining = {}; for _, stroke in ipairs(next_strokes) do remaining[stroke] = true end
                for _, stroke in ipairs(current) do
                    if not remaining[stroke] then
                        for _, point in ipairs(InkTools.points(stroke)) do
                            dirty.left = math.min(dirty.left, point[1] - pad)
                            dirty.top = math.min(dirty.top, point[2] - pad)
                            dirty.right = math.max(dirty.right, point[1] + pad)
                            dirty.bottom = math.max(dirty.bottom, point[2] + pad)
                        end
                    end
                end
            end
        end
    elseif event.kind == "lasso" and (event.mode == "move" or event.mode == "resize") then
        local moved = InkTools.selectionBounds(next_strokes, mode.selection)
        if dirty and moved then
            dirty = { left = math.min(dirty.left, moved.left), top = math.min(dirty.top, moved.top),
                right = math.max(dirty.right, moved.right), bottom = math.max(dirty.bottom, moved.bottom) }
        else dirty = moved or dirty end
    else dirty = nil end
    mode.editRect = dirty
    if event.name ~= "undo" and event.name ~= "redo" then
        mode.undo[#mode.undo + 1] = InkTools.copy(current)
        mode.redo = {}
    end
    local ok, err = self:replaceInkPage(session, next_strokes)
    if not ok then
        mode.undo, mode.redo, mode.selection = old_undo, old_redo, old_selected
        return nil, nil, err
    end
    return true
end

function Kalamos:applyInkBatch(session, batch)
    local strokes = batch.strokes or {}
    if session.kind == "full-page" and self.ui.rolling and self.ui.document and self.ui.document.getWordFromPosition then
        for _, stroke in ipairs(strokes) do
            local points = InkTools.points(stroke)
            if stroke.tool == "highlighter" and #points == 2 then
                local x = (points[1][1] + points[2][1]) / 2
                local y = (points[1][2] + points[2][2]) / 2
                local ok, word = pcall(self.ui.document.getWordFromPosition, self.ui.document,
                    { x = x, y = y })
                if ok and word and word.sbox then
                    local box = word.sbox
                    local center = box.y + box.h / 2
                    if math.abs(center - y) < math.max(24, box.h) then
                        points[1][2], points[2][2] = center, center
                    end
                end
            end
        end
    end
    if session.kind == "full-page" and self.ui.paging and self.ui.document and self.ui.document.getTextBoxes then
        local page = (session.target.page or 0) + 1
        local ok, lines = pcall(self.ui.document.getTextBoxes, self.ui.document, page)
        if ok and type(lines) == "table" then
            for _, stroke in ipairs(strokes) do
                local points = InkTools.points(stroke)
                if stroke.tool == "highlighter" and #points == 2 then
                    local y = (points[1][2] + points[2][2]) / 2
                    local best_y, best_distance
                    for _, line in ipairs(lines) do
                        local first, last = line[1], line[#line]
                        if first and last then
                            local transformed, rect = pcall(self.ui.view.pageToScreenTransform,
                                self.ui.view, page, { x = first.x0, y = first.y0,
                                    w = last.x1 - first.x0, h = last.y1 - first.y0 })
                            if transformed and rect then
                                local center = rect.y + rect.h / 2
                                local distance = math.abs(center - y)
                                if distance < math.max(24, rect.h) and
                                    (not best_distance or distance < best_distance) then
                                    best_y, best_distance = center, distance
                                end
                            end
                        end
                    end
                    if best_y then points[1][2], points[2][2] = best_y, best_y end
                end
            end
        end
    end
    local ok, err = self:appendInkStrokes(session, strokes)
    if not ok then return nil, nil, err end
    -- A later tool-event write may fail. Retrying that batch must not append its strokes twice.
    batch.strokes = {}
    local repaint = false
    for _, stroke in ipairs(strokes) do
        if stroke.tool == "highlighter" then repaint = true end
    end
    local finish = false
    while batch.events and #batch.events > 0 do
        local changed, requested_finish, event_err = self:applyInkToolEvent(session, batch.events[1])
        if changed == nil then return nil, nil, event_err end
        table.remove(batch.events, 1)
        repaint = repaint or changed
        finish = finish or requested_finish
    end
    return repaint, finish
end

function Kalamos:replayEditedInk(session)
    local mode = self.ink_mode
    if not mode or self.ink_session ~= session then return end
    -- Reconcile completed batches at an idle boundary, never over the next live stroke.
    if AndroidBridge.isPenInputActive() then
        if not mode.replay_scheduled then
            mode.replay_scheduled = true
            UIManager:scheduleIn(0.03, function()
                mode.replay_scheduled = nil
                if self.ink_mode == mode and self.ink_session == session then self:replayEditedInk(session) end
            end)
        end
        return
    end
    -- Same-page edits must keep the retained ink visible until the replacement frame is ready.
    -- pauseInk clears the full surface for page turns and makes every stroke blink away.
    local pending, err = AndroidBridge.drainInk()
    if not pending then message(err or _("Could not refresh handwriting")); return end
    local applied, finish, apply_err = self:applyInkBatch(session, pending)
    if applied == nil then message(_("Could not save handwriting: ") .. tostring(apply_err)); return end
    if finish then self:finishInk(); return end
    local strokes = self:strokesForTarget(session.kind, session.target)
    local bounds = self:inkBounds(session.kind, strokes, mode.editRect == nil, mode.bounds)
    bounds.selection = InkTools.selectionBounds(strokes, mode.selection)
    bounds.selectedIndices = {}
    for index, selected in pairs(mode.selection) do
        if selected then bounds.selectedIndices[#bounds.selectedIndices + 1] = index - 1 end
    end
    bounds.editRect = mode.editRect
    mode.editRect = nil
    local result, start_err = AndroidBridge.startInk(bounds)
    if not result or result.err then message(start_err or result and result.err or _("Could not refresh handwriting")) end
end

function Kalamos:checkpointInkPage()
    local session = self.ink_session
    if not session then return true end
    local mode = self.ink_mode
    local batch, err = mode and mode.pending_batch or AndroidBridge.drainInk()
    if not batch then return nil, err or _("Could not collect handwriting") end
    local repaint, finish, apply_err = self:applyInkBatch(session, batch)
    if repaint == nil then
        if mode then
            local tail = AndroidBridge.stopInk()
            batch.strokes = batch.strokes or {}
            batch.events = batch.events or {}
            for _, stroke in ipairs(tail and tail.strokes or {}) do batch.strokes[#batch.strokes + 1] = stroke end
            for _, event in ipairs(tail and tail.events or {}) do batch.events[#batch.events + 1] = event end
            mode.pending_batch, mode.pending_session = batch, session
            self.ink_session = nil
            message(_("Could not save handwriting. Pen capture is paused; use the checked writing action to retry Save.") .. "\n" .. tostring(apply_err))
        end
        return nil, apply_err
    end
    if mode then mode.pending_batch = nil end
    if batch.suspended then
        -- Android already detached the background daemon. Save its last completed vectors
        -- before ending the Lua session; do not repaint or reattach from this old watcher.
        self.ink_generation = self.ink_generation + 1
        self.ink_watch_generation = self.ink_watch_generation + 1
        self.ink_session = nil
        self.ink_mode = nil
        self:closeStickyEditor()
        self.resume_page_writing, self.awaiting_sticky = nil, nil
        self:deactivatePenSuppression()
        logger.info("Kalamos handwriting saved after Android background handoff")
    elseif finish then self:finishInk()
    elseif self.ink_mode and self.ink_mode.pending_action then
        local action = self.ink_mode.pending_action
        self.ink_mode.pending_action = nil
        self:writingAction(action)
    elseif repaint then self:replayEditedInk(session) end
    return true
end

function Kalamos:saveInkPage(keep_attached)
    local mode = self.ink_mode
    local session = self.ink_session or mode and mode.pending_session
    if not session then return true end
    if mode and mode.pending_batch then
        local applied, _, err = self:applyInkBatch(session, mode.pending_batch)
        if applied == nil then return nil, err end
        mode.pending_batch = nil
        if mode.pending_session then
            mode.pending_session = nil
            self.ink_session = nil
            return true
        end
    end
    local batch, err
    if keep_attached then batch, err = AndroidBridge.pauseInk()
    else batch, err = AndroidBridge.stopInk() end
    if not batch then return nil, err or _("Could not collect handwriting") end
    self.ink_session = nil
    local applied, _, apply_err = self:applyInkBatch(session, batch)
    if applied == nil then
        mode.pending_batch, mode.pending_session = batch, session
        -- Native capture has stopped. Never reattach departing-page vectors to a new view while
        -- disk recovery is pending. The checked main action remains available to retry Save.
        self.ink_generation = self.ink_generation + 1
        return nil, apply_err
    end
    return true
end

function Kalamos:startInk(kind, target, bounds, initial_tool)
    if self.ink_available == false then
        message(_("Handwriting is unavailable on this device or KOReader build."))
        return
    end
    local book = self:book(); if not book then return end
    if self.ink_mode then message(_("Finish the active handwriting session first")); return end
    if self.writing_spaces_error then message(tostring(self.writing_spaces_error)); return end
    if self.writing_spaces and self.writing_spaces.preview_document then
        message(_("Apply or cancel the writing-space preview before writing.")); return
    end
    if self.writing_spaces and #self.writing_spaces.saved.spaces > 0 and not self.writing_spaces:supported() then
        message(_("Restore single-page EPUB view before editing this book's handwriting.")); return
    end
    local annotations, annotation_index = self:loadInkAnnotations(book.bookId)
    if not annotations then
        message(_("Could not load saved handwriting. The original file has been preserved.") .. "\n" .. tostring(annotation_index))
        return
    end
    self.ink_mode = { kind = kind, book = book, saved = 0,
        annotations = annotations, annotation_index = annotation_index, bounds = bounds, target = target,
        undo = {}, redo = {}, selection = {}, initial_tool = initial_tool,
        placement = (initial_tool == "canvas" or initial_tool == "sticky") and initial_tool or nil }
    if kind == "space" then self.ink_mode.space_strokes = self:spaceStrokeList(target, bounds) end
    if kind == "sticky" then
        self.ink_mode.original_strokes = InkTools.copy(self:strokesForTarget(kind, target))
        local conversion = self.pending_space_conversion
        if conversion and target.stickyId == conversion.stickyId then
            self.ink_mode.converting_space = conversion.id
            local source = conversion.space
            local reference = {left = 0, top = 0, right = source.basisWidth or 600, bottom = source.basisHeight or source.height}
            local strokes = self.writing_spaces:strokes(source, reference, false)
            local scale = math.min((bounds.right - bounds.left) / reference.right,
                (bounds.bottom - bounds.top) / reference.bottom)
            for _, stroke in ipairs(strokes) do
                for _, point in ipairs(InkTools.points(stroke)) do
                    point[1], point[2] = bounds.left + point[1] * scale, bounds.top + point[2] * scale
                end
                if stroke.width then stroke.width = stroke.width * scale end
            end
            local ok, err = self:replaceInkPage({kind = kind, book = book, target = target}, strokes)
            if not ok then self.ink_mode = nil; message(tostring(err)); return nil end
            self.pending_space_conversion = nil
        end
    end
    self:activatePenSuppression()
    self.pen_contact_active = false
    self.pen_release_pending = false
    self.pen_selection_active = false
    self:showSavedInk()
    -- Let KOReader close its menu and paint the page before the daemon becomes authoritative.
    -- A transient InfoMessage here would dismiss itself by repainting over freshly drawn ink.
    self:scheduleInkPage(target or self:inkTarget(), false)
    self:startInkPageWatch()
    return true
end

function Kalamos:openStickyEditor(item)
    if self.sticky_widget then return end
    if self.ink_mode then
        if self.ink_mode.kind ~= "full-page" then return end
        if not self:finishInk(true) then return end
        self.resume_page_writing = true
    end
    self.awaiting_sticky = nil
    local sticky = item and item.kalamosSticky
    local sticky_id = sticky and sticky.id
        or ("sticky-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)))
    local target = self:inkTarget()
    target.stickyId = sticky_id
    target.selectionText = item and item.text
    if item and type(item.pos0) == "string" then target.selectionFragment = item.pos0 end

    local StickyNoteWidget = require("stickynotewidget")
    local widget
    widget = StickyNoteWidget:new{
        selection_text = target.selectionText,
        save_callback = function() self:finishInk() end,
        cancel_callback = function() self:cancelStickyInk() end,
        text_callback = function() self:editStickyText() end,
        options_callback = function() self:showStickyOptions() end,
    }
    self.sticky_item = item
    self.sticky_widget = widget
    UIManager:show(widget)
    UIManager:tickAfterNext(function()
        if self.sticky_widget ~= widget then return end
        local bounds = widget:getWritingBounds()
        logger.warn("Kalamos opening sticky", sticky_id,
            bounds and (tostring(bounds.left) .. "," .. tostring(bounds.top) .. "-" ..
                tostring(bounds.right) .. "," .. tostring(bounds.bottom)) or "without bounds")
        if not bounds or not self:startInk("sticky", target, bounds) then
            self:closeStickyEditor()
        end
    end)
end

function Kalamos:editStickyText()
    local item = self.sticky_item
    self.resume_page_writing = nil
    if not self:finishInk(true) then return end
    for index, entry in ipairs(self.ui.annotation.annotations) do
        if entry == item then
            self.ui.highlight:editNote(index)
            return
        end
    end
end
function Kalamos:showStickyOptions()
    -- Finger fallback for the same header command; pause/save the native owner first.
    local item = self.sticky_item
    self.resume_page_writing = nil
    if not self:finishInk(true) then return end
    local dialog
    dialog = ButtonDialog:new{buttons = {
        {{text = _("Text note"), callback = function()
            UIManager:close(dialog)
            for index, entry in ipairs(self.ui.annotation.annotations) do
                if entry == item then self.ui.highlight:editNote(index); return end
            end
        end}},
        {{text = _("Continue handwriting"), callback = function() UIManager:close(dialog); self:openStickyEditor(item) end}},
    }}
    UIManager:show(dialog)
end
function Kalamos:closeStickyEditor()
    local widget = self.sticky_widget
    self.sticky_widget = nil
    if widget then UIManager:close(widget) end
end

function Kalamos:cancelStickyInk()
    if not self.ink_mode or self.ink_mode.kind ~= "sticky" then
        self:closeStickyEditor()
        return
    end
    local mode = self.ink_mode
    local session = self.ink_session or mode.pending_session or
        (mode.target and {kind = mode.kind, book = mode.book, target = mode.target})
    if not session then return end
    local ok, err = self:replaceInkPage(session, self.ink_mode.original_strokes or {})
    if not ok then message(_("Could not cancel note edits: ") .. tostring(err)); return end
    self.ink_generation = self.ink_generation + 1
    self.ink_watch_generation = self.ink_watch_generation + 1
    AndroidBridge.stopInk()
    self.ink_session = nil
    local converting = self.ink_mode.converting_space
    self.ink_mode = nil
    if (converting or self.new_placement_sticky == session.target.stickyId) and self.ui.annotation and self.ui.highlight then
        for index, item in ipairs(self.ui.annotation.annotations) do
            if item.kalamosSticky and item.kalamosSticky.id == session.target.stickyId then
                self.ui.highlight:deleteHighlight(index); break
            end
        end
    end
    self.new_placement_sticky = nil
    self:closeStickyEditor()
    self:showSavedInk()
    self:resumePageWriting()
end

function Kalamos:finishInk(quiet)
    if not self.ink_mode then return true end
    local mode = self.ink_mode
    local ok, save_err = self:saveInkPage()
    if not ok then
        message(_("Could not save handwriting. Writing remains active; retry Save.") .. "\n" .. tostring(save_err))
        return nil, save_err
    end
    if mode.converting_space then
        -- Persist the ordinary KOReader anchor before removing the original space. A failure
        -- leaves the source intact and the saved sticky available; retrying Save is safe.
        local saved_settings, settings_err = pcall(function()
            self.ui:handleEvent(Event:new("SaveSettings"))
            return self.ui.doc_settings:flush()
        end)
        if not saved_settings or not settings_err then
            local err = _("Could not persist the sticky-note anchor. The original writing space has been kept.")
            message(err); return nil, err
        end
        local removed, remove_err = self.writing_spaces:remove(mode.converting_space, true)
        if not removed then message(tostring(remove_err)); return nil, remove_err end
        mode.converting_space = nil
    end
    self.ink_generation = self.ink_generation + 1
    self.ink_watch_generation = self.ink_watch_generation + 1
    self.ink_mode = nil
    recoveries[mode.book.bookId] = nil
    if mode.kind == "sticky" then self.new_placement_sticky = nil; self:closeStickyEditor() end
    self:showSavedInk()
    if mode.kind == "sticky" then self:resumePageWriting() end
    return true
end

function Kalamos:resumePageWriting()
    local resume = self.resume_page_writing
    self.resume_page_writing = nil
    if resume then self:startInk("full-page") end
end

function Kalamos:writingAction(action)
    local event = type(action) == "table" and action or {name = action}
    action = event.name
    if action == "exit-kalamos" then return self:exitKalamosMode()
    elseif action == "original-ink" then return self:toggleOriginalPageInk()
    elseif action == "sticky-text" then return self:editStickyText()
    elseif action == "cancel-sticky" then return self:cancelStickyInk()
    elseif action == "place-canvas" or action == "place-sticky" then
        return self:placeWritingTool(event)
    elseif action:match("^space%-") then
        return self:adjustActiveSpace(action)
    elseif action == "page" then
        self.resume_page_writing = nil
        if self.ink_mode and not self:finishInk(true) then return end
        self:startInk("full-page")
    elseif action == "sticky" then
        self.resume_page_writing = nil
        if self.ink_mode and not self:finishInk(true) then return end
        self:startInk("full-page", nil, nil, "sticky")
    elseif action == "space" then
        self:showWritingSpaces()
    end
end

function Kalamos:changeInkPage(pageno)
    local mode = self.ink_mode
    if not mode then return end
    local next_target = self:inkTarget()
    if type(pageno) == "number" then next_target.page = math.max(0, pageno - 1) end
    if self.ink_session and self.ink_session.target.viewKey == next_target.viewKey and
        self.ink_session.target.layout == next_target.layout then return end
    if mode.pending_session then return end
    if not self.ink_session and next_target.viewKey and
        mode.pending_view_key == next_target.viewKey then return end
    logger.warn("Kalamos ink transition to", tostring(next_target.viewKey))
    local keep_attached = mode.kind == "full-page"
    local ok, save_err = self:saveInkPage(keep_attached)
    if not ok then
        message(_("Could not save handwriting. The departing page's ink is retained for retry: ") .. tostring(save_err))
        return
    end
    if keep_attached then
        mode.undo, mode.redo, mode.selection = {}, {}, {}
        -- Keep one bound surface/controller across page turns. Once the destination view is stable,
        -- make one full-page GU16 update authoritative so retained panel pixels cannot leak from the
        -- old page. Normal pen updates remain regional.
        self:scheduleInkPage(next_target, true)
    else
        self.ink_mode = nil
        if mode.kind == "sticky" then self:closeStickyEditor() end
        self:showSavedInk()
        if mode.kind == "space" then self:startInk("full-page") end
    end
end

function Kalamos:exitKalamosMode()
    -- Explicit Exit must never reopen page tools after saving a sticky note.
    self.resume_page_writing, self.awaiting_sticky = nil, nil
    self.pending_canvas_start = nil
    return self:finishInk()
end

function Kalamos:toggleWriting()
    if self.ink_mode or self.pending_canvas_start then return self:exitKalamosMode() end
    self.resume_page_writing, self.awaiting_sticky = nil, nil
    return self:startInk("full-page")
end

function Kalamos:getSubMenu()
    -- Fallback for key-only menus and older readers without action-tab support.
    return {{ text = _("Page writing"), checked_func = function() return self.ink_mode ~= nil or self.pending_canvas_start ~= nil end,
        callback = function() self:toggleWriting() end }}
end

function Kalamos:addToMainMenu(menu_items)
    if self.ink_available == false or not self.ui.document then return end
    ensureKalamosMenuOrder()
    menu_items.kalamos = { icon = "kalamos", remember = false,
        icon_func = function() return (self.ink_mode or self.pending_canvas_start) and "kalamos-active" or "kalamos" end,
        activate_callback = function() self:toggleWriting() end }
    menu_items.kalamos_handwriting = self:getSubMenu()[1]
end

function Kalamos:onCloseDocument()
    self:restoreWritingLayoutGuard()
    self.pending_canvas_start = nil
    self.resume_page_writing = nil
    self.awaiting_sticky = nil
    if self.ink_available == false then return end
    self.ink_generation = self.ink_generation + 1
    self.ink_watch_generation = self.ink_watch_generation + 1
    if self.ink_session or self.ink_mode and self.ink_mode.pending_session then
        local ok, err = self:saveInkPage()
        if not ok then
            recoveries[self.ink_mode.book.bookId] = self.ink_mode
            message(_("Handwriting could not be saved. Keep KOReader running and reopen this book to retry; unsaved strokes are retained in memory.") .. "\n" .. tostring(err))
        end
    elseif self.ink_mode then
        AndroidBridge.stopInk()
    end
    self.ink_mode = nil
    if self.writing_spaces then self.writing_spaces:close() end
    self.writing_spaces = nil
    self:closeStickyEditor()
    self:restoreStickyHighlightTap()
    self:restoreCompactSelection()
    self:deactivatePenSuppression()
    if self.ui.onClose == self.close_guard then self.ui.onClose = self.previous_close end
    self.close_guard, self.previous_close = nil, nil
end

function Kalamos:onReaderReady()
    if self.ink_available == false then return end
    local book = InkStore.current(self.ui)
    if book then
        local annotations, err = self:loadInkAnnotations(book.bookId)
        if not annotations then
            message(_("Could not load saved handwriting. The original file has been preserved.") .. "\n" .. tostring(err))
        end
        if self.ui.doc_settings and self.ui.document.getDocumentRenderingHash then
            self.legacy_layout = self.ui.doc_settings:readSetting("kalamos_legacy_ink_layout")
            if not self.legacy_layout then
                self.legacy_layout = self:inkTarget().layout
                self.ui.doc_settings:saveSetting("kalamos_legacy_ink_layout", self.legacy_layout)
            end
        end
        local loaded, space_err = self:loadWritingSpaces(book.bookId)
        if not loaded then message(_("Could not read writing spaces. The original file is preserved.") .. "\n" .. tostring(space_err)) end
        local recovery = recoveries[book.bookId]
        if recovery and annotations and loaded then
            self.ink_mode = recovery
            local recovered, recovery_err = self:saveInkPage()
            if recovered then
                recoveries[book.bookId] = nil
                self.ink_mode = nil
                self:loadInkAnnotations(book.bookId)
                message(_("Recovered pending handwriting."))
            else message(_("Pending handwriting still needs Save: ") .. tostring(recovery_err)) end
        end
        self:registerSpaceMarkers()
        self:showSavedInk()
    end
    self:setPenSelectionColor()

end

function Kalamos:onPageUpdate(pageno)
    self:changeInkPage(pageno)
end

function Kalamos:onPosUpdate(_, pageno)
    self:changeInkPage(pageno)
end

require("layoutguard")(Kalamos)
require("writingui")(Kalamos)
require("selectionui")(Kalamos)

return Kalamos
