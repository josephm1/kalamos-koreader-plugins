-- Small initial action bar; the reader's complete menu remains behind More.
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
return function(Kalamos)
function Kalamos:installCompactSelection()
    local highlight = self.ui.highlight
    if self.compact_selection_wrapper or not highlight.onShowHighlightMenu then return end
    local previous = highlight.onShowHighlightMenu
    self.previous_selection_menu = previous
    local wrapper
    wrapper = function(this, index)
        if self.compact_selection_wrapper ~= wrapper then return previous(this, index) end
        if not this.selected_text then return end
        -- Pen mode owns page input until Read is explicitly selected. A palm/stray
        -- hold must not silently retire capture or open chrome over the native paper.
        if self.pending_canvas_start or self.ink_mode then
            this:onClose()
            return true
        end
        if this.highlight_dialog then UIManager:close(this.highlight_dialog); this.highlight_dialog = nil end
        local dialog
        local function close()
            UIManager:close(dialog)
            if this.highlight_dialog == dialog then this.highlight_dialog = nil end
        end
        local height = Device.screen.scaleBySize and Device.screen:scaleBySize(34) or 40
        local size = math.floor(height * .55)
        dialog = ButtonDialog:new{
            width = math.floor(math.min(Device.screen:getWidth() * .88, height * 8)),
            buttons = {{
                {icon = "kalamos-highlight", icon_width = size, icon_height = size, height = height,
                    hold_callback = function() end,
                    callback = function()
                        close()
                        if index then this:editHighlightColor(index)
                        else this:saveHighlight(); this:onClose() end
                    end},
                {icon = "kalamos-note", icon_width = size, icon_height = size, height = height,
                    callback = function()
                        close()
                        self.resume_page_writing = self.selection_was_writing
                        self.selection_was_writing = nil
                        self:makeStickyHighlight(this, index)
                    end},
                {text = _("Look up"), font_size = 16, font_bold = false, height = height,
                    callback = function() close(); this:lookupDict(index); this:onClose(true) end},
                {text = "⋮", height = height,
                    callback = function() close(); return previous(this, index) end},
            }},
            anchor = function()
                local boxes = index and this:getHighlightVisibleBoxes(index) or this.selected_text and this.selected_text.sboxes
                if not boxes or #boxes == 0 then return end
                local first, last = boxes[1], boxes[#boxes]
                if this.ui.paging then
                    local page = index and this.ui.annotation.annotations[index].pos0.page or this.selected_text.pos0.page
                    first, last = this.view:pageToScreenTransform(page, first), this.view:pageToScreenTransform(page, last)
                end
                if not first or not last then return end
                local pad = math.max(6, math.floor(height * .15))
                local h = dialog:getContentSize().h + pad * 2
                if last.y + last.h + h < Device.screen:getHeight() then return {y = last.y + last.h + pad}, true end
                if first.y > h then return {y = first.y - pad} end
            end,
            tap_close_callback = function() if this.hold_pos then this:clear() end end,
        }
        this.highlight_dialog = dialog
        UIManager:show(dialog, "[ui]")
        return true
    end
    self.compact_selection_wrapper = wrapper
    highlight.onShowHighlightMenu = wrapper
end
function Kalamos:restoreCompactSelection()
    local highlight = self.ui.highlight
    if highlight and highlight.onShowHighlightMenu == self.compact_selection_wrapper then
        highlight.onShowHighlightMenu = self.previous_selection_menu
    end
    self.compact_selection_wrapper, self.previous_selection_menu = nil, nil
end
end
