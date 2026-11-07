--[[
The publication date of a book, read out of the file itself.

KOReader's document engines do not expose one: crengine's
getDocumentProps stops at title, authors, language, series, description,
keywords and identifiers, and BookInfoManager stores no more. Each
format is therefore read here the cheapest way it allows, and nothing
is rendered:

  EPUB/KEPUB  the OPF's dc:date, preferring the publication event,
              dcterms:issued after it
  FB2/FB2.ZIP publish-info's year (the edition), then title-info's date
  CBZ/CBR/CB7/CBT ComicInfo.xml's Year, Month and Day
  MOBI/AZW/AZW3/PRC EXTH record 106, "publishingdate"
  PDF         the Info dictionary's CreationDate

The date is whatever someone put there on purpose: for a re-issued
classic that is often the edition's date rather than the first printing,
which is still better than no date at all.

Adapted from Bookshelf's lib/bookshelf_pubdate.lua (AGPL-3.0), which
Tomedown ships under the same license. The parsers are kept pure; the
file readers are guarded and may run on the UI thread because every
format reads only its head or a small archive entry. Results are cached
by path, modification time and size, so a library export opens each
book once.

Every reader returns nil on any surprise: a missing date is normal, an
exception never reaches the caller.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local M = {}

-- ------------------------------------------------------------------ dates

-- A year nobody means: calibre writes 0101-01-01 for "no publication
-- date", and an empty field can come through as 0000. Real publication
-- years in ebook metadata are well inside this range.
local MIN_YEAR, MAX_YEAR = 1000, 2999

local function validYear(y)
    y = tonumber(y)
    return y and y >= MIN_YEAR and y <= MAX_YEAR and y or nil
end

--- Parse a date into "YYYY", "YYYY-MM" or "YYYY-MM-DD".
-- Takes ISO dates and timestamps (2010-05-04T00:00:00+00:00), compact
-- ones (20100504, and PDF's D:20100504120000Z) and, failing those, the
-- first standalone four-digit year in free text ("1 Jan 1869").
function M.parseDate(s)
    if type(s) ~= "string" then
        return nil
    end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then
        return nil
    end
    local y, mo, d = s:match("^D?:?(%d%d%d%d)(%d%d)(%d%d)")
    if not y then
        y, mo, d = s:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)")
    end
    if not y then
        y, mo = s:match("^(%d%d%d%d)%-(%d%d?)")
    end
    if not y then
        y = s:match("^D?:?(%d%d%d%d)")
    end
    if not y then
        y = s:match("%f[%d](%d%d%d%d)%f[%D]")
        mo, d = nil, nil
    end
    y = validYear(y)
    if not y then
        return nil
    end
    mo, d = tonumber(mo), tonumber(d)
    if not mo or mo < 1 or mo > 12 then
        return string.format("%04d", y)
    end
    if not d or d < 1 or d > 31 then
        return string.format("%04d-%02d", y, mo)
    end
    return string.format("%04d-%02d-%02d", y, mo, d)
end

-- -------------------------------------------------- per-format parsers

local function unescape(s)
    return (s:gsub("<!%[CDATA%[(.-)%]%]>", "%1"):gsub("<[^>]*>", ""))
end

local function attr(attrs, name)
    return attrs:match(name .. '%s*=%s*"([^"]*)"')
        or attrs:match(name .. "%s*=%s*'([^']*)'")
end

--- Date out of an EPUB OPF. Preference, best first: a dc:date marked as
-- the publication (EPUB 2's opf:event), a dc:date with no event
-- (calibre's and EPUB 3's, the publication by definition),
-- dcterms:issued, then any other event except a modification.
function M.fromOpf(opf)
    if type(opf) ~= "string" or opf == "" then
        return nil
    end
    local best, best_rank
    local function offer(text, rank)
        local date = M.parseDate(unescape(text or ""))
        if date and (not best_rank or rank < best_rank) then
            best, best_rank = date, rank
        end
    end
    for attrs, text in opf:gmatch("<%s*dc:date%s+([^>]*)>(.-)</%s*dc:date%s*>") do
        local event = (attr(attrs, "opf:event") or attr(attrs, "event") or ""):lower()
        if event == "publication" or event == "original-publication" then
            offer(text, 1)
        elseif event == "" then
            offer(text, 2)
        elseif not event:find("modif", 1, true) then
            offer(text, 4)
        end
    end
    -- a dc:date with no attributes at all
    for text in opf:gmatch("<%s*dc:date%s*>(.-)</%s*dc:date%s*>") do
        offer(text, 2)
    end
    -- `meta%s+` matters: without it <metadata> itself matches
    for attrs, text in opf:gmatch("<%s*meta%s+([^>]*)>(.-)</%s*meta%s*>") do
        local prop = attr(attrs, "property") or attr(attrs, "name")
        if prop == "dcterms:issued" then
            offer(text, 3)
        end
    end
    for attrs in opf:gmatch("<%s*meta%s+([^>]*)/%s*>") do
        if (attr(attrs, "name") or attr(attrs, "property")) == "dcterms:issued" then
            offer(attr(attrs, "content"), 3)
        end
    end
    return best
end

--- Date out of an FB2 document. publish-info's year is the edition in
-- hand, the closest match to what an EPUB's dc:date means; title-info's
-- date (when the work was written) is the fallback. document-info's date
-- is when the file was made, so never.
function M.fromFb2(xml)
    if type(xml) ~= "string" or xml == "" then
        return nil
    end
    local publish = xml:match("<%s*publish%-info[^>]*>(.-)</%s*publish%-info%s*>")
    if publish then
        local date = M.parseDate(unescape(
            publish:match("<%s*year[^>]*>(.-)</%s*year%s*>") or ""))
        if date then
            return date
        end
    end
    local title = xml:match("<%s*title%-info[^>]*>(.-)</%s*title%-info%s*>")
    if title then
        local attrs, text = title:match("<%s*date([^>]*)>(.-)</%s*date%s*>")
        if attrs then
            return M.parseDate(attr(attrs, "value") or "") or M.parseDate(unescape(text))
        end
        attrs = title:match("<%s*date([^>]*)/>")
        if attrs then
            return M.parseDate(attr(attrs, "value") or "")
        end
    end
    return nil
end

--- Date out of a ComicInfo.xml.
function M.fromComicInfo(xml)
    if type(xml) ~= "string" or xml == "" then
        return nil
    end
    local function field(name)
        return tonumber((xml:match("<%s*" .. name
            .. "%s*>%s*(%-?%d+)%s*</%s*" .. name .. "%s*>")))
    end
    local y = validYear(field("Year"))
    if not y then
        return nil
    end
    local mo, d = field("Month"), field("Day")
    if mo and mo >= 1 and mo <= 12 then
        if d and d >= 1 and d <= 31 then
            return string.format("%04d-%02d-%02d", y, mo, d)
        end
        return string.format("%04d-%02d", y, mo)
    end
    return string.format("%04d", y)
end

--- Date out of MuPDF's getMetadata() table.
function M.fromPdfInfo(meta)
    if type(meta) ~= "table" then
        return nil
    end
    return M.parseDate(meta.creationDate)
end

-- Big-endian unsigned integers out of a byte string, 0-based offsets.
local function u16(s, o)
    local a, b = s:byte(o + 1, o + 2)
    if not b then
        return nil
    end
    return a * 256 + b
end

local function u32(s, o)
    local a, b, c, d = s:byte(o + 1, o + 4)
    if not d then
        return nil
    end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

--- Date out of the head of a MOBI/AZW/AZW3/PRC file: record 0 (PDB
-- header, record list, MOBI header and its EXTH block).
function M.fromMobi(head)
    if type(head) ~= "string" or #head < 86 then
        return nil
    end
    local rec0 = u32(head, 78)
    if not rec0 then
        return nil
    end
    if head:sub(rec0 + 17, rec0 + 20) ~= "MOBI" then
        return nil
    end
    local mobi_len = u32(head, rec0 + 20)
    local flags = u32(head, rec0 + 128)
    if not (mobi_len and flags) then
        return nil
    end
    -- Bit 0x40 says an EXTH block follows the MOBI header.
    if math.floor(flags / 64) % 2 ~= 1 then
        return nil
    end
    local exth = rec0 + 16 + mobi_len
    if head:sub(exth + 1, exth + 4) ~= "EXTH" then
        return nil
    end
    local count = u32(head, exth + 8)
    if not count then
        return nil
    end
    local pos = exth + 12
    for _i = 1, math.min(count, 500) do
        local rtype, rlen = u32(head, pos), u32(head, pos + 4)
        if not (rtype and rlen) or rlen < 8 then
            return nil
        end
        if rtype == 106 then
            return M.parseDate(head:sub(pos + 9, pos + rlen))
        end
        pos = pos + rlen
    end
    return nil
end

-- --------------------------------------------------------- file readers

local function lowerExt(fp)
    local l = fp:lower()
    if l:match("%.fb2%.zip$") then
        return "fb2.zip"
    end
    return l:match("%.([%w]+)$")
end

local function readHead(fp, n)
    local fh = io.open(fp, "rb")
    if not fh then
        return nil
    end
    local s = fh:read(n)
    fh:close()
    return s
end

-- withArchive(fp, fn) -> fn(reader)'s result. The native reader goes
-- back on every path, including the failing ones.
local function withArchive(fp, fn)
    local ok_req, Archiver = pcall(require, "ffi/archiver")
    if not ok_req or not Archiver then
        return nil
    end
    local rd = Archiver.Reader:new()
    if not rd:open(fp) then
        return nil
    end
    for _ in rd:iterate() do end -- luacheck: ignore
    local ok, res = pcall(fn, rd)
    pcall(function() rd:close() end)
    if not ok then
        return nil
    end
    return res
end

local function findEntry(rd, pred)
    if type(rd.entries) ~= "table" then
        return nil
    end
    for _i, e in ipairs(rd.entries) do
        if type(e) == "table" and type(e.path) == "string" and pred(e.path) then
            return e.path
        end
    end
    return nil
end

local function extractToMemory(rd, key)
    if not key then
        return nil
    end
    if type(rd.extractToMemory) == "function" then
        return rd:extractToMemory(key)
    end
    return nil
end

local READERS = {}

READERS.epub = function(fp)
    return withArchive(fp, function(rd)
        local container = extractToMemory(rd, "META-INF/container.xml")
        local opf_path = container and container:match('full%-path%s*=%s*"([^"]+)"')
        if opf_path then
            opf_path = opf_path:gsub("%%(%x%x)", function(h)
                return string.char(tonumber(h, 16))
            end)
        end
        if not (opf_path and rd.entries and rd.entries[opf_path]) then
            opf_path = findEntry(rd, function(p)
                return p:lower():match("%.opf$")
            end)
        end
        return M.fromOpf(extractToMemory(rd, opf_path))
    end)
end
READERS.kepub = READERS.epub

local function comic(fp)
    return withArchive(fp, function(rd)
        local key = findEntry(rd, function(p)
            return p:lower():match("^comicinfo%.xml$")
                or p:lower():match("/comicinfo%.xml$")
        end)
        return M.fromComicInfo(extractToMemory(rd, key))
    end)
end
READERS.cbz, READERS.cbr, READERS.cb7, READERS.cbt = comic, comic, comic, comic

-- The description, where both dates live, comes before the body and the
-- base64 images: the first 256 KB is plenty and spares reading a large
-- file.
READERS.fb2 = function(fp)
    return M.fromFb2(readHead(fp, 256 * 1024))
end
READERS["fb2.zip"] = function(fp)
    return withArchive(fp, function(rd)
        local key = findEntry(rd, function(p)
            return p:lower():match("%.fb2$")
        end)
        return M.fromFb2(extractToMemory(rd, key))
    end)
end

local function mobi(fp)
    return M.fromMobi(readHead(fp, 256 * 1024))
end
READERS.mobi, READERS.azw, READERS.azw3, READERS.prc = mobi, mobi, mobi, mobi

READERS.pdf = function(fp)
    local ok_req, mupdf = pcall(require, "ffi/mupdf")
    if not ok_req or not mupdf then
        return nil
    end
    local ok, doc = pcall(mupdf.openDocument, fp)
    if not (ok and doc) then
        return nil
    end
    local ok_m, meta = pcall(function() return doc:getMetadata() end)
    pcall(function() doc:close() end)
    return ok_m and M.fromPdfInfo(meta) or nil
end

--- Is there a reader for this file's format?
function M.handles(fp)
    return type(fp) == "string" and READERS[lowerExt(fp) or ""] ~= nil
end

-- ---------------------------------------------------------------- cache

-- path + modification time + size -> date or false. A file rewritten in
-- place (a new edition dropped over the old one) gets a new key, so the
-- cache never serves a stale date; a long library run opens each file
-- at most once.
local cache = {}

--- Forget every cached date (tests, or a caller that knows better).
function M.clearCache()
    cache = {}
end

--- Read the publication date of `fp`, or nil when the format is unknown
-- or carries none.
function M.read(fp)
    if type(fp) ~= "string" then
        return nil
    end
    local reader = READERS[lowerExt(fp) or ""]
    if not reader then
        return nil
    end
    local attr = lfs.attributes(fp)
    local key = fp .. "\0" .. tostring(attr and attr.modification or "")
        .. "\0" .. tostring(attr and attr.size or "")
    local cached = cache[key]
    if cached ~= nil then
        return cached or nil
    end
    local ok, date = pcall(reader, fp)
    if not ok then
        logger.warn("tomedown: cannot read the publication date of", fp, date)
        date = nil
    end
    cache[key] = date or false
    return date
end

return M
