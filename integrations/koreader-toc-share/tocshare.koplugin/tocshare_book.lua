-- A temporary registry reference: no ReaderUI launch, history update or saved position change.
local Book = {}
function Book.prepare(file)
    local doc
    local ok, text, metadata, coverPath = pcall(function()
        doc = require("document/documentregistry"):openDocument(file)
        if not doc or not doc.loadDocument then
            return nil, "Could not open this EPUB; nothing was shared."
        end
        -- FileManager has no ReaderRolling to initialize a fresh CRe view.
        -- setupDefaultView is a no-op for an already loaded registry document.
        doc:setupDefaultView()
        if not doc:loadDocument() then return nil, "Could not open this EPUB; nothing was shared." end
        if not doc.been_rendered then doc:render() end
        local content, err = require("tocshare_range").extractBook(doc)
        if not content then return nil, err end
        local props = doc:getProps() or {}
        local title = props.display_title or props.title
        if not title or title == "" then title = file:match("([^/]+)$") or "Book" end
        props.title = title
        local info, cover = require("tocshare_metadata").build({document = doc, doc_props = props}, title)
        return content, info, cover
    end)
    if doc then pcall(doc.close, doc) end
    if not ok then return nil, "Could not extract this book; nothing was shared." end
    return text, metadata, coverPath
end
return Book
