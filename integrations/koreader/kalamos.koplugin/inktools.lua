-- Page-scoped, device-independent ink operations. Strokes keep their own style so the native
-- daemon replay and KOReader's saved-page renderer use the same width and colour.
local InkTools = {}

function InkTools.points(stroke)
    return stroke and (stroke.points or stroke) or {}
end

function InkTools.copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = InkTools.copy(item) end
    return result
end

local function distance2(x, y, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local length2 = dx * dx + dy * dy
    local t = length2 > 0 and math.max(0, math.min(1,
        ((x - ax) * dx + (y - ay) * dy) / length2)) or 0
    local px, py = ax + t * dx, ay + t * dy
    return (x - px)^2 + (y - py)^2
end

local function nearGesture(point, gesture, radius)
    if #gesture == 0 then return false end
    local limit = radius * radius
    if #gesture == 1 then
        return distance2(point[1], point[2], gesture[1][1], gesture[1][2],
            gesture[1][1], gesture[1][2]) <= limit
    end
    for i = 2, #gesture do
        if distance2(point[1], point[2], gesture[i-1][1], gesture[i-1][2],
            gesture[i][1], gesture[i][2]) <= limit then return true end
    end
    return false
end

local function sampled(points, spacing)
    if #points < 2 then return points end
    local result = { points[1] }
    for index = 2, #points do
        local from, to = points[index - 1], points[index]
        local dx, dy = to[1] - from[1], to[2] - from[2]
        local count = math.min(256, math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy) / spacing)))
        for step = 1, count do
            local point = {}
            for field = 1, 4 do
                point[field] = (from[field] or 0) + ((to[field] or 0) - (from[field] or 0)) * step / count
            end
            result[#result + 1] = point
        end
    end
    return result
end

local function withinPolygon(point, polygon)
    if #polygon < 3 then return false end
    local inside, previous = false, polygon[#polygon]
    for _, current in ipairs(polygon) do
        local x1, y1, x2, y2 = current[1], current[2], previous[1], previous[2]
        if (y1 > point[2]) ~= (y2 > point[2]) and
            point[1] < (x2 - x1) * (point[2] - y1) / (y2 - y1) + x1 then
            inside = not inside
        end
        previous = current
    end
    return inside
end

local function bounds(points)
    local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
    for _, point in ipairs(points) do
        left, top = math.min(left, point[1]), math.min(top, point[2])
        right, bottom = math.max(right, point[1]), math.max(bottom, point[2])
    end
    return left, top, right, bottom
end

function InkTools.selectionBounds(strokes, selected)
    local points = {}
    for index, stroke in ipairs(strokes) do
        if selected[index] then
            for _, point in ipairs(InkTools.points(stroke)) do points[#points + 1] = point end
        end
    end
    if #points == 0 then return nil end
    local left, top, right, bottom = bounds(points)
    return { left = left, top = top, right = right, bottom = bottom }
end

function InkTools.select(strokes, polygon, mode)
    local selected = {}
    if #polygon == 0 then return selected end
    local left, top, right, bottom = bounds(polygon)
    for index, stroke in ipairs(strokes) do
        for _, point in ipairs(InkTools.points(stroke)) do
            local hit
            if mode == "line" then
                hit = nearGesture(point, polygon, 14)
            elseif mode == "circle" then
                local cx, cy = (left + right) / 2, (top + bottom) / 2
                local rx, ry = math.max(1, (right - left) / 2), math.max(1, (bottom - top) / 2)
                hit = ((point[1] - cx) / rx)^2 + ((point[2] - cy) / ry)^2 <= 1
            else
                hit = withinPolygon(point, polygon)
            end
            if hit then selected[index] = true; break end
        end
    end
    return selected
end

function InkTools.erase(strokes, gesture, mode, width)
    local result = {}
    if mode == "stroke" then
        for _, stroke in ipairs(strokes) do
            local hit = false
            local radius = math.max(3, width or 10)
            for _, point in ipairs(sampled(InkTools.points(stroke), radius / 2)) do
                if nearGesture(point, gesture, math.max(3, width or 10)) then hit = true; break end
            end
            if not hit then result[#result + 1] = stroke end
        end
    elseif mode == "range" then
        for _, stroke in ipairs(strokes) do
            local hit = false
            for _, point in ipairs(sampled(InkTools.points(stroke), 3)) do
                if withinPolygon(point, gesture) then hit = true; break end
            end
            if not hit then result[#result + 1] = stroke end
        end
    else -- track erase: split a line into the surviving sections
        local radius = math.max(3, width or 10)
        for _, stroke in ipairs(strokes) do
            local segment = {}
            for _, point in ipairs(sampled(InkTools.points(stroke), radius / 2)) do
                if nearGesture(point, gesture, radius) then
                    if #segment > 0 then
                        local part = InkTools.copy(stroke)
                        if part.points then part.points = segment else part = segment end
                        result[#result + 1] = part
                        segment = {}
                    end
                else
                    segment[#segment + 1] = point
                end
            end
            if #segment > 0 then
                local part = InkTools.copy(stroke)
                if part.points then part.points = segment else part = segment end
                result[#result + 1] = part
            end
        end
    end
    return result
end

function InkTools.delete(strokes, selected)
    local result = {}
    for index, stroke in ipairs(strokes) do
        if not selected[index] then result[#result + 1] = stroke end
    end
    return result
end

function InkTools.transform(strokes, selected, gesture, mode, handle)
    if #gesture < 2 then return strokes end
    local result = InkTools.copy(strokes)
    local first, last = gesture[1], gesture[#gesture]
    local dx, dy = last[1] - first[1], last[2] - first[2]
    local selectedPoints = {}
    for index, stroke in ipairs(result) do
        if selected[index] then
            for _, point in ipairs(InkTools.points(stroke)) do selectedPoints[#selectedPoints + 1] = point end
        end
    end
    if #selectedPoints == 0 then return strokes end
    local left, top, right, bottom = bounds(selectedPoints)
    local horizontal, vertical = (handle or ""):match("([^,]*),([^,]*)")
    local anchor_x = horizontal == "left" and right or left
    local anchor_y = vertical == "top" and bottom or top
    local sx = horizontal == "left" and (1 - dx / math.max(20, right - left))
        or horizontal == "right" and (1 + dx / math.max(20, right - left)) or 1
    local sy = vertical == "top" and (1 - dy / math.max(20, bottom - top))
        or vertical == "bottom" and (1 + dy / math.max(20, bottom - top)) or 1
    sx, sy = math.max(0.1, math.min(8, sx)), math.max(0.1, math.min(8, sy))
    for index, stroke in ipairs(result) do
        if selected[index] then
            for _, point in ipairs(InkTools.points(stroke)) do
                if mode == "resize" then
                    point[1], point[2] = anchor_x + (point[1] - anchor_x) * sx,
                        anchor_y + (point[2] - anchor_y) * sy
                else
                    point[1], point[2] = point[1] + dx, point[2] + dy
                end
            end
            if mode == "resize" and stroke.points then
                stroke.width = math.max(1, math.min(40, (stroke.width or 5) * (sx + sy) / 2))
            end
        end
    end
    return result
end

return InkTools
