-- TOC ranges are document positions, never displayed page numbers or EPUB filenames.
-- Larger text is shared by file reference, never embedded in an Android transaction.
local Range = { MAX_SHARE_BYTES = 100 * 1024 * 1024, MAX_END_STEPS = 100000 }

local function valid_pointer(doc, pointer)
    return type(pointer) == "string" and pointer ~= ""
        and doc:compareXPointers(pointer, pointer) == 0
end

local function depth(row)
    local value = tonumber(row.depth)
    if value and value >= 1 and value % 1 == 0 then return value end
end

function Range.findIndex(toc, item)
    for index, row in ipairs(toc) do
        if row == item then return index end
    end
    -- Search/filter menus may pass a copy. Their index refers to the full TOC.
    local index = tonumber(item.index)
    local row = index and toc[index]
    if row and row.xpointer == item.xpointer and row.title == item.title
        and row.depth == item.depth then return index end
    local found
    for candidate, entry in ipairs(toc) do
        if entry.xpointer == item.xpointer and entry.title == item.title
            and entry.depth == item.depth then
            if found then return nil end -- ambiguous copied entry
            found = candidate
        end
    end
    return found
end

local function document_end(doc, start)
    if not doc.getPageCount or not doc.getPageXPointer or not doc.getNextVisibleChar then
        return nil, "This KOReader version cannot locate the end of the last section."
    end
    -- Begin on the last *internal* page so hidden/nonlinear pages are accounted for.
    -- nextVisibleChar advances through punctuation, Unicode and the end-of-text offset.
    -- A nil successor proves exhaustion; a page's start alone is never the book's end.
    local last_page = doc:getPageCount(true)
    if type(last_page) ~= "number" or last_page < 1 then
        return nil, "The document has no valid final page."
    end
    local cursor = doc:getPageXPointer(last_page, true)
    if not valid_pointer(doc, cursor) then return nil, "The final page has no valid text position." end
    local order = doc:compareXPointers(start, cursor)
    if order == nil then return nil, "The final section has an invalid text position." end
    if order < 0 then cursor = start end
    for _ = 1, Range.MAX_END_STEPS do
        local next_char = doc:getNextVisibleChar(cursor)
        if next_char == nil then return cursor end
        if not valid_pointer(doc, next_char) or doc:compareXPointers(cursor, next_char) ~= 1 then
            return nil, "The document's final text positions are not in reading order."
        end
        cursor = next_char
    end
    return nil, "Could not verify the end of this section; nothing was shared."
end

function Range.extract(doc, toc, item)
    if not doc or not doc.getTextFromXPointers or not doc.compareXPointers then
        return nil, "This document does not support exact text ranges."
    end
    if type(toc) ~= "table" or type(item) ~= "table" then
        return nil, "The selected table-of-contents entry is unavailable."
    end
    -- The engine throws for some malformed XPointers. Never fall back to the whole book.
    local ok, text, label = pcall(function()
        local index = Range.findIndex(toc, item)
        if not index then return nil, "Could not identify this entry in the full table of contents." end
        local selected = toc[index]
        local level = depth(selected)
        local start = selected.xpointer
        if not level or not valid_pointer(doc, start) then
            return nil, "This entry has no valid chapter boundary."
        end
        local finish, next_entry
        for following = index + 1, #toc do
            local next_depth = depth(toc[following])
            if not next_depth then return nil, "The table-of-contents hierarchy is invalid." end
            if next_depth <= level then
                next_entry = toc[following]
                finish = next_entry.xpointer
                break
            end
        end
        if next_entry then
            if not valid_pointer(doc, finish) then
                return nil, "The next section has no valid boundary; nothing was shared."
            end
        else
            local err
            finish, err = document_end(doc, start)
            if not finish then return nil, err end
        end
        if doc:compareXPointers(start, finish) ~= 1 then
            return nil, "This section has empty or out-of-order boundaries; nothing was shared."
        end
        local content = doc:getTextFromXPointers(start, finish, false)
        if type(content) ~= "string" or not content:find("%S") then
            return nil, "No readable text was found in this section."
        end
        if #content > Range.MAX_SHARE_BYTES then
            return nil, "This section is too large for text sharing (100 MiB maximum). Select a smaller subsection. Nothing was truncated."
        end
        return content, selected.title or item.text or "Excerpt"
    end)
    if not ok then return nil, "Could not extract this section; nothing was shared." end
    return text, label
end

-- Whole-book extraction is explicit and independent of publisher TOC coverage.
function Range.extractBook(doc)
    local ok, text, err = pcall(function()
        local start = doc:getPageXPointer(1, true)
        if not valid_pointer(doc, start) then return nil, "The book has no valid starting position." end
        local finish, message = document_end(doc, start)
        if not finish then return nil, message end
        if doc:compareXPointers(start, finish) ~= 1 then return nil, "No readable text was found in this book." end
        local content = doc:getTextFromXPointers(start, finish, false)
        if type(content) ~= "string" or not content:find("%S") then return nil, "No readable text was found in this book." end
        if #content > Range.MAX_SHARE_BYTES then
            return nil, "This book is too large for text sharing (100 MiB maximum). Share a chapter instead. Nothing was truncated."
        end
        return content
    end)
    if not ok then return nil, "Could not extract this book; nothing was shared." end
    return text, err
end

return Range
