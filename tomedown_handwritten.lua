--[[
Handwritten & stylus annotations support for tomedown.koplugin.

Supports freehand notes, margin sketches, and stylus drawings created on
e-readers (Kindle Scribe, Kobo Libra Colour, Kobo Sage, Kobo Elipsa, Onyx Boox,
Android) via KOReader stylus plugins such as `ink-away.koplugin` (`inkaway.lua`
sidecar strokes, shapes, text boxes, and linked `.inkaway` book/highlight
notebooks), `pencil.koplugin` (raster PNG previews and bookmark entries inside
the book's `.sdr` sidecar directory), and `stylus-annotations.koplugin` (raw
vector stroke coordinates).

When an export runs:
1. `handwritten.collect` inspects the document settings and `.sdr` folder
   for freehand items (PNG previews or vector stroke tables).
2. `handwritten.ensureDrawings` copies the PNG previews or serializes vector
   strokes into lightweight, self-contained `.svg` files inside the vault's
   `drawings/` folder (or a custom folder chosen by the reader).
3. Uploaded drawing files follow the same transient rule as book covers:
   once uploaded to the cloud they are cleaned up from the local transfer
   buffer, while local-only setups keep them in the export folder.
]]

local DocSettings = require("docsettings")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local shared = require("tomedown_shared")
local util = require("util")

local handwritten = {}

local DEFAULT_FOLDER = "drawings"
local CLUSTER_GAP_Y = 180
local toc_cache = {}
local inkaway_cache = {}

local function isDocTocReady(doc)
    if type(doc) ~= "table" or doc.is_locked then
        return false
    end
    -- CreDocument (`doc.loadDocument` exists, `doc.info.has_pages == false`)
    -- creates an unloaded C++ LVDocView in `init()`. Calling `getToc()` or
    -- `getPageFromXPointer()` before `render()` (`been_rendered == true`)
    -- dereferences a NULL pointer in `libkoreader-cre.so`.
    if doc.loadDocument ~= nil and not doc.been_rendered then
        return false
    end
    if type(doc.info) == "table" and doc.info.has_pages == false and not doc.been_rendered then
        return false
    end
    return true
end

local function tocCacheKey(file)
    if type(file) ~= "string" or file == "" then
        return nil
    end
    local attr = lfs.attributes(file)
    if type(attr) == "table" and attr.mode == "file" then
        return string.format("%s\31%s\31%s", file, tostring(attr.modification or 0), tostring(attr.size or 0))
    end
    return file
end

local function trim(s)
    if type(s) ~= "string" then
        return nil
    end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then
        return nil
    end
    return s
end

--- Compute the sidecar `.sdr` directory path for `file`.
function handwritten.getSidecarDir(file)
    if type(file) ~= "string" or file == "" then
        return nil
    end
    if DocSettings and type(DocSettings.getSidecarDir) == "function" then
        local ok, sdr = pcall(DocSettings.getSidecarDir, DocSettings, file)
        if ok and type(sdr) == "string" and sdr ~= "" then
            if lfs.attributes(sdr, "mode") == "directory" then
                return sdr
            end
        end
    end
    local fallback = file .. ".sdr"
    if lfs.attributes(fallback, "mode") == "directory" then
        return fallback
    end
    local no_ext = file:gsub("%.[^%.%/]+$", "") .. ".sdr"
    if no_ext ~= fallback and lfs.attributes(no_ext, "mode") == "directory" then
        return no_ext
    end
    return nil
end

--- The relative path a drawing occupies inside the vault (POSIX "/").
-- @string book_leaf sanitized base filename of the book (without subdir)
-- @string drawing_id short identifier (e.g. "p42-1")
-- @string ext file extension ("png" or "svg")
-- @string folder target subfolder name (defaults to "drawings")
function handwritten.relPath(book_leaf, drawing_id, ext, folder)
    local sub = (type(folder) == "string" and folder ~= "") and folder or DEFAULT_FOLDER
    local clean_ext = (type(ext) == "string" and ext ~= "") and ext:gsub("^%.", "") or "png"
    local leaf = tostring(book_leaf or "book"):match("([^/]+)$") or "book"
    local id = tostring(drawing_id or "1"):gsub("[^%w_%-]", "-")
    return sub .. "/" .. leaf .. " - " .. id .. "." .. clean_ext
end

--- Is this absolute path an exported drawing inside `dir`?
function handwritten.isDrawingPath(path, dir, folder)
    local sub = (type(folder) == "string" and folder ~= "") and folder or DEFAULT_FOLDER
    local prefix = dir .. "/" .. sub .. "/"
    return type(path) == "string" and path:sub(1, #prefix) == prefix
end

--- Extract point coordinates `(x, y)` from either `{ x = 10, y = 20 }` or `{ 10, 20 }`.
local function pointXY(pt)
    if type(pt) ~= "table" then
        return nil, nil
    end
    local x = tonumber(pt.x or pt[1])
    local y = tonumber(pt.y or pt[2])
    if x and y then
        return x, y
    end
    return nil, nil
end

local function formatColor(c)
    if type(c) == "string" and c ~= "" then
        return c
    end
    if type(c) == "table" then
        local r, g, b = tonumber(c[1] or c.r), tonumber(c[2] or c.g), tonumber(c[3] or c.b)
        if r and g and b then
            r = math.max(0, math.min(255, math.floor(r + 0.5)))
            g = math.max(0, math.min(255, math.floor(g + 0.5)))
            b = math.max(0, math.min(255, math.floor(b + 0.5)))
            return string.format("#%02x%02x%02x", r, g, b)
        end
    end
    return "#1e1e1e"
end

--- Normalize a stroke entry into `{ points = { {x, y}, ... }, width = number, color = string, ... }`.
local function normalizeStroke(stroke)
    if type(stroke) ~= "table" then
        return nil
    end
    local raw_pts = type(stroke.points) == "table" and stroke.points
        or (type(stroke.path) == "table" and stroke.path)
        or stroke
    local pts = {}
    for __, pt in ipairs(raw_pts) do
        local x, y = pointXY(pt)
        if x and y then
            pts[#pts + 1] = { x = x, y = y }
        end
    end
    if #pts == 0 then
        return nil
    end
    local width = tonumber(stroke.width or stroke.size or stroke.stroke_width) or 2.5
    if width <= 0 then
        width = 2.5
    end
    local opacity = tonumber(stroke.opacity)
    if not opacity then
        local alpha = tonumber(stroke.alpha)
        if alpha and alpha > 0 and alpha < 255 then
            opacity = alpha / 255
        end
    end
    if opacity and (opacity <= 0 or opacity >= 0.995) then
        opacity = nil
    end
    return {
        points = pts,
        width = width,
        color = formatColor(stroke.color),
        opacity = opacity,
        closed = stroke.closed == true,
        fill = stroke.fill == true,
    }
end

local function fmtCoord(n)
    local rounded = math.floor(n * 10 + 0.5) / 10
    if rounded == math.floor(rounded) then
        return tostring(math.floor(rounded))
    end
    return string.format("%.1f", rounded)
end

local function adler32Hex(s)
    if type(s) ~= "string" or s == "" then
        return nil
    end
    local s1, s2 = 1, 0
    for i = 1, #s do
        s1 = (s1 + s:byte(i)) % 65521
        s2 = (s2 + s1) % 65521
    end
    return string.format("%04x%04x", s2, s1)
end

local function readFileBytes(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local bytes = f:read("*a")
    f:close()
    return bytes
end

--- Load a serialized Lua data table (`return { ... }`) in an empty-env sandbox
-- compatible with Lua 5.1, LuaJIT (including InkAway split-constant chunks), and Lua 5.4.
local function loadLuaData(str)
    if type(str) ~= "string" or str == "" or str:byte(1) == 27 then
        return nil
    end
    local chunk
    if setfenv and loadstring then
        chunk = loadstring(str, "inkaway")
        if chunk then
            setfenv(chunk, {})
        end
    else
        chunk = load(str, "inkaway", "t", {})
    end
    if not chunk then
        return nil
    end
    local ok, data = pcall(chunk)
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

--- Serialize a list of vector strokes into a standalone SVG string.
-- Automatically computes a tight bounding box with padding when explicit
-- canvas dimensions (`width`, `height`) are not provided.
-- @tparam table strokes list of strokes
-- @tparam[opt] number width canvas width
-- @tparam[opt] number height canvas height
-- @treturn string|nil SVG document string, or nil when no valid points exist
function handwritten.renderStrokesToSvg(strokes, width, height)
    if type(strokes) ~= "table" or #strokes == 0 then
        return nil
    end
    local norm_strokes = {}
    local single = normalizeStroke(strokes)
    if single and type(strokes[1]) == "table" and (strokes[1].x ~= nil or type(strokes[1][1]) == "number") then
        -- `strokes` was passed as a single stroke's point array
        norm_strokes[1] = single
    else
        for __, s in ipairs(strokes) do
            local ns = normalizeStroke(s)
            if ns then
                norm_strokes[#norm_strokes + 1] = ns
            end
        end
    end
    if #norm_strokes == 0 then
        return nil
    end

    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge
    local max_w = 2.5
    for __, s in ipairs(norm_strokes) do
        if s.width > max_w then
            max_w = s.width
        end
        for __, pt in ipairs(s.points) do
            if pt.x < min_x then min_x = pt.x end
            if pt.y < min_y then min_y = pt.y end
            if pt.x > max_x then max_x = pt.x end
            if pt.y > max_y then max_y = pt.y end
        end
    end
    if min_x == math.huge then
        return nil
    end

    local pad = math.ceil(max_w * 2 + 12)
    local vx, vy, vw, vh
    if type(width) == "number" and width > 0 and type(height) == "number" and height > 0 then
        vx, vy = 0, 0
        vw, vh = math.ceil(width), math.ceil(height)
    else
        vx = math.floor(min_x - pad)
        vy = math.floor(min_y - pad)
        vw = math.max(32, math.ceil((max_x - min_x) + pad * 2))
        vh = math.max(32, math.ceil((max_y - min_y) + pad * 2))
    end

    local lines = {
        string.format(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="%d %d %d %d" width="%d" height="%d">',
            vx, vy, vw, vh, vw, vh),
    }
    for __, s in ipairs(norm_strokes) do
        local color = tostring(s.color):gsub('"', "")
        local w_str = fmtCoord(s.width)
        local op_attr = s.opacity and string.format(' opacity="%.2f"', s.opacity) or ""
        if #s.points == 1 then
            local p = s.points[1]
            lines[#lines + 1] = string.format(
                '  <circle cx="%s" cy="%s" r="%s" fill="%s"%s/>',
                fmtCoord(p.x), fmtCoord(p.y), fmtCoord(s.width / 2), color, op_attr)
        else
            local d = { "M " .. fmtCoord(s.points[1].x) .. " " .. fmtCoord(s.points[1].y) }
            for i = 2, #s.points do
                d[#d + 1] = "L " .. fmtCoord(s.points[i].x) .. " " .. fmtCoord(s.points[i].y)
            end
            if s.closed and #s.points >= 3 then
                d[#d + 1] = "Z"
            end
            if s.fill and s.closed then
                lines[#lines + 1] = string.format(
                    '  <path d="%s" fill="%s" stroke="none"%s/>',
                    table.concat(d, " "), color, op_attr)
            else
                lines[#lines + 1] = string.format(
                    '  <path d="%s" fill="none" stroke="%s" stroke-width="%s" stroke-linecap="round" stroke-linejoin="round"%s/>',
                    table.concat(d, " "), color, w_str, op_attr)
            end
        end
    end
    lines[#lines + 1] = "</svg>\n"
    return table.concat(lines, "\n")
end

--- Resolve an image path (absolute or relative to `sdr_dir`) if it exists on disk.
local function resolveImageFile(img_path, sdr_dir)
    if type(img_path) ~= "string" or img_path == "" then
        return nil
    end
    if lfs.attributes(img_path, "mode") == "file" then
        return img_path
    end
    if sdr_dir then
        local in_sdr = sdr_dir .. "/" .. img_path:gsub("^[/\\]+", "")
        if lfs.attributes(in_sdr, "mode") == "file" then
            return in_sdr
        end
        local in_pencil = sdr_dir .. "/pencil/" .. img_path:gsub("^[/\\]+", "")
        if lfs.attributes(in_pencil, "mode") == "file" then
            return in_pencil
        end
    end
    return nil
end

--- Scan `sdr_dir` (and `sdr_dir/pencil`) for raster/vector drawing files.
-- Returns a sorted list of `{ path = abs_path, name = filename, page = page_or_nil, ext = ext }`.
local function scanSdrDrawings(sdr_dir)
    local found = {}
    if not sdr_dir or lfs.attributes(sdr_dir, "mode") ~= "directory" then
        return found
    end
    local function scanFolder(folder, require_prefix)
        if lfs.attributes(folder, "mode") ~= "directory" then
            return
        end
        local ok_iter, iter, obj = pcall(lfs.dir, folder)
        if not ok_iter or not iter then
            return
        end
        for entry in iter, obj do
            if entry ~= "." and entry ~= ".." then
                local lower = entry:lower()
                local ext = lower:match("%.(png)$") or lower:match("%.(svg)$") or lower:match("%.(jpg)$")
                if ext then
                    local is_pencil = not require_prefix
                        or lower:match("^pencil")
                        or lower:match("^drawing")
                        or lower:match("^stylus")
                        or lower:match("^handwritten")
                        or lower:match("^ink")
                    if is_pencil then
                        local full = folder .. "/" .. entry
                        if lfs.attributes(full, "mode") == "file" then
                            local pnum = tonumber(
                                lower:match("page[_%-]?(%d+)")
                                or lower:match("p(%d+)")
                                or lower:match("[_%-](%d+)"))
                            found[#found + 1] = {
                                path = full,
                                name = entry,
                                page = pnum,
                                ext = ext,
                                mtime = lfs.attributes(full, "modification") or 0,
                            }
                        end
                    end
                end
            end
        end
    end
    scanFolder(sdr_dir, true)
    scanFolder(sdr_dir .. "/pencil", false)
    scanFolder(sdr_dir .. "/drawings", false)
    scanFolder(sdr_dir .. "/stylus", false)
    table.sort(found, function(a, b)
        if (a.page or 0) ~= (b.page or 0) then
            return (a.page or 0) < (b.page or 0)
        end
        return a.name < b.name
    end)
    return found
end

--- Check if a bookmark/annotation note matches `pencil.koplugin`'s marker
-- ("Pencil annotation on page X").
function handwritten.isPencilBookmarkNote(text)
    if type(text) ~= "string" then
        return false
    end
    local lower = text:lower()
    return lower:match("^pencil annotation") ~= nil
        or lower:match("^handwritten annotation") ~= nil
        or lower:match("^stylus annotation") ~= nil
end

--- Convert an InkAway `op` (`ink-away.koplugin`) at offset `(ox, oy)` into
-- vector strokes or extracted text paragraphs.
local function flatPtsToPoints(flat, ox, oy)
    local pts = {}
    if type(flat) ~= "table" then
        return pts
    end
    for i = 1, #flat - 1, 2 do
        local x, y = tonumber(flat[i]), tonumber(flat[i + 1])
        if x and y then
            pts[#pts + 1] = { x = x + ox, y = y + oy }
        end
    end
    return pts
end

local function inkAwayEffectiveOpacity(style, alpha)
    local a = tonumber(alpha) or 255
    if a <= 0 then
        return 0
    end
    if style == "highlighter" then
        return 0.42 * (a / 255)
    elseif style == "wash" then
        return 0.65 * (a / 255)
    elseif style == "felttip" then
        return 0.78 * (a / 255)
    end
    if a < 255 then
        return a / 255
    end
    return nil
end

local function splitPtsByBreaks(flat, breaks)
    if type(flat) ~= "table" or #flat < 2 then
        return {}
    end
    if type(breaks) ~= "table" or #breaks == 0 then
        return { flat }
    end
    local out = {}
    local start = 1
    local n = math.floor(#flat / 2)
    for k = 1, #breaks + 1 do
        local stop = (tonumber(breaks[k]) or (n + 1)) - 1
        if stop >= start then
            local p = {}
            for i = start, stop do
                p[#p + 1] = flat[2 * i - 1]
                p[#p + 1] = flat[2 * i]
            end
            if #p >= 2 then
                out[#out + 1] = p
            end
        end
        start = math.max(start, stop + 1)
    end
    return out
end

local function appendWithSymmetry(dst, generated, sym, cw, ch)
    for __, s in ipairs(generated) do
        dst[#dst + 1] = s
    end
    if not sym or sym == "off" or not cw or cw <= 0 or not ch or ch <= 0 then
        return
    end
    local flips
    if sym == "vert" then
        flips = { { true, false } }
    elseif sym == "horiz" then
        flips = { { false, true } }
    elseif sym == "quad" then
        flips = { { true, false }, { false, true }, { true, true } }
    else
        return
    end
    for __, fl in ipairs(flips) do
        local fx, fy = fl[1], fl[2]
        for ___, s in ipairs(generated) do
            local mpts = {}
            for i, pt in ipairs(s.points) do
                mpts[i] = {
                    x = fx and (cw - 1 - pt.x) or pt.x,
                    y = fy and (ch - 1 - pt.y) or pt.y,
                }
            end
            dst[#dst + 1] = {
                points = mpts,
                width = s.width,
                color = s.color,
                opacity = s.opacity,
                alpha = s.alpha,
                closed = s.closed,
                fill = s.fill,
            }
        end
    end
end

local function inkAwayShapeStrokes(op, ox, oy)
    local p = op.pts
    if type(p) ~= "table" or #p < 4 then
        return {}
    end
    local x0, y0, x1, y1 = tonumber(p[1]), tonumber(p[2]), tonumber(p[3]), tonumber(p[4])
    if not (x0 and y0 and x1 and y1) then
        return {}
    end
    local kind = op.shape
    local poly, closed = {}, true
    if kind == "line" then
        poly = { x0, y0, x1, y1 }
        closed = false
    elseif kind == "curve" then
        local cx = tonumber(p[5]) or (x0 + x1) / 2
        local cy = tonumber(p[6]) or (y0 + y1) / 2
        for i = 0, 24 do
            local t = i / 24
            local mt = 1 - t
            local a, b, c = mt * mt, 2 * mt * t, t * t
            poly[#poly + 1] = a * x0 + b * cx + c * x1
            poly[#poly + 1] = a * y0 + b * cy + c * y1
        end
        closed = false
    elseif kind == "rect" then
        local ax0, ay0 = math.min(x0, x1), math.min(y0, y1)
        local ax1, ay1 = math.max(x0, x1), math.max(y0, y1)
        poly = { ax0, ay0, ax1, ay0, ax1, ay1, ax0, ay1 }
    elseif kind == "triangle" then
        local ax0, ay0 = math.min(x0, x1), math.min(y0, y1)
        local ax1, ay1 = math.max(x0, x1), math.max(y0, y1)
        poly = { (ax0 + ax1) / 2, ay0, ax0, ay1, ax1, ay1 }
    elseif kind == "ellipse" then
        local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        local rx, ry = math.abs(x1 - x0) / 2, math.abs(y1 - y0) / 2
        local steps = math.max(24, math.min(64, math.floor(rx + ry)))
        for i = 0, steps - 1 do
            local a = (i / steps) * 2 * math.pi
            poly[#poly + 1] = cx + rx * math.cos(a)
            poly[#poly + 1] = cy + ry * math.sin(a)
        end
    elseif kind == "poly" then
        for i = 1, #p do
            poly[i] = tonumber(p[i]) or 0
        end
        closed = op.closed == true
    else
        return {}
    end

    local ang = tonumber(op.angle)
    if ang and ang ~= 0 and #poly >= 2 then
        local cx, cy
        if kind == "poly" then
            local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
            for i = 1, #poly - 1, 2 do
                if poly[i] < minx then minx = poly[i] end
                if poly[i] > maxx then maxx = poly[i] end
                if poly[i + 1] < miny then miny = poly[i + 1] end
                if poly[i + 1] > maxy then maxy = poly[i + 1] end
            end
            cx, cy = (minx + maxx) / 2, (miny + maxy) / 2
        else
            cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        end
        local ca, sa = math.cos(ang), math.sin(ang)
        for i = 1, #poly - 1, 2 do
            local dx, dy = poly[i] - cx, poly[i + 1] - cy
            poly[i] = cx + dx * ca - dy * sa
            poly[i + 1] = cy + dx * sa + dy * ca
        end
    end

    local pts = flatPtsToPoints(poly, ox, oy)
    if #pts == 0 then
        return {}
    end
    local color = formatColor(op.color)
    local width = tonumber(op.width) or 2
    local op_opacity = inkAwayEffectiveOpacity(op.style, op.alpha)
    local filled = (op.fill == true and closed)
    local out = {}
    if not filled and closed and type(op.fill_color) == "table" then
        out[#out + 1] = {
            points = pts,
            width = width,
            color = formatColor(op.fill_color),
            opacity = inkAwayEffectiveOpacity(nil, op.fill_alpha or op.alpha),
            closed = true,
            fill = true,
        }
    end
    if filled or op.color ~= nil or type(op.fill_color) ~= "table" then
        out[#out + 1] = {
            points = pts,
            width = width,
            color = color,
            opacity = op_opacity,
            closed = closed,
            fill = filled,
        }
    end
    if not filled and (op.arrow == "end" or op.arrow == "both")
            and (kind == "line" or kind == "curve") and #poly >= 4 then
        local n = math.floor(#poly / 2)
        local head = tonumber(op.head) or math.max(12, width * 3)
        local ca, sa = math.cos(0.4887), math.sin(0.4887)
        local function addTip(txi, tyi, fxi, fyi)
            local tx, ty = poly[txi], poly[tyi]
            local dx, dy = tx - poly[fxi], ty - poly[fyi]
            local len = math.sqrt(dx * dx + dy * dy)
            if len < 1e-3 then
                return
            end
            dx, dy = dx / len, dy / len
            out[#out + 1] = {
                points = {
                    { x = tx + ox, y = ty + oy },
                    { x = tx - head * (dx * ca - dy * sa) + ox, y = ty - head * (dx * sa + dy * ca) + oy },
                },
                width = width,
                color = color,
                opacity = op_opacity,
            }
            out[#out + 1] = {
                points = {
                    { x = tx + ox, y = ty + oy },
                    { x = tx - head * (dx * ca + dy * sa) + ox, y = ty + head * (dx * sa - dy * ca) + oy },
                },
                width = width,
                color = color,
                opacity = op_opacity,
            }
        end
        addTip(2 * n - 1, 2 * n, 2 * n - 3, 2 * n - 2)
        if op.arrow == "both" then
            addTip(1, 2, 3, 4)
        end
    end
    return out
end

local function inkAwayFillStrokes(op, ox, oy)
    local runs = op.runs
    if type(runs) ~= "table" or #runs < 3 then
        return {}
    end
    local out = {}
    local color = formatColor(op.color)
    local op_opacity = inkAwayEffectiveOpacity(nil, op.alpha)
    local row_step = math.max(1, math.floor((#runs / 3) / 1000))
    local stride = 3 * row_step
    local stroke_w = math.max(1.2, row_step * 1.1)
    for i = 1, #runs - 2, stride do
        local rx, ry, rlen = tonumber(runs[i]), tonumber(runs[i + 1]), tonumber(runs[i + 2])
        if rx and ry and rlen and rlen > 0 then
            local pts
            if rlen <= 1 then
                pts = { { x = rx + ox, y = ry + oy } }
            else
                pts = {
                    { x = rx + ox, y = ry + oy },
                    { x = rx + rlen - 1 + ox, y = ry + oy },
                }
            end
            out[#out + 1] = {
                points = pts,
                width = stroke_w,
                color = color,
                opacity = op_opacity,
            }
        end
    end
    return out
end

local function inkAwayExtractText(op)
    if type(op.paras) ~= "table" then
        return nil
    end
    local lines = {}
    local num_idx = 0
    for __, para in ipairs(op.paras) do
        if type(para) == "table" and type(para.spans) == "table" then
            local parts = {}
            for ___, span in ipairs(para.spans) do
                if type(span) == "table" and type(span.t) == "string" then
                    parts[#parts + 1] = span.t
                end
            end
            local line = trim(table.concat(parts))
            if line then
                if para.bullet == "number" then
                    num_idx = num_idx + 1
                    line = tostring(num_idx) .. ". " .. line
                elseif para.bullet == "disc" then
                    num_idx = 0
                    line = "• " .. line
                elseif para.bullet == "check" then
                    num_idx = 0
                    line = (para.checked and "[x] " or "[ ] ") .. line
                else
                    num_idx = 0
                end
                lines[#lines + 1] = line
            end
        end
    end
    if #lines == 0 then
        return nil
    end
    return table.concat(lines, "\n")
end

local function inkAwayAppendOp(strokes, texts, op, ox, oy, cw, ch)
    if type(op) ~= "table" or op.hidden then
        return
    end
    local kind = op.kind
    if kind == "erase" or kind == "smudge" or kind == "link" or kind == "image" then
        return
    end
    if kind == "text" then
        local txt = inkAwayExtractText(op)
        if txt then
            texts[#texts + 1] = txt
        end
        return
    end
    if kind == "fill" then
        appendWithSymmetry(strokes, inkAwayFillStrokes(op, ox, oy), op.sym, cw, ch)
        return
    end
    if kind == "shape" then
        appendWithSymmetry(strokes, inkAwayShapeStrokes(op, ox, oy), op.sym, cw, ch)
        return
    end
    if (kind == nil or kind == "ink") and type(op.pts) == "table" and #op.pts >= 2 then
        local generated = {}
        local color = formatColor(op.color)
        local width = tonumber(op.width) or 2.5
        local op_opacity = inkAwayEffectiveOpacity(op.style, op.alpha)
        for __, seg_pts in ipairs(splitPtsByBreaks(op.pts, op.breaks)) do
            local pts = flatPtsToPoints(seg_pts, ox, oy)
            if #pts > 0 then
                generated[#generated + 1] = {
                    points = pts,
                    width = width,
                    color = color,
                    opacity = op_opacity,
                }
            end
        end
        appendWithSymmetry(strokes, generated, op.sym, cw, ch)
    end
end

local function resolveInkAwayNotebookPath(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    if lfs.attributes(path, "mode") == "file" then
        return path
    end
    local roots = {}
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        local custom = G_reader_settings:readSetting("inkaway_library_dir")
        if type(custom) == "string" and custom ~= "" then
            roots[#roots + 1] = custom
        end
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage then
        if type(DataStorage.getDataDir) == "function" then
            roots[#roots + 1] = DataStorage:getDataDir() .. "/ink away"
        end
        if type(DataStorage.getSettingsDir) == "function" then
            roots[#roots + 1] = DataStorage:getSettingsDir() .. "/ink away"
        end
    end
    local leaf = path:match("([^/\\]+)$")
    for __, root in ipairs(roots) do
        if leaf then
            local in_bn = root .. "/Book notes/" .. leaf
            if lfs.attributes(in_bn, "mode") == "file" then
                return in_bn
            end
            local in_root = root .. "/" .. leaf
            if lfs.attributes(in_root, "mode") == "file" then
                return in_root
            end
        end
    end
    return nil
end

local function loadInkAwaySidecar(sdr_dir)
    if not sdr_dir then
        return nil, nil
    end
    for __, name in ipairs({ "inkaway.lua", "inkaway.lua.old" }) do
        local p = sdr_dir .. "/" .. name
        if lfs.attributes(p, "mode") == "file" then
            local data = loadLuaData(readFileBytes(p))
            if data and type(data.items) == "table" then
                return data, p
            end
        end
    end
    return nil, nil
end

local function xpTokens(s)
    local out = {}
    local i = 1
    while i <= #s do
        local d0, d1 = s:find("%d+", i)
        if not d0 then
            out[#out + 1] = { text = s:sub(i) }
            break
        end
        if d0 > i then
            out[#out + 1] = { text = s:sub(i, d0 - 1) }
        end
        out[#out + 1] = { num = tonumber(s:sub(d0, d1)) }
        i = d1 + 1
    end
    return out
end

local function xpCompare(a, b)
    local n = math.min(#a, #b)
    for k = 1, n do
        local x, y = a[k], b[k]
        if x.num and y.num then
            if x.num ~= y.num then
                return x.num < y.num and -1 or 1
            end
        elseif x.num or y.num then
            return x.num and -1 or 1
        elseif x.text ~= y.text then
            return x.text < y.text and -1 or 1
        end
    end
    if #a == #b then
        return 0
    end
    return #a < #b and -1 or 1
end

local function parseXpBlock(xp)
    if type(xp) ~= "string" or xp == "" then
        return nil
    end
    local char_ofs = tonumber(xp:match("%.(%d+)$")) or 0
    local elem = xp:gsub("/text%(%).*$", ""):gsub("%.%d+$", "")
    local parent, leaf = elem:match("^(.*)/([^/]+)$")
    if not parent or not leaf then
        return { parent = elem, tag = "p", bidx = 1, is_heading = false, char_ofs = char_ofs }
    end
    local tag, idx_s = leaf:match("^([^%[]+)%[(%d+)%]$")
    tag = (tag or leaf):lower()
    local is_heading = tag:match("^h[1-6]$") ~= nil
    local bidx = idx_s and tonumber(idx_s) or (is_heading and 0 or 1)
    return {
        parent = parent,
        tag = tag,
        bidx = bidx,
        is_heading = is_heading,
        char_ofs = char_ofs,
    }
end

local function strokeListBoundsY(strokes)
    local min_y, max_y = math.huge, -math.huge
    for __, s in ipairs(strokes) do
        local hw = (tonumber(s.width) or 2) / 2
        for ___, pt in ipairs(s.points or {}) do
            if pt.y - hw < min_y then min_y = pt.y - hw end
            if pt.y + hw > max_y then max_y = pt.y + hw end
        end
    end
    if min_y == math.huge then
        return nil, nil
    end
    return min_y, max_y
end

local function clusterPlacedPieces(pieces)
    local clusters = {}
    for __, pc in ipairs(pieces) do
        local merged_idx = nil
        for ci, cl in ipairs(clusters) do
            if pc.min_y and cl.min_y then
                if pc.min_y <= cl.max_y + CLUSTER_GAP_Y and cl.min_y <= pc.max_y + CLUSTER_GAP_Y then
                    if not merged_idx then
                        merged_idx = ci
                        if pc.min_y < cl.min_y then cl.min_y = pc.min_y end
                        if pc.max_y > cl.max_y then cl.max_y = pc.max_y end
                        for ___, s in ipairs(pc.strokes) do cl.strokes[#cl.strokes + 1] = s end
                        for ___, t in ipairs(pc.texts) do cl.texts[#cl.texts + 1] = t end
                        if cl.pageno == 0 and pc.pageno > 0 then cl.pageno = pc.pageno end
                        if pc.pos0 then
                            if not cl.pos0 or xpCompare(xpTokens(pc.pos0), xpTokens(cl.pos0)) < 0 then
                                cl.pos0 = pc.pos0
                            end
                        end
                    else
                        -- pc bridged two existing clusters: fold ci into merged_idx
                        local target = clusters[merged_idx]
                        if cl.min_y < target.min_y then target.min_y = cl.min_y end
                        if cl.max_y > target.max_y then target.max_y = cl.max_y end
                        for ___, s in ipairs(cl.strokes) do target.strokes[#target.strokes + 1] = s end
                        for ___, t in ipairs(cl.texts) do target.texts[#target.texts + 1] = t end
                        if target.pageno == 0 and cl.pageno > 0 then target.pageno = cl.pageno end
                        if cl.pos0 and (not target.pos0 or xpCompare(xpTokens(cl.pos0), xpTokens(target.pos0)) < 0) then
                            target.pos0 = cl.pos0
                        end
                        cl.folded = true
                    end
                end
            elseif not pc.min_y and not cl.min_y then
                merged_idx = ci
                for ___, t in ipairs(pc.texts) do cl.texts[#cl.texts + 1] = t end
                break
            end
        end
        if not merged_idx then
            local st_copy, tx_copy = {}, {}
            for i, s in ipairs(pc.strokes) do st_copy[i] = s end
            for i, t in ipairs(pc.texts) do tx_copy[i] = t end
            clusters[#clusters + 1] = {
                pageno = pc.pageno or 0,
                pos0 = pc.pos0,
                is_fixed = pc.is_fixed,
                id_prefix = pc.id_prefix,
                min_y = pc.min_y,
                max_y = pc.max_y,
                strokes = st_copy,
                texts = tx_copy,
            }
        end
    end
    local out = {}
    for __, cl in ipairs(clusters) do
        if not cl.folded then
            out[#out + 1] = cl
        end
    end
    table.sort(out, function(a, b)
        return (a.min_y or 0) < (b.min_y or 0)
    end)
    return out
end

local function detectScreenSize(doc, nb)
    local w, h
    if type(doc) == "table" then
        if type(doc.getScreenWidth) == "function" then
            local ok_w, rw = pcall(doc.getScreenWidth, doc)
            if ok_w and tonumber(rw) and tonumber(rw) > 0 then w = tonumber(rw) end
        end
        if type(doc.getScreenHeight) == "function" then
            local ok_h, rh = pcall(doc.getScreenHeight, doc)
            if ok_h and tonumber(rh) and tonumber(rh) > 0 then h = tonumber(rh) end
        end
    end
    if not w or not h then
        local ok_cc, CanvasContext = pcall(require, "document/canvascontext")
        if ok_cc and type(CanvasContext) == "table" then
            if not w and type(CanvasContext.getWidth) == "function" then
                local ok_w, rw = pcall(CanvasContext.getWidth, CanvasContext)
                if ok_w and tonumber(rw) and tonumber(rw) > 0 then w = tonumber(rw) end
            end
            if not h and type(CanvasContext.getHeight) == "function" then
                local ok_h, rh = pcall(CanvasContext.getHeight, CanvasContext)
                if ok_h and tonumber(rh) and tonumber(rh) > 0 then h = tonumber(rh) end
            end
        end
    end
    if type(nb) == "table" then
        if not w and tonumber(nb.w) and tonumber(nb.w) > 0 then w = tonumber(nb.w) end
        if not h and tonumber(nb.h) and tonumber(nb.h) > 0 then h = tonumber(nb.h) end
    end
    return w or 800, h or 1200
end

local function openRenderedReflowDoc(file, ds)
    if type(file) ~= "string" or file == "" or lfs.attributes(file, "mode") ~= "file" then
        return nil
    end
    local ok_dr, DocumentRegistry = pcall(require, "document/documentregistry")
    if not (ok_dr and DocumentRegistry and type(DocumentRegistry.openDocument) == "function") then
        return nil
    end
    local ok_doc, temp_doc = pcall(DocumentRegistry.openDocument, DocumentRegistry, file)
    if not (ok_doc and temp_doc) then
        return nil
    end
    if temp_doc.is_locked then
        if type(temp_doc.close) == "function" then pcall(temp_doc.close, temp_doc) end
        return nil
    end
    if temp_doc.loadDocument ~= nil and not temp_doc.been_rendered then
        if type(temp_doc.setupDefaultView) == "function" then
            pcall(temp_doc.setupDefaultView, temp_doc)
        end
        -- Prevent offscreen rendering from overwriting ReaderUI's on-disk cr3cache
        if type(temp_doc._document) == "userdata" or type(temp_doc._document) == "table" then
            pcall(function()
                temp_doc._document:setIntProperty("crengine.cache.filesize.min", 0x7FFFFFFF)
            end)
        end
        if ds and type(ds.readSetting) == "function" then
            local dom_v = ds:readSetting("cre_dom_version")
            if dom_v and type(temp_doc.requestDomVersion) == "function" then
                pcall(temp_doc.requestDomVersion, temp_doc, dom_v)
            end
            local fface = ds:readSetting("font_face")
            if type(fface) == "string" and fface ~= "" and type(temp_doc.setFontFace) == "function" then
                pcall(temp_doc.setFontFace, temp_doc, fface)
            end
            local fsize = tonumber(ds:readSetting("font_size"))
            if fsize and fsize > 0 and type(temp_doc.setFontSize) == "function" then
                local ok_dev, Device = pcall(require, "device")
                if ok_dev and Device and Device.screen and type(Device.screen.scaleBySize) == "function" then
                    local ok_s, scaled = pcall(Device.screen.scaleBySize, Device.screen, fsize)
                    if ok_s and tonumber(scaled) then fsize = tonumber(scaled) end
                end
                pcall(temp_doc.setFontSize, temp_doc, fsize)
            end
            local h_margins = ds:readSetting("copt_h_page_margins")
            local t_margin = tonumber(ds:readSetting("copt_t_page_margin"))
            local b_margin = tonumber(ds:readSetting("copt_b_page_margin"))
            if type(h_margins) == "table" and h_margins[1] and h_margins[2]
                    and t_margin and b_margin and type(temp_doc.setPageMargins) == "function" then
                pcall(temp_doc.setPageMargins, temp_doc, h_margins[1], t_margin, h_margins[2], b_margin)
            end
            local lspace = tonumber(ds:readSetting("copt_line_spacing"))
            if lspace and lspace > 0 and type(temp_doc.setInterlineSpacePercent) == "function" then
                pcall(temp_doc.setInterlineSpacePercent, temp_doc, lspace)
            end
        end
        local ok_ld, loaded = pcall(temp_doc.loadDocument, temp_doc, true)
        if not (ok_ld and loaded == true) then
            if type(temp_doc.close) == "function" then pcall(temp_doc.close, temp_doc) end
            return nil
        end
        if type(temp_doc.render) == "function" then
            pcall(temp_doc.render, temp_doc)
        end
    end
    if not isDocTocReady(temp_doc) then
        if type(temp_doc.close) == "function" then pcall(temp_doc.close, temp_doc) end
        return nil
    end
    if type(temp_doc.getToc) == "function" then
        local ok_t, t = pcall(temp_doc.getToc, temp_doc)
        local ckey = tocCacheKey(file)
        if ok_t and type(t) == "table" and #t > 0 and ckey then
            toc_cache[ckey] = t
        end
    end
    return temp_doc
end

local function collectInkAway(file, ds, sdr_dir, raw, document, addEntry)
    local data, ink_path = loadInkAwaySidecar(sdr_dir)
    if not data then
        return
    end
    local ink_attr = ink_path and lfs.attributes(ink_path) or nil
    local mtime = (type(ink_attr) == "table" and ink_attr.modification) or 0
    local ink_size = (type(ink_attr) == "table" and ink_attr.size) or 0
    local fallback_dt = (mtime and mtime > 0) and os.date("%Y-%m-%d %H:%M:%S", mtime) or nil

    local nb_path = resolveInkAwayNotebookPath(data.notes)
    local nb = nb_path and loadLuaData(readFileBytes(nb_path)) or nil
    local nb_mtime = (nb_path and lfs.attributes(nb_path, "modification")) or 0

    local has_reflow_items = false
    for __, item in ipairs(data.items) do
        local a = type(item) == "table" and item.a or nil
        if type(a) == "table" and (type(a.xp0) == "string" or type(a.pxp) == "string") then
            has_reflow_items = true
            break
        end
    end

    local cache_key = (document == nil and ink_path)
        and string.format("%s\31%s\31%s\31%s", tostring(ink_path), tostring(mtime), tostring(ink_size), tostring(nb_mtime))
        or nil
    if cache_key and type(inkaway_cache[cache_key]) == "table" then
        for __, cached in ipairs(inkaway_cache[cache_key]) do
            addEntry(cached.entry, nil, cached.strokes)
        end
        return
    end

    local work_doc = isDocTocReady(document) and document or nil
    local owns_doc = false
    if not work_doc and document == nil and has_reflow_items then
        work_doc = openRenderedReflowDoc(file, ds)
        owns_doc = work_doc ~= nil
    end

    local screen_w, screen_h = detectScreenSize(work_doc, nb)
    local has_box_api = work_doc ~= nil and type(work_doc.getScreenBoxesFromPositions) == "function"

    local saved_page, saved_xp
    if has_box_api and not owns_doc then
        if work_doc._view_mode == work_doc.SCROLL_VIEW_MODE and type(work_doc.getXPointer) == "function" then
            local ok_x, xp = pcall(work_doc.getXPointer, work_doc)
            if ok_x and type(xp) == "string" then saved_xp = xp end
        elseif type(work_doc.getCurrentPage) == "function" then
            local ok_cp, cp = pcall(work_doc.getCurrentPage, work_doc, true)
            if ok_cp and tonumber(cp) then saved_page = tonumber(cp) end
        end
    end

    -- First pass: resolve pageno & bucket for each item
    local raw_items = {}
    local pages_to_visit = {}
    local offline_blocks = {}
    for idx, item in ipairs(data.items) do
        if type(item) == "table" and type(item.op) == "table" and type(item.a) == "table" then
            local a = item.a
            local pos0
            if type(a.pxp) == "string" then
                pos0 = a.pxp
            elseif type(a.xp0) == "string" then
                pos0 = ((tonumber(a.seg) or 1) > 1 and type(a.xp1) == "string") and a.xp1 or a.xp0
            end
            local pageno = tonumber(a.page) or tonumber(a.pg) or 0
            if pageno == 0 and pos0 and work_doc and type(work_doc.getPageFromXPointer) == "function" then
                local ok_p, rp = pcall(work_doc.getPageFromXPointer, work_doc, pos0)
                if ok_p and tonumber(rp) and tonumber(rp) > 0 then
                    pageno = tonumber(rp)
                end
            end
            if has_box_api and pageno > 0 and (a.xp0 or a.pxp) then
                pages_to_visit[pageno] = pages_to_visit[pageno] or {}
                local list = pages_to_visit[pageno]
                list[#list + 1] = #raw_items + 1
            end
            local off_blk
            if not (has_box_api and pageno > 0) and pos0 then
                local pb = parseXpBlock(pos0)
                if pb then
                    local matched_b
                    for __, ob in ipairs(offline_blocks) do
                        if ob.parent == pb.parent
                                and pb.bidx >= ob.min_bidx - 1
                                and pb.bidx <= ob.max_bidx + 1 then
                            matched_b = ob
                            if pb.bidx < ob.min_bidx then ob.min_bidx = pb.bidx end
                            if pb.bidx > ob.max_bidx then ob.max_bidx = pb.bidx end
                            break
                        end
                    end
                    if not matched_b then
                        matched_b = {
                            id = "offblk:" .. tostring(#offline_blocks + 1),
                            parent = pb.parent,
                            base_bidx = pb.bidx,
                            base_line = math.floor(pb.char_ofs / 72),
                            min_bidx = pb.bidx,
                            max_bidx = pb.bidx,
                        }
                        offline_blocks[#offline_blocks + 1] = matched_b
                    end
                    off_blk = { grp = matched_b, pb = pb }
                end
            end
            raw_items[#raw_items + 1] = {
                idx = idx,
                item = item,
                a = a,
                pos0 = pos0,
                pageno = pageno,
                off_blk = off_blk,
            }
        end
    end

    -- Visit each active reflowable page once to read exact word boxes
    if has_box_api then
        local sorted_pages = {}
        for p in pairs(pages_to_visit) do sorted_pages[#sorted_pages + 1] = p end
        table.sort(sorted_pages)
        for __, p in ipairs(sorted_pages) do
            if type(work_doc.gotoPage) == "function" then
                pcall(work_doc.gotoPage, work_doc, p)
            end
            for ___, r_idx in ipairs(pages_to_visit[p]) do
                local ri = raw_items[r_idx]
                local a = ri.a
                if type(a.xp0) == "string" then
                    local ok_b, boxes = pcall(work_doc.getScreenBoxesFromPositions,
                        work_doc, a.xp0, a.xp1 or a.xp0, true)
                    if ok_b and type(boxes) == "table" and #boxes > 0 then
                        ri.box = boxes[math.min(tonumber(a.seg) or 1, #boxes)]
                    end
                end
            end
        end
        if not owns_doc then
            if saved_xp and type(work_doc.gotoXPointer) == "function" then
                pcall(work_doc.gotoXPointer, work_doc, saved_xp)
            elseif saved_page and type(work_doc.gotoPage) == "function" then
                pcall(work_doc.gotoPage, work_doc, saved_page, true)
            end
        end
    end

    if owns_doc and work_doc and type(work_doc.close) == "function" then
        pcall(work_doc.close, work_doc)
    end

    -- Second pass: place each item into its page/anchor bucket
    local bucket_order, buckets = {}, {}
    local function getBucket(bkey)
        local b = buckets[bkey]
        if not b then
            b = { key = bkey, pieces = {} }
            buckets[bkey] = b
            bucket_order[#bucket_order + 1] = b
        end
        return b
    end

    for __, ri in ipairs(raw_items) do
        local a = ri.a
        local bkey, ox, oy, is_fixed, id_prefix = nil, 0, 0, false, nil
        if type(a.page) == "number" then
            bkey = "page:" .. tostring(a.page)
            ox = tonumber(a.x) or 0
            oy = tonumber(a.y) or 0
            is_fixed = true
        elseif type(a.pg) == "number" then
            bkey = "pg:" .. tostring(a.pg)
            ox = (tonumber(a.fx) or 0) * screen_w
            oy = (tonumber(a.fy) or 0) * screen_h
            id_prefix = "pg" .. tostring(a.pg)
        elseif a.room and not a.xp0 then
            bkey = "room:" .. tostring(a.room)
            ox = tonumber(a.rx) or 0
            oy = tonumber(a.ry) or 0
            id_prefix = "room-" .. tostring(a.room)
        elseif ri.box then
            bkey = "epub_page:" .. tostring(ri.pageno)
            local box = ri.box
            if tonumber(a.mr) then
                ox = screen_w - tonumber(a.mr)
            elseif tonumber(a.ml) then
                ox = tonumber(a.ml)
            else
                ox = (tonumber(box.x) or 0) + (tonumber(a.dx) or tonumber(a.rx) or 0)
            end
            local bh = tonumber(box.h) or 24
            if tonumber(a.dyb) then
                oy = (tonumber(box.y) or 0) + bh + tonumber(a.dyb)
            else
                oy = (tonumber(box.y) or 0) + (tonumber(a.dy) or tonumber(a.ry) or 0)
            end
        elseif type(a.pxp) == "string" and ri.pageno > 0 and has_box_api then
            bkey = "epub_page:" .. tostring(ri.pageno)
            ox = tonumber(a.dx) or 0
            oy = tonumber(a.dy) or 0
        elseif ri.off_blk then
            local grp, pb = ri.off_blk.grp, ri.off_blk.pb
            bkey = grp.id
            local eff_w = math.max(screen_w, 1000)
            local col = pb.char_ofs % 72
            local line = math.floor(pb.char_ofs / 72)
            local est_x = 80 + col * 9.5
            local est_y
            if pb.bidx == grp.base_bidx then
                est_y = 200 + (line - grp.base_line) * 28
            elseif pb.bidx > grp.base_bidx then
                est_y = 200 + (pb.bidx - grp.base_bidx) * 28 + line * 28
            else
                est_y = 200 + (pb.bidx - grp.base_bidx) * 34 - (pb.is_heading and 38 or 0)
            end
            if tonumber(a.mr) then
                ox = eff_w - tonumber(a.mr)
            elseif tonumber(a.ml) then
                ox = tonumber(a.ml)
            else
                ox = est_x + (tonumber(a.dx) or tonumber(a.rx) or 0)
            end
            if tonumber(a.dyb) then
                oy = est_y + 26 + tonumber(a.dyb)
            else
                oy = est_y + (tonumber(a.dy) or tonumber(a.ry) or 0)
            end
        else
            bkey = "idx:" .. tostring(ri.idx)
        end

        local p_strokes, p_texts = {}, {}
        inkAwayAppendOp(p_strokes, p_texts, ri.item.op, ox, oy, nil, nil)
        if #p_strokes > 0 or #p_texts > 0 then
            local min_y, max_y = strokeListBoundsY(p_strokes)
            if not min_y then
                min_y = (tonumber(ri.item.op.y) or 0) + oy
                max_y = min_y + (tonumber(ri.item.op.h or ri.item.op.size) or 24)
            end
            local b = getBucket(bkey)
            b.pieces[#b.pieces + 1] = {
                pageno = ri.pageno,
                pos0 = ri.pos0,
                is_fixed = is_fixed,
                id_prefix = id_prefix,
                min_y = min_y,
                max_y = max_y,
                strokes = p_strokes,
                texts = p_texts,
            }
        end
    end

    local collected_for_cache = cache_key and {} or nil
    local function emitEntry(entry, strokes)
        if collected_for_cache then
            collected_for_cache[#collected_for_cache + 1] = { entry = entry, strokes = strokes }
        end
        addEntry(entry, nil, strokes)
    end

    local used_custom_ids = {}
    local function uniqueCustomId(base_id)
        if not base_id then
            return nil
        end
        if not used_custom_ids[base_id] then
            used_custom_ids[base_id] = 1
            return base_id
        end
        used_custom_ids[base_id] = used_custom_ids[base_id] + 1
        return base_id .. "-" .. tostring(used_custom_ids[base_id])
    end

    for __, b in ipairs(bucket_order) do
        for ___, cl in ipairs(clusterPlacedPieces(b.pieces)) do
            if #cl.strokes > 0 or #cl.texts > 0 then
                local custom_id = nil
                if not cl.is_fixed then
                    if cl.id_prefix then
                        custom_id = uniqueCustomId(cl.id_prefix)
                    elseif cl.pos0 then
                        custom_id = uniqueCustomId("ink-" .. tostring(adler32Hex(cl.pos0) or "1"))
                    end
                end
                local note = #cl.texts > 0 and table.concat(cl.texts, "\n") or nil
                emitEntry({
                    pageno = cl.pageno,
                    pos0 = cl.pos0,
                    drawing_id = custom_id,
                    datetime = fallback_dt,
                    note = note,
                }, #cl.strokes > 0 and cl.strokes or nil)
            end
        end
    end

    -- Linked `.inkaway` book notebook (`data.notes`: chapter pages + highlight handwritten notes)
    if nb then
        local pages = type(nb.pages) == "table" and nb.pages
            or (type(nb.ops) == "table" and { { ops = nb.ops } })
        if type(pages) == "table" then
            local nb_dt = (nb_mtime and nb_mtime > 0) and os.date("%Y-%m-%d %H:%M:%S", nb_mtime) or fallback_dt
            local nb_w, nb_h = tonumber(nb.w), tonumber(nb.h)
            local hl_by_dt, hl_by_pos = {}, {}
            if type(raw) == "table" then
                for __, r in ipairs(raw) do
                    if type(r) == "table" and not r.deleted then
                        if type(r.datetime) == "string" then
                            hl_by_dt[r.datetime] = r
                        end
                        if type(r.pos0) == "string" then
                            hl_by_pos[r.pos0] = r
                        end
                    end
                end
            end
            local prev_chap, prev_toc = nil, nil
            for pg_idx, pg in ipairs(pages) do
                if type(pg) == "table" and type(pg.ops) == "table" then
                    local tag = type(pg.book) == "table" and pg.book or nil
                    local hl_tag = tag and type(tag.hl) == "table" and tag.hl or nil
                    local explicit_title = not hl_tag and trim(pg.title) or nil
                    local explicit_toc = not hl_tag and tag and tonumber(tag.toc) or nil
                    if explicit_title then prev_chap = explicit_title end
                    if explicit_toc then prev_toc = explicit_toc end

                    local strokes, texts = {}, {}
                    for ___, op in ipairs(pg.ops) do
                        inkAwayAppendOp(strokes, texts, op, 0, 0, nb_w, nb_h)
                    end
                    if #strokes > 0 or #texts > 0 then
                        local matched_hl = hl_tag and ((hl_tag.dt and hl_by_dt[hl_tag.dt])
                            or (hl_tag.pos0 and hl_by_pos[hl_tag.pos0])) or nil
                        local pos0 = (matched_hl and matched_hl.pos0)
                            or (hl_tag and type(hl_tag.pos0) == "string" and hl_tag.pos0) or nil
                        local pageno = matched_hl and (tonumber(matched_hl.pageno)
                            or (type(matched_hl.page) == "number" and matched_hl.page)) or 0
                        if pageno == 0 and pos0 and isDocTocReady(document) and type(document.getPageFromXPointer) == "function" then
                            local ok_p, rp = pcall(document.getPageFromXPointer, document, pos0)
                            if ok_p and tonumber(rp) and tonumber(rp) > 0 then
                                pageno = tonumber(rp)
                            end
                        end
                        local is_continuation = (not tag and not explicit_title)
                        local chapter = (matched_hl and trim(matched_hl.chapter))
                            or explicit_title
                            or (is_continuation and prev_chap)
                            or nil
                        local toc_idx = explicit_toc or (is_continuation and prev_toc) or nil
                        local dt = (matched_hl and (matched_hl.datetime_updated or matched_hl.datetime))
                            or (hl_tag and type(hl_tag.dt) == "string" and hl_tag.dt)
                            or nb_dt
                        local nb_id = uniqueCustomId("nb-" .. tostring(pg.id or pg_idx))
                        local note = #texts > 0 and table.concat(texts, "\n") or nil
                        emitEntry({
                            pageno = pageno,
                            pos0 = pos0,
                            drawing_id = nb_id,
                            chapter = chapter,
                            toc_index = toc_idx,
                            datetime = dt,
                            note = note,
                        }, #strokes > 0 and strokes or nil)
                    end
                end
            end
        end
    end

    if cache_key and collected_for_cache then
        inkaway_cache[cache_key] = collected_for_cache
    end
end

local function cleanTocTitle(title)
    if type(title) ~= "string" then
        return nil
    end
    return trim(title:gsub("\13", ""))
end

local function lookupChapterInTocList(toc_list, pageno)
    local p = tonumber(pageno)
    if type(toc_list) ~= "table" or #toc_list == 0 or not p or p <= 0 then
        return nil
    end
    local prev_idx = nil
    for i, entry in ipairs(toc_list) do
        local ep = type(entry) == "table" and tonumber(entry.page) or nil
        if ep then
            if ep == p then
                prev_idx = i
                break
            elseif ep > p then
                break
            end
            prev_idx = i
        end
    end
    if prev_idx and toc_list[prev_idx] then
        return cleanTocTitle(toc_list[prev_idx].title)
    end
    return nil
end

local function lookupChapterByXPointer(toc_list, pos0)
    if type(toc_list) ~= "table" or #toc_list == 0 or type(pos0) ~= "string" or pos0 == "" then
        return nil
    end
    local target_tok = xpTokens(pos0)
    local target_frag = tonumber(pos0:match("DocFragment%[(%d+)%]"))
    local prev_idx = nil
    local first_same_frag = nil
    local matched_same_frag = false
    for i, entry in ipairs(toc_list) do
        local xp = type(entry) == "table" and entry.xpointer or nil
        if type(xp) == "string" and xp ~= "" then
            local efrag = tonumber(xp:match("DocFragment%[(%d+)%]"))
            if target_frag and efrag then
                if efrag > target_frag then
                    break
                elseif efrag < target_frag then
                    prev_idx = i
                else
                    first_same_frag = first_same_frag or i
                    if xpCompare(xpTokens(xp), target_tok) <= 0 then
                        prev_idx = i
                        matched_same_frag = true
                    end
                end
            else
                if xpCompare(xpTokens(xp), target_tok) <= 0 then
                    prev_idx = i
                end
            end
        end
    end
    if target_frag and first_same_frag and not matched_same_frag then
        prev_idx = first_same_frag
    end
    if prev_idx and toc_list[prev_idx] then
        return cleanTocTitle(toc_list[prev_idx].title)
    end
    return nil
end

local function hasSidecarHandwrittenFiles(file)
    local sdr = handwritten.getSidecarDir(file)
    if not sdr then
        return false
    end
    if lfs.attributes(sdr .. "/inkaway.lua", "mode") == "file"
            or lfs.attributes(sdr .. "/inkaway.lua.old", "mode") == "file"
            or lfs.attributes(sdr .. "/pencil", "mode") == "directory"
            or lfs.attributes(sdr .. "/drawings", "mode") == "directory"
            or lfs.attributes(sdr .. "/stylus", "mode") == "directory" then
        return true
    end
    return #scanSdrDrawings(sdr) > 0
end

--- Cache a live book's Table of Contents in memory while its ReaderUI document
-- is still open and rendered, so delayed close-exports (`onCloseDocument`) or
-- FileManager batch exports can resolve EPUB xpointer chapters without ever
-- opening an unrendered `CreDocument` offscreen.
function handwritten.cacheBookToc(file, document, toc_module, opts)
    local key = tocCacheKey(file)
    if not key then
        return nil
    end
    if type(toc_module) == "table" and type(toc_module.toc) == "table" and #toc_module.toc > 0 then
        toc_cache[key] = toc_module.toc
        return toc_module.toc
    end
    if opts and opts.only_if_needed and not hasSidecarHandwrittenFiles(file) then
        return nil
    end
    local doc_ready = (document == nil) or isDocTocReady(document)
    if not doc_ready then
        return nil
    end
    if type(toc_module) == "table" and type(toc_module.fillToc) == "function" then
        pcall(toc_module.fillToc, toc_module)
        if type(toc_module.toc) == "table" and #toc_module.toc > 0 then
            toc_cache[key] = toc_module.toc
            return toc_module.toc
        end
    end
    if isDocTocReady(document) and type(document.getToc) == "function" then
        local ok_t, t = pcall(document.getToc, document)
        if ok_t and type(t) == "table" and #t > 0 then
            toc_cache[key] = t
            return t
        end
    end
    return nil
end

local function loadBookTocList(file, ds, document, toc_module)
    local cache_key = tocCacheKey(file)
    local toc_ready = (document == nil) or isDocTocReady(document)
    if toc_ready and type(toc_module) == "table" then
        if type(toc_module.fillToc) == "function" and type(toc_module.toc) ~= "table" then
            pcall(toc_module.fillToc, toc_module)
        end
        if type(toc_module.toc) == "table" and #toc_module.toc > 0 then
            if cache_key then
                toc_cache[cache_key] = toc_module.toc
            end
            return toc_module.toc
        end
    end
    if ds and type(ds.readSetting) == "function" then
        if ds:readSetting("handmade_toc_enabled") == true then
            local hm = ds:readSetting("handmade_toc")
            if type(hm) == "table" and #hm > 0 then
                return hm
            end
        end
    end
    if isDocTocReady(document) and type(document.getToc) == "function" then
        local ok_t, t = pcall(document.getToc, document)
        if ok_t and type(t) == "table" and #t > 0 then
            if cache_key then
                toc_cache[cache_key] = t
            end
            return t
        end
    end
    if cache_key and toc_cache[cache_key] ~= nil then
        return toc_cache[cache_key] or nil
    end
    if type(file) == "string" and file ~= "" and lfs.attributes(file, "mode") == "file" then
        local ok_dr, DocumentRegistry = pcall(require, "document/documentregistry")
        if ok_dr and DocumentRegistry and type(DocumentRegistry.openDocument) == "function" then
            local can_open_offscreen = true
            if type(DocumentRegistry.getProvider) == "function" then
                local ok_prov, prov = pcall(DocumentRegistry.getProvider, DocumentRegistry, file)
                if not ok_prov or type(prov) ~= "table"
                        or prov.loadDocument ~= nil
                        or (type(prov.info) == "table" and prov.info.has_pages == false) then
                    can_open_offscreen = false
                end
            end
            if can_open_offscreen then
                local ok_doc, temp_doc = pcall(DocumentRegistry.openDocument, DocumentRegistry, file)
                if ok_doc and temp_doc then
                    local ok_t, t = nil, nil
                    if isDocTocReady(temp_doc) and type(temp_doc.getToc) == "function" then
                        ok_t, t = pcall(temp_doc.getToc, temp_doc)
                    end
                    if type(temp_doc.close) == "function" then
                        pcall(temp_doc.close, temp_doc)
                    end
                    if ok_t and type(t) == "table" then
                        if cache_key then
                            toc_cache[cache_key] = (#t > 0) and t or false
                        end
                        if #t > 0 then
                            return t
                        end
                    end
                end
            end
        end
    end
    return nil
end

--- Collect all handwritten/stylus annotations for `file`.
-- @string file book file path
-- @tparam table|nil ds DocSettings instance
-- @tparam table|nil raw raw `annotations` table from DocSettings
-- @tparam table|nil document open KOReader document instance (optional, for xpointer page/TOC lookup)
-- @tparam table|nil toc_module open KOReader ReaderToc instance (`ui.toc`, optional)
-- @treturn table list of raw handwritten descriptors
function handwritten.collect(file, ds, raw, document, toc_module)
    local out = {}
    if not file and not ds and not raw then
        return out
    end
    local sdr_dir = handwritten.getSidecarDir(file)
    local sdr_files = scanSdrDrawings(sdr_dir)
    local used_files = {}
    local seq_by_page = {}

    local function nextDrawingId(pageno)
        local p = tonumber(pageno) or 0
        seq_by_page[p] = (seq_by_page[p] or 0) + 1
        if p > 0 then
            return string.format("p%d-%d", p, seq_by_page[p])
        end
        return string.format("note-%d", seq_by_page[p])
    end

    local function findSdrFileForPage(pageno)
        local p = tonumber(pageno)
        for __, f in ipairs(sdr_files) do
            if not used_files[f.path] and p and f.page == p then
                used_files[f.path] = true
                return f
            end
        end
        return nil
    end

    local function addEntry(item, img_file, strokes)
        local pageno = tonumber(item.pageno)
            or (type(item.page) == "number" and item.page)
            or (img_file and img_file.page)
            or 0
        if pageno == 0 and type(item.text) == "string" then
            pageno = tonumber(item.text:match("page%s+(%d+)")) or 0
        end
        if pageno == 0 and type(item.note) == "string" then
            pageno = tonumber(item.note:match("page%s+(%d+)")) or 0
        end
        local datetime = item.datetime_updated or item.datetime
        if not datetime and img_file and img_file.mtime and img_file.mtime > 0 then
            datetime = os.date("%Y-%m-%d %H:%M:%S", img_file.mtime)
        end
        local raw_note = trim(item.note) or trim(item.notes)
        local raw_text = trim(item.text)
        if raw_note and handwritten.isPencilBookmarkNote(raw_note) then
            raw_note = nil
        end
        if raw_text and handwritten.isPencilBookmarkNote(raw_text) then
            raw_text = nil
        end
        -- If there is highlighted text alongside a note, keep both; if text is
        -- just a label and note is nil, treat text as user note only when it
        -- isn't the default placeholder.
        local user_note = raw_note or raw_text
        local ext = (img_file and img_file.ext) or "svg"
        local drawing_id = item.drawing_id or nextDrawingId(pageno)
        local w_num = tonumber(item.width or item.page_width or item.screen_width)
        local h_num = tonumber(item.height or item.page_height or item.screen_height)
        local digest
        if strokes then
            local preview_svg = handwritten.renderStrokesToSvg(strokes, w_num, h_num)
            digest = adler32Hex((preview_svg or "") .. "\31" .. tostring(user_note or ""))
        end
        out[#out + 1] = {
            pageno = pageno > 0 and pageno or nil,
            pageref = item.pageref or (pageno > 0 and tostring(pageno) or nil),
            page = item.page,
            pos0 = item.pos0,
            chapter = trim(item.chapter),
            toc_index = item.toc_index,
            datetime = datetime,
            datetime_updated = item.datetime_updated,
            note = user_note,
            special = item.tomedown_special or nil,
            drawing_source = img_file and img_file.path or nil,
            drawing_strokes = strokes,
            drawing_width = w_num,
            drawing_height = h_num,
            drawing_ext = ext,
            drawing_id = drawing_id,
            drawing_digest = digest,
        }
    end

    -- 1. Inspect items in `raw` (`annotations` table)
    if type(raw) == "table" then
        for __, item in ipairs(raw) do
            if type(item) == "table" and not item.deleted then
                local img_path = item.pencil_image or item.drawing or item.image or item.image_path
                local resolved = resolveImageFile(img_path, sdr_dir)
                local has_strokes = type(item.strokes) == "table" and #item.strokes > 0
                local is_pencil_drawer = item.drawer == "pencil" or item.drawer == "stylus" or item.handwritten == true
                local is_pencil_bm = not item.drawer
                    and (handwritten.isPencilBookmarkNote(item.note) or handwritten.isPencilBookmarkNote(item.text))

                if resolved then
                    used_files[resolved] = true
                    local ext = resolved:lower():match("%.([%w]+)$") or "png"
                    addEntry(item, { path = resolved, ext = ext }, nil)
                elseif has_strokes then
                    addEntry(item, nil, item.strokes)
                elseif is_pencil_drawer or is_pencil_bm then
                    local p = tonumber(item.pageno) or tonumber(item.page)
                        or tonumber(tostring(item.note or item.text or ""):match("page%s+(%d+)"))
                    local matched = findSdrFileForPage(p)
                    if matched then
                        addEntry(item, matched, nil)
                    elseif is_pencil_drawer and type(item.points) == "table" and #item.points > 0 then
                        addEntry(item, nil, { item })
                    end
                end
            end
        end
    end

    -- 2. Inspect dedicated stylus/pencil settings keys in DocSettings
    if ds and type(ds.readSetting) == "function" then
        local keys = { "pencil_annotations", "stylus_annotations", "pencil", "handwritten_notes", "strokes" }
        for __, key in ipairs(keys) do
            local tbl = ds:readSetting(key)
            if type(tbl) == "table" then
                -- Can be an array of annotation entries or a map keyed by page number
                local handled_array = false
                if #tbl > 0 then
                    for __, entry in ipairs(tbl) do
                        if type(entry) == "table" and not entry.deleted then
                            local img_path = entry.pencil_image or entry.image or entry.file or entry.path
                            local resolved = resolveImageFile(img_path, sdr_dir)
                            if resolved and not used_files[resolved] then
                                used_files[resolved] = true
                                local ext = resolved:lower():match("%.([%w]+)$") or "png"
                                addEntry(entry, { path = resolved, ext = ext }, nil)
                                handled_array = true
                            elseif type(entry.strokes) == "table" and #entry.strokes > 0 then
                                addEntry(entry, nil, entry.strokes)
                                handled_array = true
                            elseif type(entry.points) == "table" and #entry.points > 0 then
                                addEntry(entry, nil, { entry })
                                handled_array = true
                            end
                        end
                    end
                end
                if not handled_array then
                    local pages = {}
                    for k, v in pairs(tbl) do
                        local pnum = tonumber(k)
                        if pnum and type(v) == "table" then
                            pages[#pages + 1] = { p = pnum, val = v }
                        end
                    end
                    table.sort(pages, function(a, b) return a.p < b.p end)
                    for __, pv in ipairs(pages) do
                        local v = pv.val
                        local img_path = type(v.image) == "string" and v.image
                            or (type(v.file) == "string" and v.file)
                        local resolved = resolveImageFile(img_path, sdr_dir)
                        if resolved and not used_files[resolved] then
                            used_files[resolved] = true
                            local ext = resolved:lower():match("%.([%w]+)$") or "png"
                            addEntry({
                                pageno = pv.p,
                                chapter = v.chapter,
                                datetime = v.datetime,
                                note = v.note,
                            }, { path = resolved, ext = ext, page = pv.p }, nil)
                        elseif type(v.strokes) == "table" and #v.strokes > 0 then
                            addEntry({
                                pageno = pv.p,
                                chapter = v.chapter,
                                datetime = v.datetime,
                                note = v.note,
                                width = v.width,
                                height = v.height,
                            }, nil, v.strokes)
                        elseif #v > 0 and normalizeStroke(v[1]) then
                            addEntry({ pageno = pv.p }, nil, v)
                        end
                    end
                end
            end
        end
    end

    -- 3. Any remaining unmatched image files in `<sdr>/pencil` or `pencil_*.png`
    for __, f in ipairs(sdr_files) do
        if not used_files[f.path] then
            used_files[f.path] = true
            addEntry({ pageno = f.page or 0 }, f, nil)
        end
    end

    -- 4. InkAway (`ink-away.koplugin`) sidecar `<sdr>/inkaway.lua` + linked `.inkaway` notebooks
    collectInkAway(file, ds, sdr_dir, raw, document, addEntry)

    -- 5. Resolve missing chapter titles (and TOC positions for chapter notebook pages)
    --    via live `toc_module:getTocTitleByPage`, `document:getToc()`, `handmade_toc`,
    --    cached TOC, or fixed-page `DocumentRegistry`
    local toc_ready = (document == nil) or isDocTocReady(document)
    local needs_toc_list = false
    for __, item in ipairs(out) do
        if not item.chapter and toc_ready and type(toc_module) == "table"
                and type(toc_module.getTocTitleByPage) == "function" then
            local target = (type(item.pos0) == "string" and item.pos0 ~= "") and item.pos0 or item.pageno
            if target then
                local ok_c, chap = pcall(toc_module.getTocTitleByPage, toc_module, target)
                local cleaned = ok_c and cleanTocTitle(chap) or nil
                if not cleaned and target ~= item.pageno and item.pageno then
                    ok_c, chap = pcall(toc_module.getTocTitleByPage, toc_module, item.pageno)
                    cleaned = ok_c and cleanTocTitle(chap) or nil
                end
                if cleaned then
                    item.chapter = cleaned
                end
            end
        end
        if (item.toc_index and (not item.chapter or (not item.pageno and not item.pos0)))
                or (not item.chapter and (item.pageno or (type(item.pos0) == "string" and item.pos0 ~= ""))) then
            needs_toc_list = true
        end
    end
    if needs_toc_list then
        local toc_list = loadBookTocList(file, ds, document, toc_module)
        if toc_list then
            for __, item in ipairs(out) do
                if item.toc_index and type(toc_list[item.toc_index]) == "table" then
                    local te = toc_list[item.toc_index]
                    if not item.chapter then
                        item.chapter = cleanTocTitle(te.title)
                    end
                    if not item.pageno and tonumber(te.page) and tonumber(te.page) > 0 then
                        item.pageno = tonumber(te.page)
                    end
                    if not item.pos0 and type(te.xpointer) == "string" and te.xpointer ~= "" then
                        item.pos0 = te.xpointer
                    end
                end
                if not item.chapter and type(item.pos0) == "string" and item.pos0 ~= "" then
                    item.chapter = lookupChapterByXPointer(toc_list, item.pos0)
                end
                if not item.chapter and item.pageno then
                    item.chapter = lookupChapterInTocList(toc_list, item.pageno)
                end
            end
        end
    end

    return out
end

local function copyBinaryFile(src, dst)
    if type(ffiUtil) == "table" and type(ffiUtil.copyFile) == "function" then
        local ok, res = pcall(ffiUtil.copyFile, src, dst)
        if ok and res == true and lfs.attributes(dst, "mode") == "file" then
            return true
        end
    end
    local f_in = io.open(src, "rb")
    if not f_in then
        return false
    end
    local bytes = f_in:read("*a")
    f_in:close()
    if not bytes then
        return false
    end
    local f_out = io.open(dst, "wb")
    if not f_out then
        return false
    end
    local written = f_out:write(bytes)
    f_out:close()
    return written ~= nil and written ~= false and lfs.attributes(dst, "mode") == "file"
end

--- Copy or serialize all handwritten drawings of `book` into `<dir>/<folder>/`.
-- Updates each handwritten annotation's `drawing` (vault-relative for the book
-- note, accounting for subfolder layout) and `drawing_vault_rel` (root-relative
-- for the Reading Digest).
-- @tparam table book built book table
-- @string dir local export root directory
-- @string folder target subfolder name (e.g. "drawings")
-- @treturn table list of absolute file paths written/present for cloud sync
function handwritten.ensureDrawings(book, dir, folder, opts)
    local written = {}
    if type(book) ~= "table" or type(book.annotations) ~= "table" then
        return written
    end
    local sub = (type(folder) == "string" and folder ~= "") and folder or DEFAULT_FOLDER
    local base = tostring(book.base or "book")
    local leaf = base:match("([^/]+)$") or base
    local in_subdir = base:find("/", 1, true) ~= nil
    local active_files = {}
    local has_vector = false

    for __, a in ipairs(book.annotations) do
        if a.handwritten and a.drawing_id then
            local rel = handwritten.relPath(leaf, a.drawing_id, a.drawing_ext, sub)
            local abs_target = dir .. "/" .. rel
            local ok_file = lfs.attributes(abs_target, "mode") == "file"
            local target_dir = abs_target:match("^(.*)/[^/]+$")
            if a.drawing_source and lfs.attributes(a.drawing_source, "mode") == "file" then
                if not ok_file then
                    if target_dir then
                        util.makePath(target_dir)
                    end
                    ok_file = copyBinaryFile(a.drawing_source, abs_target)
                end
            elseif a.drawing_strokes then
                has_vector = true
                local svg = handwritten.renderStrokesToSvg(
                    a.drawing_strokes, a.drawing_width, a.drawing_height)
                if svg then
                    local existing = ok_file and readFileBytes(abs_target) or nil
                    if existing ~= svg then
                        if target_dir then
                            util.makePath(target_dir)
                        end
                        local ok_w = util.writeToFile(svg, abs_target, true, false, true)
                        ok_file = ok_w == true and lfs.attributes(abs_target, "mode") == "file"
                    end
                end
            end
            if ok_file then
                active_files[abs_target] = true
                a.drawing_vault_rel = rel
                a.drawing = in_subdir and ("../" .. rel) or rel
                written[#written + 1] = abs_target
            end
        end
    end

    local prune_all = opts and opts.prune == true
    if has_vector or prune_all then
        local target_folder = dir .. "/" .. sub
        if lfs.attributes(target_folder, "mode") == "directory" then
            local prefix = leaf .. " - "
            local ok_iter, iter, obj = pcall(lfs.dir, target_folder)
            if ok_iter and iter then
                for entry in iter, obj do
                    if entry ~= "." and entry ~= ".." and entry:sub(1, #prefix) == prefix then
                        local rest = entry:sub(#prefix + 1)
                        -- `drawing_id` never contains spaces (`relPath` sanitizes to `[%w_%-]`),
                        -- so `not rest:find(" ")` never touches another book like `"Title - Sequel - p1-1.svg"`
                        if not rest:find(" ", 1, true) then
                            local ext = rest:lower():match("%.([^%.]+)$")
                            local can_prune = (ext == "svg") or (prune_all and (ext == "png" or ext == "jpg" or ext == "jpeg"))
                            if can_prune then
                                local full = target_folder .. "/" .. entry
                                if not active_files[full] and lfs.attributes(full, "mode") == "file" then
                                    os.remove(full)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return written
end

--- Remove uploaded drawing files from the local transfer buffer (same rule as covers).
function handwritten.deleteUploaded(paths, dir, folder)
    local removed = 0
    for __, path in ipairs(paths or {}) do
        if handwritten.isDrawingPath(path, dir, folder) and os.remove(path) then
            removed = removed + 1
            logger.info("tomedown: uploaded drawing removed:", path)
        end
    end
    return removed
end

--- Move an old drawings folder to the new folder name and remove the old directory.
function handwritten.migrateFolder(dir, old_folder, new_folder)
    local shared_with_covers = (old_folder == shared.getCoversFolder())
    local ok = shared.migrateAssetFolder(dir, old_folder, new_folder,
        function(entry)
            local ext = entry:lower():match("%.([^%.]+)$")
            if ext == "png" or ext == "svg" then
                return true
            end
            if not shared_with_covers and (ext == "jpg" or ext == "jpeg") then
                return true
            end
            return false
        end,
        copyBinaryFile)
    if ok then
        logger.info("tomedown: migrated drawings folder from", old_folder, "to", new_folder)
    end
    return ok
end

return handwritten
