local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

-- One flat bottom sheet, one header, one paper area. The native tools dock inside
-- this paper; no second inset rectangle or excerpt crowds the writing surface.
local StickyNoteWidget = InputContainer:extend{stop_events_propagation = true}
function StickyNoteWidget:init()
    local screen = Device.screen:getSize()
    local border = math.max(1, Device.screen:scaleBySize(1))
    local width = math.floor(screen.w * .90) - 2 * border
    local height = math.floor(screen.h * .49)
    local header_height = Device.screen:scaleBySize(34)
    local icon_width = Device.screen:scaleBySize(32)
    local text_width = width - 2 * icon_width
    local header = ButtonTable:new{
        width = width, sep_width = 0, show_parent = self,
        buttons = {{
            {text = _("Handwritten note"), width = math.floor(text_width * .6),
                height = header_height, font_size = 16, font_bold = true, callback = function() end},
            {text = _("Text note"), height = header_height, font_size = 16, font_bold = false,
                callback = self.text_callback},
            {text = "⋮", width = icon_width, height = header_height, callback = self.options_callback},
            {icon = "close", width = icon_width, height = header_height,
                icon_width = math.floor(icon_width * .5), icon_height = math.floor(icon_width * .5), callback = self.save_callback},
        }},
    }
    -- FrameContainer records its painted screen position. OverlapGroup alone keeps
    -- its constructor x/y at zero, which would attach native ink at the screen origin.
    self.writing_area = FrameContainer:new{
        padding = 0, margin = 0, bordersize = 0, background = Blitbuffer.COLOR_WHITE,
        OverlapGroup:new{dimen = Geom:new{w = width, h = height}},
    }
    self.frame = FrameContainer:new{
        padding = 0, margin = 0, bordersize = border, radius = 0,
        color = Blitbuffer.COLOR_BLACK, background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{align = "left",
            header,
            LineWidget:new{dimen = Geom:new{w = width, h = border}, background = Blitbuffer.COLOR_BLACK},
            self.writing_area,
        },
    }
    self.active_tab_width = math.floor(text_width * .6)
    self.header_height = header:getSize().h
    self.border = border
    self[1] = BottomContainer:new{dimen = Geom:new{w = screen.w, h = screen.h - math.floor(screen.h * .06)}, self.frame}
end
function StickyNoteWidget:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)
    local d = self.frame.dimen
    if d then
        bb:paintRect(d.x + self.border, d.y + self.border + self.header_height - self.border,
            self.active_tab_width, self.border * 2, Blitbuffer.COLOR_BLACK)
    end
end
function StickyNoteWidget:getHeaderBounds()
    local d = self.frame.dimen
    if not d then return end
    return {left = d.x + self.border, top = d.y + self.border,
        right = d.x + d.w - self.border, bottom = d.y + self.border + self.header_height}
end
function StickyNoteWidget:getWritingBounds()
    local d = self.writing_area.dimen
    if not d then return nil end
    local inset = self.border * 2
    return {left = d.x + inset, top = d.y + inset,
        right = d.x + d.w - inset, bottom = d.y + d.h - inset}
end
function StickyNoteWidget:onShow() UIManager:setDirty(self, "ui") end
function StickyNoteWidget:onCloseWidget() UIManager:setDirty(nil, "ui", self.frame.dimen) end
return StickyNoteWidget
