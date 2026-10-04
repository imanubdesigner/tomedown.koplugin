--[[
Merge a fresh render into the note already on disk, region by region.

The generated blocks live between tomedown markers (see
tomedown_render.beginMarker): whatever sits outside them belongs to
the reader and is carried over untouched. Every export rebuilds the
block from the render — the notes belong above the marker now — while
the hash inside the begin marker (or, for markers from older builds,
the fingerprint stored at the last export) tells whether the reader
had written inside it: the file is then flagged so the caller can keep
it as .bak before it is rewritten.

Pure module: tomedown_render for the markers and digests, ffi/sha2 for
md5 (the test suite stubs it), nothing from KOReader.
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
-- so files written by older builds keep parsing. The hash inside a
-- begin marker is optional: markers predating it parse as well.
local BEGIN_PATTERN_HASH = "<!%-%- tomedown:begin ([%w_]+)%s+hash=(%w+)[^\n]*%-%->\n"
local BEGIN_PATTERN = "<!%-%- tomedown:begin ([%w_]+)[^\n]*%-%->\n"
local END_PATTERN = "<!%-%- tomedown:end[^\n]*%-%->"

--- Split a note into its frontmatter and its alternating zone/region
-- blocks. Zones are the text between markers (the reader's), regions
-- the generated content inside them. Returns nil when the file has no
-- complete marker pairs (a legacy export or a mangled file): the
-- caller then decides between rebuilding it and adopting its text.
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
        local s, e, name, hash = rest:find(BEGIN_PATTERN_HASH, pos)
        if not s then
            s, e, name = rest:find(BEGIN_PATTERN, pos)
        end
        if not s then
            blocks[#blocks + 1] = { kind = "zone", text = rest:sub(pos) }
            break
        end
        blocks[#blocks + 1] = { kind = "zone", text = rest:sub(pos, s - 1) }
        local cs, ce = rest:find(END_PATTERN, e + 1)
        if not cs then
            return nil
        end
        blocks[#blocks + 1] = { kind = "region", name = name, hash = hash,
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
            s = s .. render.beginMarker(b.name, b.hash) .. "\n" .. b.text
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

-- { order = { keys }, blocks = { key = { lines } }, loose = { lines } }:
-- a line that fits neither a key nor a continuation (Obsidian can
-- produce odd YAML) is kept verbatim in `loose` instead of failing the
-- whole parse, so one odd line never costs the reader their front matter
local function parseFm(fm)
    local order, blocks, loose = {}, {}, {}
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
            loose[#loose + 1] = line
        end
    end
    return { order = order, blocks = blocks, loose = loose }
end

--- Merge the frontmatter: the exporter's keys win, tags are the union
-- of both sides, any key only the user knows about is kept verbatim.
function merge.mergeFrontmatter(disk_fm, rendered_fm)
    local disk = parseFm(disk_fm)
    local rendered = parseFm(rendered_fm)
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
    -- lines the parse could not place: kept verbatim at the end
    for __, line in ipairs(disk.loose) do
        if line:find("%S") then
            out[#out + 1] = line
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

-- The zones are framed on the way out, whatever shape they had on
-- disk: the head zone separates the front matter from the begin marker
-- with a blank line, the tail zone (below the end marker) starts with
-- one and never glues to the marker. Both are idempotent, so a file
-- that already looks right passes through a merge unchanged.
local function frameHead(zone)
    if not zone:find("%S") then
        return "\n"
    end
    if zone:sub(1, 1) ~= "\n" then
        zone = "\n" .. zone
    end
    if zone:sub(-1) ~= "\n" then
        zone = zone .. "\n\n"
    elseif zone:sub(-2) ~= "\n\n" then
        zone = zone .. "\n"
    end
    return zone
end

local function frameTail(zone)
    if not zone:find("%S") then
        return ""
    end
    if zone:sub(1, 2) ~= "\n\n" then
        zone = (zone:sub(1, 1) == "\n") and ("\n" .. zone)
            or ("\n\n" .. zone)
    end
    if zone:sub(-1) ~= "\n" then
        zone = zone .. "\n"
    end
    return zone
end

-- The head zone of a preserve merge, with the plugin's heading on top:
-- the old heading line is dropped first (wherever the reader moved it,
-- so a renamed title lands at once and a file from before the heading
-- gets it added), the text below is framed, the current heading joins.
-- title == "" exports the zone without a heading, title == nil (a
-- caller that does not pass the option) leaves the zone untouched.
local function frameHeadWithHeading(zone, title)
    if title == nil then
        return frameHead(zone)
    end
    zone = (zone:gsub("#[^\n]*<!%-%- tomedown:notes %-%->\n?", "", 1))
    zone = frameHead(zone)
    if title ~= "" then
        zone = render.notesHeading(title) .. "\n" .. zone
    end
    return zone
end

-- did the reader write inside this block? With a hash in the marker the
-- block itself answers; markers from older builds fall back to the
-- fingerprint stored at the last export, and with none we cannot prove
-- an edit (the block counts as ours)
local function regionEdited(db, stored_fp)
    if db.hash then
        return render.digest(db.text) ~= db.hash
    end
    if stored_fp then
        return md5(db.text) ~= stored_fp
    end
    return false
end

-- a file we cannot merge but do generate ourselves: markers we cannot
-- parse, or a v0.8 export (our front matter, no markers at all)
local function rebuildable(disk_md)
    if disk_md:find("tomedown:", 1, true) then
        return true
    end
    local fm = disk_md:match("^%-%-%-\n(.-)\n%-%-%-\n")
    if not fm then
        return false
    end
    return fm:find("exported:", 1, true) ~= nil
        and fm:find("  - ebook", 1, true) ~= nil
end

-- a file without markers of its own: its text becomes the zone above
-- the generated block, nothing of it is lost (and the current heading
-- of the write zone joins on top, when one is given)
local function adopt(disk_md, rendered, title)
    local disk_fm, disk_body = disk_md:match("^%-%-%-\n(.-)\n%-%-%-\n(.*)$")
    if not disk_fm then
        disk_body = disk_md
    end
    local out = {
        fm = disk_fm and merge.mergeFrontmatter(disk_fm, rendered.fm)
            or rendered.fm,
        blocks = {},
    }
    out.blocks[1] = { kind = "zone",
        text = frameHeadWithHeading("\n" .. disk_body, title) }
    out.blocks[2] = rendered.blocks[2]
    out.blocks[3] = { kind = "zone", text = frameTail("") }
    return merge.join(out)
end

-- one-time conversion from the old three-region layout (preamble,
-- highlights, bookmarks): the zone above the preamble stays above, the
-- zones between and below the old regions join below the end marker,
-- and the old generated content is dropped (the render has it again).
-- Regions the reader had edited survive only in the .bak the caller
-- writes: flagged through info.backup.
local function migrate(disk, rendered, stored_fps, title)
    stored_fps = stored_fps or {}
    local edited, tail_chunks = {}, {}
    for i, b in ipairs(disk.blocks) do
        if b.kind == "region" then
            local fp = stored_fps[b.name]
            if fp and md5(b.text) ~= fp then
                edited[#edited + 1] = b.name
            end
        elseif i > 1 and b.text:find("%S") then
            tail_chunks[#tail_chunks + 1] =
                b.text:gsub("^%s+", ""):gsub("%s+$", "")
        end
    end
    local out = {
        fm = merge.mergeFrontmatter(disk.fm, rendered.fm),
        blocks = {},
    }
    out.blocks[1] = { kind = "zone",
        text = frameHeadWithHeading(disk.blocks[1].text, title) }
    out.blocks[2] = rendered.blocks[2]
    out.blocks[3] = { kind = "zone",
        text = frameTail(table.concat(tail_chunks, "\n\n")) }
    return merge.join(out), {
        reason = "restructured",
        edited = edited,
        backup = #edited > 0,
    }
end

-- the reader's zones folded into the render's blocks: the head zone
-- gains the current heading, the tail keeps its blank line; the other
-- zones pass through as they sit on disk
local function withZones(disk, rendered, title)
    local blocks = {}
    for i, rb in ipairs(rendered.blocks) do
        if rb.kind == "zone" then
            local text = (disk.blocks[i] and disk.blocks[i].text) or rb.text
            if i == 1 then
                text = frameHeadWithHeading(text, title)
            elseif i == #rendered.blocks then
                text = frameTail(text)
            end
            blocks[i] = { kind = "zone", text = text }
        else
            blocks[i] = rb
        end
    end
    return blocks
end

-- markers damaged beyond parsing (a line deleted or rewritten while
-- the reader was writing): a begin line, even a damaged one, fixes the
-- boundary exactly; without one the render's first stable region line
-- marks where the zone ends, and the file is then also flagged for a
-- .bak. nil when no boundary can be found: the caller rebuilds with a
-- .bak. Returns the document and whether it needs that backup.
local function recoverSplit(disk_md, rendered)
    if not rendered or #rendered.blocks ~= 3 then
        return nil
    end
    local fm, body = disk_md:match("^%-%-%-\n(.-)\n%-%-%-\n(.*)$")
    if not fm then
        return nil
    end
    local region
    for __, b in ipairs(rendered.blocks) do
        if b.kind == "region" then
            region = b
        end
    end
    if not region then
        return nil
    end
    local after, risky = 1, false
    local bs = body:find("tomedown:begin", 1, true)
    if bs then
        local nl = body:find("\n", bs, true)
        after = nl and (nl + 1) or (#body + 1)
    else
        local function findLine(text)
            local s = body:find("\n" .. text .. "\n", 1, true)
            if s then
                return s + 1
            end
            if body:sub(1, #text) == text
                and body:sub(#text + 1, #text + 1) == "\n" then
                return 1
            end
            return nil
        end
        -- skip the furniture (rules, the highlights title): those
        -- lines sit in the region at every export and in no note
        local pos
        for line in (region.text .. "\n"):gmatch("(.-)\n") do
            if line:find("%S") and not line:find("^[-*_]+$")
                and not line:find("^# %*%*") then
                pos = findLine(line)
                if pos then
                    break
                end
            end
        end
        if not pos then
            return nil
        end
        after, risky = pos, true
    end
    local epos, eend = body:find(END_PATTERN, after)
    if not epos then
        return nil
    end
    local zone = body:sub(1, after - 1)
        :gsub("[^\n]*tomedown:[^\n]*\n?", "")
    if risky then
        -- region furniture captured above the boundary is dropped:
        -- the render has it again, and the .bak holds it as it was
        while true do
            local stripped = zone:gsub("\n[-*_]+%s*\n?%s*$", "\n")
                :gsub("\n#[^\n]*%*%*[^\n]*\n?%s*$", "\n")
            if stripped == zone then
                break
            end
            zone = stripped
        end
    end
    return { fm = fm, blocks = {
        { kind = "zone", text = zone },
        { kind = "region", name = region.name, text = region.text,
            hash = render.digest(region.text) },
        { kind = "zone", text = body:sub(eend + 1) },
    } }, risky
end

--- Merge rendered_md into disk_md.
--
-- opts.mode: "overwrite" (write the render as generated)
--            "preserve" (keep the file's front matter and zones, rebuild
--             every generated region from the render)
-- opts.notes_title: title of the heading that names the write zone
--             (current with render.notesHeading); "" exports the zone
--             without a heading, nil leaves the zone's heading alone
--
-- Returns the text to write and info = { reason, edited, backup }:
-- "overwrite" | "legacy" | "adopt" | "format" | "shape" |
-- "restructured" | "merged". info.edited lists the regions the reader
-- had written in; info.backup is true when the file on disk held such
-- edits, so the caller can keep it as .bak before overwriting.
function merge.apply(disk_md, rendered_md, stored_fps, opts)
    opts = opts or {}
    local rendered = merge.split(rendered_md)
    if not rendered then
        -- a render without markers would be a bug in tomedown_render
        return rendered_md, { reason = "shape", edited = {} }
    end
    if opts.mode ~= "preserve" then
        return rendered_md, { reason = "overwrite", edited = {} }
    end
    local disk = merge.split(disk_md)
    local risky
    if not disk then
        disk, risky = recoverSplit(disk_md, rendered)
    end
    if not disk then
        if rebuildable(disk_md) then
            -- rebuilt from the render: the front matter still comes
            -- across, and the file as it was is kept whole as .bak
            local disk_fm = disk_md:match("^%-%-%-\n(.-)\n%-%-%-\n")
            local content = disk_fm and merge.join({
                fm = merge.mergeFrontmatter(disk_fm, rendered.fm),
                blocks = rendered.blocks,
            }) or rendered_md
            return content, { reason = "legacy", edited = {},
                backup = true }
        end
        return adopt(disk_md, rendered, opts.notes_title),
            { reason = "adopt", edited = {} }
    end
    local disk_names = regionNames(disk)
    if disk_names ~= regionNames(rendered) then
        if disk_names == "preamble,highlights,bookmarks" then
            return migrate(disk, rendered, stored_fps, opts.notes_title)
        end
        return rendered_md, { reason = "shape", edited = {} }
    end
    local stamp = disk.fm:match('tomedown:%s*"([^"]*)"')
    if stamp and stamp ~= render.FORMAT_VERSION then
        -- the layout still matches: only the block is regenerated, the
        -- zones and front matter (a key the user added) come across
        return merge.join({
            fm = merge.mergeFrontmatter(disk.fm, rendered.fm),
            blocks = withZones(disk, rendered, opts.notes_title),
        }), { reason = "format", edited = {} }
    end
    stored_fps = stored_fps or {}

    local edited = {}
    for i, rb in ipairs(rendered.blocks) do
        if rb.kind == "region"
            and regionEdited(disk.blocks[i], stored_fps[rb.name]) then
            edited[#edited + 1] = rb.name
        end
    end
    return merge.join({
        fm = merge.mergeFrontmatter(disk.fm, rendered.fm),
        blocks = withZones(disk, rendered, opts.notes_title),
    }), {
        reason = "merged",
        edited = edited,
        backup = #edited > 0 or risky == true,
    }
end

return merge
