local Device = require("device")
local ButtonDialog = require("ui/widget/buttondialog")
local unpack = unpack or table.unpack
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Range = require("tocshare_range")
local _ = require("gettext")

local TocShare = WidgetContainer:extend{
    name = "tocshare",
    is_doc_only = false,
}

function TocShare:canShare()
    return type(Device.canShareText) == "function" and Device:canShareText()
        and type(Device.doShareText) == "function"
end

function TocShare:available()
    local doc = self.ui and self.ui.document
    return doc and self.ui.rolling and self:canShare()
        and type(doc.file) == "string" and doc.file:lower():match("%.epub$") ~= nil
end

function TocShare:init()
    if self.ui and self.ui.addFileDialogButtons and self:canShare() then
        self.ui:addFileDialogButtons("tocshare_book", function(file, is_file)
            if is_file and type(file) == "string" and file:lower():match("%.epub$") then
                return {{ text = _("Share book text"), callback = function()
                    if self.pending_share then return end
                    local menu = self.ui.file_chooser
                    if menu and menu.file_dialog then UIManager:close(menu.file_dialog) end
                    self:shareBook(file)
                end }}
            end
        end)
    end
    self:install()
end

function TocShare:onReaderReady()
    self:install()
end

function TocShare:install()
    local toc = self.ui and self.ui.toc
    if self.closed or self.toc or not toc or not self:available() then return end
    local original = toc.onShowToc
    if type(original) ~= "function" then return end
    self.toc, self.original_show = toc, original
    self.show_wrapper = function(reader_toc, ...)
        local result = original(reader_toc, ...)
        self:attachMenu(reader_toc.toc_menu)
        return result
    end
    -- Wrap this reader instance only; no global Menu or ReaderToc patch.
    toc.onShowToc = self.show_wrapper
end

function TocShare:attachMenu(menu)
    if self.closed or not menu or self.menu == menu then return end
    self:restoreMenu()
    self.menu, self.original_hold = menu, menu.onMenuHold
    local original = self.original_hold
    self.hold_wrapper = function(current_menu, item, ...)
        local handmade = self.ui and self.ui.handmade
        local editing_flows = handmade and handmade.isHandmadeHiddenFlowsEnabled
            and handmade:isHandmadeHiddenFlowsEnabled()
            and handmade.isHandmadeHiddenFlowsEditEnabled and handmade:isHandmadeHiddenFlowsEditEnabled()
        if self.closed or not self:available() or editing_flows or not Device:isTouchDevice() then
            if original then return original(current_menu, item, ...) end
            return false
        end
        if self.pending_share then return true end
        local args = { n = select("#", ...), ... }
        local dialog
        local function choose(callback)
            UIManager:close(dialog)
            self.action_dialog = nil
            if self.closed or current_menu ~= self.menu then return end
            callback()
        end
        if self.action_dialog then UIManager:close(self.action_dialog) end
        local buttons = {
            {{ text = _("Share excerpt"), callback = function()
                choose(function() self:share(item, current_menu) end)
            end }},
        }
        if original then
            buttons[#buttons + 1] = {{ text = _("Show full title"), callback = function()
                choose(function() original(current_menu, item, unpack(args, 1, args.n)) end)
            end }}
        end
        dialog = ButtonDialog:new{ title = item.text or item.title, buttons = buttons }
        self.action_dialog = dialog
        UIManager:show(dialog)
        return true
    end
    menu.onMenuHold = self.hold_wrapper
end

function TocShare:share(item, menu)
    if self.pending_share or self.closed then return end
    local text, label = Range.extract(self.ui.document, self.toc.toc, item)
    if not text then
        UIManager:show(InfoMessage:new{ text = _(label) })
        return
    end
    local metadata, coverPath = require("tocshare_metadata").build(self.ui, label)
    local shareTitle = metadata.title
    if metadata.bookTitle ~= "" then shareTitle = metadata.bookTitle .. " — " .. metadata.title end
    -- Same ordering as KOReader's highlight sharing: close reader UI before Android takes focus.
    if menu.close_callback then menu:close_callback() end
    self:sendText(text, _("Share excerpt"), shareTitle, metadata, coverPath)
end

function TocShare:shareBook(file)
    if self.pending_share or self.closed then return end
    self.pending_share = true
    UIManager:nextTick(function()
        if self.closed then self.pending_share = false; return end
        local text, metadata, coverPath = require("tocshare_book").prepare(file)
        self.pending_share = false
        if not text then UIManager:show(InfoMessage:new{ text = _(metadata) }); return end
        self:sendText(text, _("Share book text"), metadata.title, metadata, coverPath)
    end)
end

function TocShare:sendText(text, reason, title, metadata, coverPath)
    self.pending_share = true
    UIManager:nextTick(function()
        self.pending_share = false
        if self.closed then return end
        local ok, sent = pcall(function()
            if Device.isAndroid and Device:isAndroid() then
                return require("tocshare_android").send(text, reason, title, metadata, coverPath)
            end
            assert(#text <= 256 * 1024, "Large text needs Android file sharing")
            Device:doShareText(text, reason, title, "text/plain")
            return true
        end)
        -- JNI enrichment is optional. Keep ordinary stock sharing as a fallback.
        if (not ok or not sent) and #text <= 256 * 1024 then
            require("logger").warn("TOC share: enriched Android intent failed; using text fallback")
            ok = pcall(Device.doShareText, Device, text, reason, title, "text/plain")
            sent = ok
        end
        if not ok or not sent then
            UIManager:show(InfoMessage:new{ text = _("Android could not open the share sheet. Nothing was truncated.") })
        end
    end)
end

function TocShare:restoreMenu()
    if self.action_dialog then UIManager:close(self.action_dialog) end
    self.action_dialog = nil
    if self.menu and self.menu.onMenuHold == self.hold_wrapper then
        self.menu.onMenuHold = self.original_hold
    end
    self.menu, self.original_hold, self.hold_wrapper = nil, nil, nil
end

function TocShare:onCloseDocument()
    self.closed = true
    self:restoreMenu()
    if self.toc and self.toc.onShowToc == self.show_wrapper then
        self.toc.onShowToc = self.original_show
    end
    self.toc, self.original_show, self.show_wrapper = nil, nil, nil
end

return TocShare
