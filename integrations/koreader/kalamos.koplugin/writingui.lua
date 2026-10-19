-- Reader-owned writing-space UI. Native ink remains the only live stylus renderer.
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local InkTools = require("inktools")
local Spaces = require("writingspaces")
local AndroidBridge = require("androidbridge")
local Event = require("ui/event")
local _ = require("gettext")
local function notice(text) UIManager:show(InfoMessage:new{text = text}) end

return function(Kalamos)
function Kalamos:loadWritingSpaces(book_id)
    if self.writing_spaces then return true end
    local spaces, err = Spaces.open(self.ui, book_id)
    if not spaces then self.writing_spaces_error = err; return nil, err end
    self.writing_spaces = spaces
    if spaces:supported() then
        spaces:install()
        if #spaces.saved.spaces > 0 then spaces:apply() end
    elseif #spaces.saved.spaces > 0 then
        notice(_("Saved writing spaces require the Kalamos EPUB engine and single-page view. Their data has been preserved."))
    end
    return true
end
function Kalamos:hasPageInk()
    for _, entry in ipairs((self.ink_annotations or {}).entries or {}) do
        if entry.kind == "full-page" and #(entry.strokes or {}) > 0 then return true end
    end
    return false
end
function Kalamos:showCanvasLayout()
    local spaces = self.writing_spaces
    if spaces and spaces.original_view then spaces:setOriginalView(false) end
end
function Kalamos:toggleOriginalPageInk()
    self.resume_page_writing, self.awaiting_sticky = nil, nil
    if self.ink_mode and not self:finishInk(true) then return end
    local spaces = self.writing_spaces
    if not spaces then return end
    local original = not spaces.original_view
    local anchor, layout
    if original then
        self.canvas_return_position = self.ui.document:getXPointer()
        -- Jump to an actual saved view rather than displaying an apparently empty
        -- original page when all handwriting lives elsewhere in the book.
        for i = #(self.ink_annotations and self.ink_annotations.entries or {}), 1, -1 do
            local item = self.ink_annotations.entries[i]
            if item.kind == "full-page" and #(item.strokes or {}) > 0 then
                anchor = item.anchor and item.anchor.fragment
                layout = item.anchor and item.anchor.canvasLayout
                break
            end
        end
    else anchor = self.canvas_return_position end
    spaces:setOriginalView(original, layout)
    if anchor then self.ui:handleEvent(Event:new("GotoXPointer", anchor)) end
    self:showSavedInk()
    self:startInk("full-page")
end
-- Canvas is a tool on the page, not a paragraph-picker dialog. The initial native
-- contact supplies the anchor; its downward extent supplies the requested height.
function Kalamos:showWritingSpaces()
    self.resume_page_writing, self.awaiting_sticky = nil, nil
    if self.ink_mode and not self:finishInk(true) then return end
    local book = self:book(); if not book then return end
    local ok, err = self:loadWritingSpaces(book.bookId)
    if not ok then notice(tostring(err)); return end
    if not self.writing_spaces:supported() then
        notice(_("Canvas requires a reflowable EPUB in single-page view.")); return
    end
    self:showCanvasLayout()
    self:startInk("full-page", nil, nil, "canvas")
end
function Kalamos:editWritingSpace(id, candidate)
    if id then return self:writeInSpace(id) end
    return self:insertWritingSpace(candidate)
end
function Kalamos:insertWritingSpace(anchor, height)
    self.resume_page_writing, self.awaiting_sticky = nil, nil
    if self.ink_mode and not self:finishInk(true) then return end
    local book = self:book(); if not book then return end
    local loaded, err = self:loadWritingSpaces(book.bookId)
    if not loaded then notice(tostring(err)); return end
    local spaces = self.writing_spaces
    self:showCanvasLayout()
    local info, failure = spaces:info(anchor)
    if not info then notice(tostring(failure)); return end
    -- Reuse an existing canvas rather than making a duplicate at the same paragraph.
    for _, space in ipairs(spaces.saved.spaces) do
        if space.anchor == info.anchor then
            if space.collapsed then
                local ok, expand_err = spaces:change(space.id, space.height, false)
                if not ok then notice(tostring(expand_err)); return end
            end
            return self:writeInSpace(space.id)
        end
    end
    local id = "space-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
    height = height or math.floor(Device.screen:getHeight() / 6)
    height = math.max(48, math.min(math.floor(Device.screen:getHeight() * .4), height))
    local ok, save_err = spaces:change(id, height, false, info.anchor)
    if not ok then notice(tostring(save_err)); return end
    self:writeInSpace(id)
end
function Kalamos:writingWordAt(x, y)
    local doc = self.ui.document
    if not doc.getWordFromPosition then return end
    -- A tap in the inter-line gap attaches to the text immediately above it. Sampling
    -- the same line across the paragraph also makes taps in the right margin useful.
    local width = Device.screen:getWidth()
    if not self.ui.paging and doc.getNearestWordAndBoxFromPosition then
        -- CREngine resolves the nearest source boundary directly, including short
        -- lines and the blank gap above the next paragraph. Avoid a grid of guesses.
        local ok, word = pcall(doc.getNearestWordAndBoxFromPosition, doc, {x = x, y = y}, -1)
        if ok and word and word.pos0 then return word end
    end
    for _, dy in ipairs({0, 8, 16, 24, 36, 48, 64, 80}) do
        if y - dy >= 0 then
            for _, px in ipairs({x, math.min(x, width * .7), width * .5, width * .3}) do
                local pos = {x = px, y = y - dy}
                if self.ui.paging then pos = self.ui.view:screenToPageTransform(pos) end
                if pos then
                    local ok, word = pcall(doc.getWordFromPosition, doc, pos, true)
                    if ok and word then
                        if self.ui.paging and word.pos then
                            -- Same normalization as upstream ReaderHighlight: PDF positions
                            -- are page-local records, not EPUB source XPointers.
                            word.pos0 = InkTools.copy(word.pos)
                            word.pos1 = InkTools.copy(word.pos)
                        end
                        if word.pos0 then return word end
                    end
                end
            end
        end
    end
end
function Kalamos:placeWritingTool(event)
    if not self.ink_mode or not self.ink_mode.placement then return end
    if type(event.x) ~= "number" or type(event.y) ~= "number" then return end
    local tool = self.ink_mode.placement
    -- Ignore stale queued contacts after a different tool was selected.
    if event.name ~= "place-" .. tool then return end
    if tool == "canvas" and self.writing_spaces then
        for _, space in ipairs(self.writing_spaces.saved.spaces) do
            local bounds = self.writing_spaces:bounds(space)
            local near_handle = bounds and event.x >= bounds.left and event.x <= bounds.right
                and event.y >= bounds.top - 16 and event.y <= bounds.bottom + 24
            if near_handle then
                local delta = (event.endY or event.y) - event.y
                if math.abs(delta) < 12 then return self:writeInSpace(space.id) end
                return self:resizeWritingSpace(space.id, delta)
            end
        end
    end
    local word = self:writingWordAt(event.x, event.y)
    if not word then return end -- Stay in placement mode; a blank margin is not an error dialog.
    if tool == "canvas" then
        local drag = (event.endY or event.y) - event.y
        return self:insertWritingSpace(word.pos0, drag > 32 and drag or nil)
    end
    self.resume_page_writing = nil
    if not self:finishInk(true) then return end
    -- Reuse KOReader's normal highlight save path, including PDF boxes, EPUB CFI,
    -- chapter/date metadata and any configured PDF annotation persistence policy.
    local highlight = self.ui.highlight
    if not highlight then return end
    highlight.selected_text = {text = word.word or "", pos0 = word.pos0, pos1 = word.pos1 or word.pos0,
        sboxes = word.sbox and {word.sbox}, pboxes = word.pbox and {word.pbox}}
    self.resume_page_writing = true
    self.creating_placement_sticky = true
    self:makeStickyHighlight(highlight)
    self.creating_placement_sticky = nil
end
function Kalamos:resizeWritingSpace(id, delta)
    self.resume_page_writing, self.awaiting_sticky = nil, nil
    if self.ink_mode and not self:finishInk(true) then return end
    local space = self.writing_spaces and self.writing_spaces:find(id)
    if not space then return end
    self:showCanvasLayout()
    local height = math.max(48, math.min(math.floor(Device.screen:getHeight() * .4), space.height + delta))
    local ok, err = self.writing_spaces:change(id, height, false)
    if not ok then notice(tostring(err)) end
    return self:writeInSpace(id)
end
function Kalamos:adjustActiveSpace(action)
    local mode = self.ink_mode
    if not mode or mode.kind ~= "space" then return end
    local id = mode.target and mode.target.spaceId
    local space = id and self.writing_spaces:find(id)
    if not space then return end
    if not self:finishInk(true) then return end
    space = self.writing_spaces:find(id) -- Include the final native batch before resizing.
    local ok, err
    if action == "space-delete" then ok, err = self.writing_spaces:remove(id, true)
    else
        local height = space.height + (action == "space-larger" and 48 or action == "space-smaller" and -48 or 0)
        if action ~= "space-collapse" then height = math.max(48, math.min(math.floor(Device.screen:getHeight() * .4), height)) end
        ok, err = self.writing_spaces:change(id, height, action == "space-collapse")
    end
    if not ok then notice(tostring(err)); self:writeInSpace(id); return end
    if action == "space-collapse" or action == "space-delete" then self:startInk("full-page")
    else self:writeInSpace(id) end
end
function Kalamos:writeInSpace(id, initial_tool)
    local active = self.ink_mode
    if not initial_tool and active and active.kind == "space" and active.target
        and active.target.spaceId == id then return true end
    self.resume_page_writing, self.awaiting_sticky = nil, nil
    if self.ink_mode and not self:finishInk(true) then return end
    local spaces = self.writing_spaces
    local space = spaces and spaces:find(id)
    if not space or space.collapsed then return end
    local opening = {id = id}
    self.pending_canvas_start = opening
    local highlight = self.ui.highlight
    if highlight and highlight.onClose then highlight:onClose() end
    self:showCanvasLayout()
    -- The canvas belongs to the paragraph's *end*. Its start can be pages away
    -- in a long paragraph; navigating to the start left a successfully created gap
    -- offscreen and incorrectly raised the "does not fit" recovery dialog.
    local info = spaces:info(space.anchor)
    self.ui:handleEvent(Event:new("GotoXPointer", info and info.tail or space.tail or space.anchor))
    self:showSavedInk()
    UIManager:tickAfterNext(function()
        if self.pending_canvas_start ~= opening then return end
        if self.ink_mode then self.pending_canvas_start = nil; return end
        space = spaces:find(id)
        if not space or space.collapsed then self.pending_canvas_start = nil; return end
        local bounds = spaces:bounds(space)
        if not bounds then
            self.pending_canvas_start = nil
            -- Recovery for old oversized canvases or a changed font; ordinary insertion
            -- proceeds directly to writing without showing this menu.
            local dialog
            local function resize(collapsed)
                local height = collapsed and space.height or math.min(space.height, math.floor(Device.screen:getHeight() * .15))
                local ok, err = spaces:change(id, math.max(48, height), collapsed)
                if not ok then notice(tostring(err)); return end
                UIManager:close(dialog)
                if not collapsed then self:writeInSpace(id) end
            end
            dialog = ButtonDialog:new{title = _("This canvas does not fit on the page"), buttons = {
                {{text = _("Fit blank space to page"), callback = function() resize(false) end}},
                {{text = _("Keep handwriting as sticky note"), callback = function()
                    UIManager:close(dialog); self:keepSpaceAsSticky(id)
                end}},
                {{text = _("Collapse"), callback = function() resize(true) end},
                 {text = _("Close"), callback = function() UIManager:close(dialog) end}},
            }}
            UIManager:show(dialog)
            return
        end
        local target = self:inkTarget(); target.spaceId = id
        self:startInk("space", target, bounds, initial_tool)
        self.pending_canvas_start = nil
    end)
end
function Kalamos:keepSpaceAsSticky(id)
    local space = self.writing_spaces and self.writing_spaces:find(id)
    if not space then return end
    local info, err = self.writing_spaces:info(space.anchor)
    if not info then notice(tostring(err)); return end
    local item = {page = info.anchor, pos0 = info.anchor, pos1 = info.tail,
        text = space.text, drawer = "lighten", color = "blue",
        kalamosSticky = {schema = "kalamos.handwritten-sticky/v1", id = "from-" .. id .. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))}}
    local index = self.ui.annotation:addItem(item)
    self.ui:handleEvent(Event:new("AnnotationsModified", {item, index_modified = index}))
    self.pending_space_conversion = {id = id, stickyId = item.kalamosSticky.id, space = InkTools.copy(space)}
    self:openStickyEditor(item)
end
function Kalamos:spaceMarker(space)
    if self.writing_spaces.original_view then return end
    local bounds = self.writing_spaces:bounds(space)
    if bounds then return {left = bounds.right - 18, top = bounds.top, right = bounds.right, bottom = bounds.top + 18} end
    local info = self.writing_spaces:info(space.anchor)
    local doc = self.ui.document
    if not info or not doc.getScreenPositionFromXPointer then return nil end
    local y = doc:getScreenPositionFromXPointer(info.tail)
    if not y or y < 0 or y + 18 > Device.screen:getHeight() then return nil end
    return {left = Device.screen:getWidth() - 22, top = y, right = Device.screen:getWidth() - 4, bottom = y + 18}
end
function Kalamos:registerSpaceMarkers()
    if self.space_marker_registered or not self.ui.registerTouchZones then return end
    self.space_marker_registered = true
    self.ui:registerTouchZones({{
        id = "kalamos_writing_space", ges = "tap",
        screen_zone = {ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1},
        overrides = {"tap_forward", "tap_backward", "tap_link", "readerhighlight_tap"},
        handler = function(gesture)
            -- A finger may touch the page before the periodic native-event poll.
            -- Drain the preceding tool choice now so that tap cannot turn the page.
            local previous = self.ink_mode
            if self.ink_session then
                if not self:checkpointInkPage() or self.ink_mode ~= previous then return true end
            end
            local p = gesture.pos
            if self.ink_mode and not self.ink_mode.placement
                and AndroidBridge.isPenInputActive() then return true end
            if self.ink_mode and self.ink_mode.placement and p then
                self:placeWritingTool({name = "place-" .. self.ink_mode.placement, x = p.x, y = p.y})
                return true
            end
            local mode = self.ink_mode
            local paper = mode and mode.kind == "space" and mode.bounds
            if paper and p and p.x >= paper.left and p.x <= paper.right
                and p.y >= paper.top and p.y <= paper.bottom then return true end
            if not self.writing_spaces or self.writing_spaces.preview_document then return end
            for _, space in ipairs(self.writing_spaces.saved.spaces) do
                local marker = self:spaceMarker(space)
                local p = gesture.pos
                local bounds = not self.ink_mode and self.writing_spaces:bounds(space)
                if bounds and p and p.x >= bounds.left and p.x <= bounds.right
                    and p.y >= bounds.top and p.y <= bounds.bottom then
                    self:writeInSpace(space.id); return true
                end
                if marker and p and p.x >= marker.left - 12 and p.x <= marker.right + 12
                    and p.y >= marker.top - 12 and p.y <= marker.bottom + 12 then
                    if space.collapsed then self:insertWritingSpace(space.anchor)
                    else self:writeInSpace(space.id) end
                    return true
                end
            end
        end,
    }})
    for _, gesture in ipairs({"hold", "hold_pan", "hold_release"}) do
        self.ui:registerTouchZones({{
            id = "kalamos_writing_" .. gesture, ges = gesture,
            screen_zone = {ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1},
            overrides = {"readerhighlight_" .. gesture},
            handler = function()
                return self.pending_canvas_start ~= nil or self.ink_mode or nil
            end,
        }})
    end
    local function begin_drag(gesture)
        local mode = self.ink_mode
        if mode and mode.placement == "canvas" then
            if not self.canvas_finger_drag then
                local start = gesture.start_pos or gesture.pos
                if start then self.canvas_finger_drag = {x = start.x, y = start.y, placement = true} end
            end
            return self.canvas_finger_drag ~= nil
        end
        if self.canvas_finger_drag then return true end
        if not self.writing_spaces or self.writing_spaces.original_view then return end
        local start = gesture.start_pos or gesture.pos
        if not start then return end
        for _, space in ipairs(self.writing_spaces.saved.spaces) do
            local bounds = self.writing_spaces:bounds(space)
            local grip = bounds and math.min(80, math.floor((bounds.right - bounds.left) * .2))
            local center = bounds and (bounds.left + bounds.right) / 2
            if bounds and math.abs(start.x - center) <= grip / 2 + 12
                and math.abs(start.y - bounds.bottom) <= 24
                and not AndroidBridge.isPenInputActive() then
                self.canvas_finger_drag = {x = start.x, y = start.y, id = space.id}
                return true
            end
        end
    end
    self.ui:registerTouchZones({
        {id = "kalamos_canvas_pan", ges = "pan",
            screen_zone = {ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1},
            overrides = {"rolling_pan", "readerhighlight_pan"},
            handler = function(gesture)
                if not self.canvas_finger_drag and self.ink_session then
                    if not self:checkpointInkPage() then return true end
                end
                return begin_drag(gesture) or self.ink_mode and
                    (self.ink_mode.kind == "space" or AndroidBridge.isPenInputActive()) or nil
            end},
        {id = "kalamos_canvas_pan_release", ges = "pan_release",
            screen_zone = {ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1},
            overrides = {"rolling_pan_release", "readerhighlight_pan_release"},
            handler = function(gesture)
                local drag = self.canvas_finger_drag
                self.canvas_finger_drag = nil
                if not drag then return self.ink_mode and
                    (self.ink_mode.kind == "space" or AndroidBridge.isPenInputActive()) or nil end
                local finish_y = gesture.pos and gesture.pos.y or drag.y
                if drag.placement then
                    self:placeWritingTool({name = "place-canvas", x = drag.x, y = drag.y, endY = finish_y})
                else self:resizeWritingSpace(drag.id, finish_y - drag.y) end
                return true
            end},
        {id = "kalamos_canvas_swipe", ges = "swipe",
            screen_zone = {ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1},
            overrides = {"rolling_swipe", "paging_swipe"},
            handler = function(gesture)
                if not begin_drag(gesture) then return self.ink_mode and
                    (self.ink_mode.kind == "space" or AndroidBridge.isPenInputActive()) or nil end
                local drag = self.canvas_finger_drag; self.canvas_finger_drag = nil
                -- Swipe reports its start in pos and its end separately.
                local end_y = gesture.end_pos and gesture.end_pos.y or drag.y
                if drag.placement then self:placeWritingTool({name = "place-canvas", x = drag.x, y = drag.y, endY = end_y})
                else self:resizeWritingSpace(drag.id, end_y - drag.y) end
                return true
            end},
    })
end
function Kalamos:spaceStrokeList(target, bounds)
    local space = self.writing_spaces and self.writing_spaces:find(target.spaceId)
    if not space then return {} end
    return self.writing_spaces:strokes(space, bounds, false)
end
end
