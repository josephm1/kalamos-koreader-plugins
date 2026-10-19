local InkTools = require("inktools")
local saved = {schema = "kalamos.writing-spaces/v1", bookId = "book", spaces = {}}
local fail, writes, updates = false, 0, 0
package.preload.inkstore = function() return {
    spaces = function() return InkTools.copy(saved) end,
    writeSpaces = function(_, value)
        if fail then return nil, "disk full" end
        saved = InkTools.copy(value); writes = writes + 1; return true
    end,
} end
package.preload['ui/event'] = function() return {new = function(_, name) return name end} end
package.preload.device = function() return {screen = {
    getWidth = function() return 600 end, getHeight = function() return 800 end,
}} end
local viewport_top, block_height, width = 120, 150, 400
local applied_css
local doc = {file = "test.epub", _document = {}, getVisiblePageCount = function() return 1 end,
    setStyleSheet = function(_, _, css) applied_css = css end}
function doc._document:getWritingSpaceInfo(xp)
    if xp == 'unresolved' then return nil end
    return {anchor = "paragraph", tail = "tail", text = "Example paragraph", selector = "body > p:nth-of-type(2)",
        visible = true, left = 50, top = viewport_top, right = 50 + width, bottom = viewport_top + block_height}
end
local ui = {document = doc, rolling = {}, typeset = {css = "epub.css"}, styletweak = {getCssText = function() return "p { color: black }" end},
    handleEvent = function() updates = updates + 1 end}
local Spaces = require("writingspaces")
local spaces = assert(Spaces.open(ui, "book"))
assert(spaces:supported())
spaces:install()
assert(spaces:change('gap', 150, false, 'selected-word'))
assert(saved.spaces[1].anchor == 'paragraph', "store the engine-resolved source boundary")
assert(applied_css:find('p { color: black }',1,true), "preserve ordinary reader CSS")
assert(applied_css:find('body > p:nth-of-type(2) { padding-bottom: 150px',1,true), "real padding, not an overlay")
local space = spaces:find('gap'); local bounds = assert(spaces:bounds(space))
local ink = {{points = {{90,150,1,2}, {130,195,1,3}}, width = 3, color = '#0000ff'}}
assert(spaces:saveInk('gap', bounds, ink))
local local_ink = saved.spaces[1].strokes
assert(local_ink[1].points[1][1] == .1 and local_ink[1].points[1][2] == .2)
local replay = spaces:strokes(spaces:find('gap'), bounds, false)
assert(math.abs(replay[1].points[2][1] - 130) < 1e-8 and replay[1].points[2][2] == 195)
assert(spaces:change('gap', 200, false), "occupied canvas can grow without stretching handwriting")
block_height = 200
local grown = assert(spaces:bounds(spaces:find('gap')))
local grown_ink = spaces:strokes(spaces:find('gap'), grown, false)
assert(grown_ink[1].points[2][2] == 195, "growing a gap must not stretch or move saved ink")
assert(spaces:change('gap', 150, false)); block_height = 150
assert(not spaces:remove('gap', false), "nonempty gap needs explicit delete")
assert(spaces:change('gap', 150, true))
assert(#saved.spaces[1].strokes == 1 and not spaces:bounds(spaces:find('gap')), "collapse preserves ink")
assert(spaces:history(false)); assert(not saved.spaces[1].collapsed)
assert(spaces:history(true)); assert(saved.spaces[1].collapsed)
assert(spaces:change('gap', 150, false))
for _, top in ipairs({-10, 750, 900}) do
    viewport_top = top
    assert(not spaces:bounds(spaces:find('gap')), "offscreen scroll rectangles must not reach native clamping")
end
viewport_top = 120; width = 600
assert(not spaces:bounds(spaces:find('gap')), "horizontal overflow must not change ink basis")
width = 400
fail = true
local before, old_writes, old_updates = InkTools.copy(saved), writes, updates
assert(not spaces:remove('gap', true))
assert(#saved.spaces == 1 and #spaces.saved.spaces == 1 and writes == old_writes and updates == old_updates)
fail = false
assert(spaces:remove('gap', true)); assert(#saved.spaces == 0)
assert(spaces:history(false)); assert(#saved.spaces == 1 and #saved.spaces[1].strokes == 1)
spaces.saved.spaces[1].anchor = 'unresolved'; assert(spaces:css() == '')
assert(#spaces.saved.spaces[1].strokes == 1, "unresolved anchors never delete ink")
doc.file = 'test.pdf'; assert(not spaces:supported() and spaces:css() == '')
spaces:close(); assert(doc.setStyleSheet ~= spaces.stylesheet_wrapper)
print('Writing spaces: paragraph CSS, local ink, history, failure preservation, viewport and capability checks passed')
-- Ink mutations invalidate the old layout redo, and undo contains the new ink coherently.
doc.file='test.epub';spaces.saved.spaces[1].anchor='paragraph';spaces:install()
assert(spaces:change('gap', 200, false));assert(spaces:history(false))
assert(#spaces.redo>0)
assert(spaces:saveInk('gap',bounds,ink));assert(#spaces.redo==0)
assert(spaces:history(false));assert(#spaces.saved.spaces==1)
-- Preview uses actual stylesheet layout without a storage write; cancel restores original CSS/position.
doc.getXPointer=function()return 'reading-position' end
local baseline=writes
assert(spaces:previewChange('new-gap',180,'selected-word'));assert(writes==baseline)
assert(applied_css:find('180px',1,true));spaces:cancelPreview()
assert(not spaces.preview_document and not applied_css:find('180px',1,true))
print('Writing spaces: occupied resize, stale-redo protection and live-preview rollback checks passed')
-- Page-ink viewing removes only the layout overlay. It never collapses/deletes
-- canvases, mutates vectors/history or rewrites the original annotation sidecar.
local stable_doc=InkTools.copy(spaces.saved);local stable_writes=writes
spaces:setOriginalView(true)
assert(spaces:css()=='' and not spaces:bounds(spaces.saved.spaces[1]))
assert(writes==stable_writes and #spaces.saved.spaces==#stable_doc.spaces)
spaces:setOriginalView(false)
assert(spaces:css():find('padding-bottom:',1,true))
local original_recipe=spaces:layoutSnapshot();assert(original_recipe[1].strokes==nil)
spaces:setOriginalView(true,original_recipe)
assert(spaces:css():find('padding-bottom:',1,true))
assert(writes==stable_writes and spaces.saved.spaces[1].height==stable_doc.spaces[1].height)
spaces:setOriginalView(false)
print('Page/canvas coexistence: non-destructive original layout, exact overlay restoration and geometry-only snapshots passed')

-- Canvas changes preserve partial rendering; no whole-book render barrier blocks entry.
local partial, updates_before = true, updates
local wrapped=doc.setStyleSheet
local rendered=false
doc.isPartialRerenderingEnabled=function()return partial end
doc.enablePartialRerendering=function()error('Canvas must preserve the rendering preference')end
doc.getCurrentPos=function()error('No foreground whole-book layout')end
ui.handleEvent=function(_,event)
 assert(event=='UpdatePos' and spaces.layout_changing and partial)
 rendered=true
end
local revision=spaces.layout_revision or 0
spaces:apply();assert(rendered and not spaces.layout_changing and spaces.layout_revision==revision+1)
doc.setStyleSheet=function()error('layout-failed')end
assert(not pcall(function()spaces:apply()end) and not spaces.layout_changing and partial)
print('Fast canvas: preserve partial layout, no whole-book barrier, revision fence and failed mutation cleanup passed')
