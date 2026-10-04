--[[
Merge a fresh render into the note already on disk, region by region.

The generated blocks live between tomedown markers (see
tomedown_render.beginMarker): whatever sits outside them belongs to the
user and is carried over untouched. A region is replaced only when its
content still matches the fingerprint stored at the last export -- that
is what tells "the annotations changed" apart from "the user edited
this region".

Pure module: tomedown_render for the markers, ffi/sha2 for md5 (the
test suite stubs it), nothing from KOReader.
]]

local render = require("tomedown_render")
local md5 = require("ffi/sha2").md5

local merge = {}

-- keys the exporter owns: always taken from the fresh render, even when
-- the file on disk says something else (Obsidian rewrites properties);
-- tags is the exception, merged as a union
local OWNED = {
    tomedown = true, title = true, author = true, cover = true,
    series = true, series_index = true, language = true, pages = true,
    exported = true, highlights = true, status = true, progress = true,
}

-- Patterns are tolerant on purpose: the suffix after the region name
-- (the human-readable hint) and the end marker's own name are ignored,
-- so files written by older builds keep parsing.
local BEGIN_PATTERN = "<!%-%- tomedown:begin ([%w_]+)[^\n]*%-%->\n"
local END_PATTERN = "<!%-%- tomedown:end[^\n]*%-%->"

--- Split a note into its frontmatter and its alternating zone/region
-- blocks. Zones are the text between markers (the user's), regions the
-- generated content inside them. Returns nil when the file has no
-- complete marker pairs (a legacy export or a mangled file): the
-- caller then falls back to a full overwrite.
function merge.split(md)
    if type(md) ~= "string" then
        return nil
    end
    if md:sub(-1) ~= "\n" then
        md = md .. "\n"
    end
    local fm, rest = md:match("^%-%-%-\n(.-)\n%-%-%-\n(.*)$")
    if not fm then
        return nil
    end
    local blocks = {}
    local pos = 1
    local found = false
    while true do
        local s, e, name = rest:find(BEGIN_PATTERN, pos)
        if not s then
            blocks[#blocks + 1] = { kind = "zone", text = rest:sub(pos) }
            break
        end
        blocks[#blocks + 1] = { kind = "zone", text = rest:sub(pos, s - 1) }
        local cs, ce = rest:find(END_PATTERN, e + 1)
        if not cs then
            return nil
        end
        blocks[#blocks + 1] = { kind = "region", name = name,
            text = rest:sub(e + 1, cs - 1) }
        found = true
        pos = ce + 1
    end
    if not found then
        return nil
    end
    return { fm = fm, blocks = blocks }
end

--- Rebuild a note from its parts, byte for byte.
function merge.join(doc)
    local s = "---\n" .. doc.fm .. "\n---\n"
    for __, b in ipairs(doc.blocks) do
        if b.kind == "zone" then
            s = s .. b.text
        else
            s = s .. render.beginMarker(b.name) .. "\n" .. b.text
                .. render.endMarker(b.name)
        end
    end
    if s:sub(-1) ~= "\n" then
        s = s .. "\n"
    end
    return s
end

--- md5 of every region of a rendered note: the reference the next
-- export compares the file on disk against.
function merge.fingerprints(doc)
    local fps = {}
    if not doc then
        return fps
    end
    for __, b in ipairs(doc.blocks) do
        if b.kind == "region" then
            fps[b.name] = md5(b.text)
        end
    end
    return fps
end

-- ---------------------------------------------------------------- frontmatter

-- { order = { keys }, blocks = { key = { lines } } }, nil when a line
-- fits neither a key nor a continuation (Obsidian can produce odd YAML;
-- the caller then keeps the rendered frontmatter wholesale)
local function parseFm(fm)
    local order, blocks = {}, {}
    local current
    for line in (fm .. "\n"):gmatch("(.-)\n") do
        local key = line:match("^([%w_-]+):")
        if key then
            current = key
            order[#order + 1] = key
            blocks[key] = { line }
        elseif current and (line == "" or line:match("^[ \t]")) then
            blocks[current][#blocks[current] + 1] = line
        else
            return nil
        end
    end
    return { order = order, blocks = blocks }
end

--- Merge the frontmatter: the exporter's keys win, tags are the union
-- of both sides, any key only the user knows about is kept verbatim.
function merge.mergeFrontmatter(disk_fm, rendered_fm)
    local disk = parseFm(disk_fm)
    local rendered = parseFm(rendered_fm)
    if not disk or not rendered then
        return rendered_fm
    end
    local out = {}
    for __, key in ipairs(rendered.order) do
        local lines = rendered.blocks[key]
        if key == "tags" then
            local seen = {}
            local merged = { lines[1] }
            for i = 2, #lines do
                local item = lines[i]:match("^%s*-%s+(.*)$")
                if item then
                    seen[item] = true
                end
                merged[#merged + 1] = lines[i]
            end
            local disk_tags = disk.blocks.tags or {}
            for i = 2, #disk_tags do
                local item = disk_tags[i]:match("^%s*-%s+(.*)$")
                if item and not seen[item] then
                    seen[item] = true
                    merged[#merged + 1] = disk_tags[i]
                end
            end
            for __, line in ipairs(merged) do
                out[#out + 1] = line
            end
        else
            for __, line in ipairs(lines) do
                out[#out + 1] = line
            end
        end
    end
    -- keys the exporter dropped or never knew: the user's, kept as is
    for __, key in ipairs(disk.order) do
        if not OWNED[key] and key ~= "tags" and not rendered.blocks[key] then
            for __, line in ipairs(disk.blocks[key]) do
                out[#out + 1] = line
            end
        end
    end
    return table.concat(out, "\n")
end

-- --------------------------------------------------------------------- apply

local function regionNames(doc)
    local names = {}
    for __, b in ipairs(doc.blocks) do
        if b.kind == "region" then
            names[#names + 1] = b.name
        end
    end
    return table.concat(names, ",")
end

--- Merge rendered_md into disk_md.
--
-- opts.mode: "overwrite" (the exported file is written as generated)
--            "preserve" (hand edits win over the generated regions)
-- opts.policy (preserve only): "keep" the edited region as the user
--            left it, "skip" the whole file and let the caller warn.
--
-- Returns the text to write and info = { reason, edited, kept }, or
-- nil and info.reason = "skip" when the policy says so. Reasons:
-- "overwrite" | "legacy" | "format" | "shape" | "merged" | "skip".
function merge.apply(disk_md, rendered_md, stored_fps, opts)
    opts = opts or {}
    local rendered = merge.split(rendered_md)
    if not rendered then
        -- a render without markers would be a bug in tomedown_render
        return rendered_md, { reason = "shape", edited = {}, kept = {} }
    end
    if opts.mode ~= "preserve" then
        return rendered_md, { reason = "overwrite", edited = {}, kept = {} }
    end
    local disk = merge.split(disk_md)
    if not disk then
        return rendered_md, { reason = "legacy", edited = {}, kept = {} }
    end
    local stamp = disk.fm:match('tomedown:%s*"([^"]*)"')
    if stamp and stamp ~= render.FORMAT_VERSION then
        return rendered_md, { reason = "format", edited = {}, kept = {} }
    end
    if regionNames(disk) ~= regionNames(rendered) then
        return rendered_md, { reason = "shape", edited = {}, kept = {} }
    end
    stored_fps = stored_fps or {}

    -- first pass: which regions changed under our feet since the last
    -- export (the disk no longer matches the fingerprint we stored).
    -- No fingerprint at all (settings wiped, file from an older build)
    -- means we cannot prove a hand edit: the region is regenerated.
    local edited = {}
    for i, rb in ipairs(rendered.blocks) do
        if rb.kind == "region" then
            local db, fp = disk.blocks[i], stored_fps[rb.name]
            if db.text ~= rb.text and fp ~= nil and md5(db.text) ~= fp then
                edited[#edited + 1] = { index = i, name = rb.name }
            end
        end
    end
    local info = { reason = "merged", edited = {}, kept = {} }
    if #edited > 0 and opts.policy == "skip" then
        for __, e in ipairs(edited) do
            info.edited[#info.edited + 1] = e.name
        end
        info.reason = "skip"
        return nil, info
    end
    local is_edited = {}
    for __, e in ipairs(edited) do
        is_edited[e.index] = true
        info.edited[#info.edited + 1] = e.name
        info.kept[#info.kept + 1] = e.name
    end

    local out = { fm = merge.mergeFrontmatter(disk.fm, rendered.fm),
        blocks = {} }
    for i, rb in ipairs(rendered.blocks) do
        -- zones: the user's, verbatim; regions: ours, or theirs when edited
        out.blocks[i] = (rb.kind == "zone" or is_edited[i])
            and disk.blocks[i] or rb
    end
    return merge.join(out), info
end

return merge
