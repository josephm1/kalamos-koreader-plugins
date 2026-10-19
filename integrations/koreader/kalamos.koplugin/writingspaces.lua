-- Paragraph-anchored, real CREngine layout padding; vector ink stays local to its canvas.
local InkStore = require("inkstore")
local InkTools = require("inktools")
local Device = require("device")
local Spaces = {}
Spaces.__index = Spaces

function Spaces.open(ui, book_id)
    local saved, err = InkStore.spaces(book_id)
    if not saved then return nil, err end
    return setmetatable({ui = ui, book_id = book_id, saved = saved, undo = {}, redo = {}}, Spaces)
end
function Spaces:supported()
    local doc = self.ui.document
    return self.ui.rolling and doc and doc.file and doc.file:lower():match("%.epub$")
        and doc._document and type(doc._document.getWritingSpaceInfo) == "function"
        and doc.getVisiblePageCount and doc:getVisiblePageCount() == 1
end
function Spaces:info(anchor)
    if not self:supported() then return nil, "Writing space requires the Kalamos EPUB engine in single-page view." end
    local ok, info = pcall(self.ui.document._document.getWritingSpaceInfo, self.ui.document._document, anchor)
    if not ok or type(info) ~= "table" or type(info.selector) ~= "string" or not info.anchor then
        return nil, "Choose left-to-right text outside tables, lists and floating content."
    end
    return info
end
function Spaces:find(id)
    for _, space in ipairs(self.saved.spaces) do if space.id == id then return space end end
end
function Spaces:css()
    if not self:supported() then return "" end
    local rules = {}
    local model = self.original_view and {spaces = self.original_layout or {}} or self.preview_document or self.saved
    for _, space in ipairs(model.spaces) do
        local info = self:info(space.anchor)
        -- Resolve each source anchor on every load. Never trust a stored CSS selector in a new DOM.
        if info then rules[#rules + 1] = info.selector .. " { padding-bottom: " ..
            tostring(space.collapsed and 0 or space.height) .. "px !important; page-break-inside: avoid !important; }" end
    end
    return table.concat(rules, "\n")
end
function Spaces:install()
    if self.previous_stylesheet then return end
    local doc = self.ui.document
    local previous = doc.setStyleSheet
    self.previous_stylesheet = previous
    self.stylesheet_wrapper = function(document, file, css)
        local added = self:css()
        return previous(document, file, added == "" and css or (css or "") .. "\n" .. added)
    end
    doc.setStyleSheet = self.stylesheet_wrapper
end
function Spaces:close()
    if self.ui.document.setStyleSheet == self.stylesheet_wrapper then
        self.ui.document.setStyleSheet = self.previous_stylesheet
    end
    self.previous_stylesheet, self.stylesheet_wrapper = nil, nil
end
function Spaces:apply()
    local ui = self.ui
    self.layout_changing = true
    self.layout_revision = (self.layout_revision or 0) + 1
    -- Render the visible chapter quickly. ReaderRolling may prepare the rest in
    -- its existing subprocess; the writing guard defers only the final reload.
    local ok, err = pcall(function()
        ui.document:setStyleSheet(ui.typeset.css, ui.styletweak:getCssText())
        ui:handleEvent(require("ui/event"):new("UpdatePos"))
    end)
    self.layout_changing = nil
    if not ok then error(err) end
end
function Spaces:setOriginalView(original, layout)
    original = original == true
    if original == (self.original_view == true) and layout == nil then return end
    self.original_view = original
    self.original_layout = original and {} or nil
    if original and type(layout) == "table" then
        for _, space in ipairs(layout) do
            if type(space) == "table" and type(space.anchor) == "string" and type(space.height) == "number"
                and space.height == space.height and space.height >= 0 and space.height <= 1200 then
                self.original_layout[#self.original_layout + 1] = {id = space.id, anchor = space.anchor,
                    height = space.height, collapsed = space.collapsed == true}
            end
        end
    end
    self:apply()
end
function Spaces:layoutSnapshot()
    local model = self.original_view and {spaces = self.original_layout or {}} or self.saved
    local snapshot = {}
    for _, space in ipairs(model.spaces) do
        snapshot[#snapshot + 1] = {id = space.id, anchor = space.anchor, height = space.height, collapsed = space.collapsed}
    end
    return snapshot
end
function Spaces:commit(next_document, record_history)
    local ok, err = InkStore.writeSpaces(self.book_id, next_document)
    if not ok then return nil, err end
    if record_history then
        self.undo[#self.undo + 1] = InkTools.copy(self.saved)
        if #self.undo > 100 then table.remove(self.undo, 1) end
        self.redo = {}
    end
    self.saved = next_document
    return true
end
function Spaces:change(id, height, collapsed, candidate)
    local next_document = InkTools.copy(self.saved)
    local space
    for _, item in ipairs(next_document.spaces) do if item.id == id then space = item end end
    if not space then
        if not candidate then return nil, "Writing space no longer exists" end
        local info, err = self:info(candidate)
        if not info then return nil, err end
        for _, item in ipairs(next_document.spaces) do
            if item.anchor == info.anchor then return nil, "This paragraph already has a writing space" end
        end
        space = {id = id, anchor = info.anchor, tail = info.tail, text = info.text, strokes = {}}
        next_document.spaces[#next_document.spaces + 1] = space
    end
    -- Preserve the original vector basis when adding/removing blank space below existing ink.
    -- The actual post-layout containment check remains authoritative before native capture.
    if #space.strokes > 0 and height < space.height then
        local max_y = 0
        for _, stroke in ipairs(space.strokes) do for _, point in ipairs(InkTools.points(stroke)) do max_y = math.max(max_y, point[2]) end end
        local basis = space.basisHeight or space.height
        if height < max_y * basis + 12 then return nil, "The smaller space would clip handwriting. Choose a larger height." end
    end
    space.height, space.collapsed = height, collapsed
    local ok, err = self:commit(next_document, true)
    if not ok then return nil, err end
    self.preview_document, self.preview_position = nil, nil
    self:apply()
    return true
end
function Spaces:previewChange(id, height, candidate)
    local next_document = InkTools.copy(self.saved)
    local space
    for _, item in ipairs(next_document.spaces) do if item.id == id then space = item end end
    if not space then
        local info, err = self:info(candidate)
        if not info then return nil, err end
        space = {id = id, anchor = info.anchor, text = info.text, tail = info.tail, strokes = {}}
        next_document.spaces[#next_document.spaces + 1] = space
    end
    space.height, space.collapsed = height, false
    if not self.preview_document then self.preview_position = self.ui.document:getXPointer() end
    self.preview_document = next_document
    self:apply()
    self.ui:handleEvent(require("ui/event"):new("GotoXPointer", space.anchor))
    return true
end
function Spaces:cancelPreview()
    if not self.preview_document then return end
    local position = self.preview_position
    self.preview_document, self.preview_position = nil, nil
    self:apply()
    if position then self.ui:handleEvent(require("ui/event"):new("GotoXPointer", position)) end
end
function Spaces:remove(id, delete_ink)
    local next_document = InkTools.copy(self.saved)
    for i, item in ipairs(next_document.spaces) do
        if item.id == id then
            if #item.strokes > 0 and not delete_ink then return nil, "This writing space contains handwriting" end
            table.remove(next_document.spaces, i)
            local ok, err = self:commit(next_document, true)
            if ok then self:apply() end
            return ok, err
        end
    end
    return nil, "Writing space no longer exists"
end
function Spaces:history(redo)
    local source, destination = redo and self.redo or self.undo, redo and self.undo or self.redo
    local next_document = source[#source]
    if not next_document then return true end
    local old = self.saved
    local ok, err = self:commit(InkTools.copy(next_document), false)
    if not ok then return nil, err end
    table.remove(source); destination[#destination + 1] = old
    self:apply()
    return true
end
function Spaces:bounds(space)
    if self.original_view or space.collapsed then return nil end
    local info = self:info(space.anchor)
    if not info or not info.visible or info.bottom - info.top < 24 or info.right <= info.left
        or info.left < 0 or info.top < 0 or info.right > Device.screen:getWidth()
        or info.bottom > Device.screen:getHeight() then return nil end
    local scale = space.basisWidth and (info.right - info.left) / space.basisWidth or 1
    for _, stroke in ipairs(space.strokes) do
        for _, point in ipairs(InkTools.points(stroke)) do
            if point[2] * (space.basisHeight or (info.bottom - info.top)) * scale > info.bottom - info.top then return nil end
        end
    end
    return {left = info.left, top = info.top, right = info.right, bottom = info.bottom}
end
function Spaces:strokes(space, bounds, to_local, strokes)
    local output = InkTools.copy(strokes or space.strokes)
    local width, height = bounds.right - bounds.left, bounds.bottom - bounds.top
    for _, stroke in ipairs(output) do
        local points = InkTools.points(stroke)
        for _, point in ipairs(points) do
            if to_local then
                point[1], point[2] = (point[1] - bounds.left) / width, (point[2] - bounds.top) / height
            else
                local scale = space.basisWidth and width / space.basisWidth or 1
                point[1], point[2] = bounds.left + point[1] * width,
                    bounds.top + point[2] * (space.basisHeight or height) * scale
            end
        end
        if not to_local and space.basisWidth and stroke.width then
            stroke.width = stroke.width * width / space.basisWidth
        end
    end
    return output
end
function Spaces:saveInk(id, bounds, strokes)
    local next_document = InkTools.copy(self.saved)
    for _, space in ipairs(next_document.spaces) do
        if space.id == id then
            space.strokes = self:strokes(space, bounds, true, strokes)
            space.basisWidth, space.basisHeight = bounds.right - bounds.left, bounds.bottom - bounds.top
            return self:commit(next_document, true)
        end
    end
    return nil, "Writing space no longer exists"
end
return Spaces
