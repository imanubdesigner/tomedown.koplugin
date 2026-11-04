--[[--
Tests for tomedown_pubdate: the pure parsers first, then the file
readers and the path/mtime/size cache against the archiver stub.
--]]
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")

local Archiver = require("ffi/archiver")
local pubdate = require("tomedown_pubdate")
local lfs = require("libs/libkoreader-lfs")

local TMP = "/tmp/opencode/tomedown-pubdate"
T.rmrf(TMP)
os.execute('mkdir -p "' .. TMP .. '"')
local function write(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
    return path
end

-- ------------------------------------------------------------------ dates

T.check(pubdate.parseDate("2010-05-04") == "2010-05-04", "ISO date")
T.check(pubdate.parseDate("2010-05-04T12:30:00+02:00") == "2010-05-04",
    "ISO timestamp")
T.check(pubdate.parseDate("2010-05") == "2010-05", "year and month")
T.check(pubdate.parseDate("2010") == "2010", "year alone")
T.check(pubdate.parseDate("20100504") == "2010-05-04", "compact date")
T.check(pubdate.parseDate("D:20100504120000Z") == "2010-05-04",
    "PDF D: timestamp")
T.check(pubdate.parseDate("1 Jan 1869") == "1869", "free text year")
T.check(pubdate.parseDate("  ") == nil, "blank date")
T.check(pubdate.parseDate("0101-01-01") == nil, "calibre's no-date year")
T.check(pubdate.parseDate("0000") == nil, "zero year")
T.check(pubdate.parseDate(nil) == nil, "nil is not a date")
T.check(pubdate.parseDate("not a date") == nil, "text without a year")

-- ------------------------------------------------------------------- OPF

local opf = [[<?xml version="1.0"?>
<package>
  <metadata>
    <dc:date opf:event="modification">2026-01-01</dc:date>
    <dc:date opf:event="publication">1999-03-02</dc:date>
    <dc:date>2001</dc:date>
    <meta property="dcterms:issued">2000-12</meta>
  </metadata>
</package>]]
T.check(pubdate.fromOpf(opf) == "1999-03-02",
    "the publication event wins over every other date")
T.check(pubdate.fromOpf([[
<metadata>
  <dc:date opf:event="modification">2026-01-01</dc:date>
  <dc:date>2001-02-03</dc:date>
</metadata>]]) == "2001-02-03", "a plain dc:date is the publication")
T.check(pubdate.fromOpf([[
<metadata>
  <dc:date opf:event="modification">2026-01-01</dc:date>
  <meta property="dcterms:issued">2000-12</meta>
</metadata>]]) == "2000-12", "dcterms:issued beats a modification date")
T.check(pubdate.fromOpf([[
<metadata>
  <meta property="dcterms:issued" content="2003-04-05"/>
</metadata>]]) == "2003-04-05", "self-closing dcterms:issued")
T.check(pubdate.fromOpf([[
<metadata>
  <dc:date opf:event="modification">2026-01-01</dc:date>
</metadata>]]) == nil, "a modification date is never a publication")
T.check(pubdate.fromOpf("") == nil, "empty OPF")

-- ------------------------------------------------------------------- FB2

local fb2 = [[<?xml version="1.0"?>
<FictionBook>
  <description>
    <title-info>
      <date value="1869-01-01">1869</date>
    </title-info>
    <publish-info>
      <year>2005</year>
    </publish-info>
    <document-info>
      <date value="2020-01-01"/>
    </document-info>
  </description>
</FictionBook>]]
T.check(pubdate.fromFb2(fb2) == "2005",
    "publish-info's year is the edition")
T.check(pubdate.fromFb2([[
<description><title-info><date value="1869"/></title-info></description>]])
    == "1869", "title-info's date when the edition is missing")
T.check(pubdate.fromFb2([[
<description><title-info><date>1869</date></title-info></description>]])
    == "1869", "title-info's date as text")
T.check(pubdate.fromFb2([[
<description><document-info><date value="2020-01-01"/></document-info></description>]])
    == nil, "document-info is never a publication")
T.check(pubdate.fromFb2("") == nil, "empty FB2")

-- -------------------------------------------------------------- ComicInfo

T.check(pubdate.fromComicInfo(
    "<ComicInfo><Year>2018</Year><Month>7</Month><Day>4</Day></ComicInfo>")
    == "2018-07-04", "comic year, month and day")
T.check(pubdate.fromComicInfo("<ComicInfo><Year>2018</Year></ComicInfo>")
    == "2018", "comic year alone")
T.check(pubdate.fromComicInfo(
    "<ComicInfo><Year>2018</Year><Month>13</Month></ComicInfo>")
    == "2018", "an impossible month is dropped")
T.check(pubdate.fromComicInfo("<ComicInfo><Year>99</Year></ComicInfo>")
    == nil, "an impossible year is dropped")
T.check(pubdate.fromComicInfo("") == nil, "empty ComicInfo")

-- -------------------------------------------------------------- PDF table

T.check(pubdate.fromPdfInfo({ creationDate = "D:20120503120000Z" })
    == "2012-05-03", "PDF creation date")
T.check(pubdate.fromPdfInfo({}) == nil, "PDF metadata without a date")
T.check(pubdate.fromPdfInfo(nil) == nil, "nil PDF metadata")

-- ------------------------------------------------------------------ MOBI

local function u32be(n)
    return string.char(
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256)
end

local function put(s, offset, bytes)
    return s:sub(1, offset) .. bytes .. s:sub(offset + #bytes + 1)
end

local function mobiHead(date)
    local rec0, mobi_len = 100, 232
    local head = string.rep("\0", 600)
    head = put(head, 78, u32be(rec0))                 -- record 0 offset
    head = put(head, rec0 + 16, "MOBI")               -- MOBI magic
    head = put(head, rec0 + 20, u32be(mobi_len))      -- MOBI header length
    head = put(head, rec0 + 128, u32be(64))           -- EXTH follows
    local exth = rec0 + 16 + mobi_len
    head = put(head, exth, "EXTH")
    head = put(head, exth + 8, u32be(1))              -- one record
    local pos = exth + 12
    local payload = date
    head = put(head, pos, u32be(106) .. u32be(8 + #payload) .. payload)
    return head
end

T.check(pubdate.fromMobi(mobiHead("2011-06-07")) == "2011-06-07",
    "MOBI EXTH publishing date")
T.check(pubdate.fromMobi("short") == nil, "a short MOBI head")
T.check(pubdate.fromMobi(string.rep("\0", 200)) == nil,
    "a MOBI head without a header")
T.check(pubdate.fromMobi(mobiHead("2011-06-07"):gsub("MOBI", "XXXX"))
    == nil, "a wrong MOBI magic")

-- ------------------------------------------------------------- file reads

pubdate.clearCache()
Archiver.reset()
local epub = write(TMP .. "/book.epub", "fake")
Archiver.entries = { "META-INF/container.xml", "OEBPS/content.opf" }
Archiver.contents = {
    ["META-INF/container.xml"] =
        '<container><rootfile full-path="OEBPS/content.opf"/></container>',
    ["OEBPS/content.opf"] =
        '<metadata><dc:date>2004-09-01</dc:date></metadata>',
}
T.check(pubdate.read(epub) == "2004-09-01", "EPUB through the OPF")
T.check(pubdate.read(epub) == "2004-09-01", "the second read comes from the cache")
T.check(pubdate.handles("x.kepub"), "kepub is handled")
T.check(pubdate.handles("X.EPUB"), "extension matching ignores case")
T.check(not pubdate.handles("x.txt"), "text files are not handled")
T.check(pubdate.read("x.txt") == nil, "an unknown format has no date")

pubdate.clearCache()
Archiver.reset()
local cbz = write(TMP .. "/book.cbz", "fake")
Archiver.entries = { "ComicInfo.xml" }
Archiver.contents = {
    ["ComicInfo.xml"] = "<ComicInfo><Year>1990</Year></ComicInfo>",
}
T.check(pubdate.read(cbz) == "1990", "CBZ through ComicInfo.xml")

pubdate.clearCache()
local fb2file = write(TMP .. "/book.fb2", fb2)
T.check(pubdate.read(fb2file) == "2005", "FB2 head")
T.check(pubdate.read(TMP .. "/missing.fb2") == nil, "missing file")

pubdate.clearCache()
local mobi = write(TMP .. "/book.mobi", mobiHead("2015-02-03"))
T.check(pubdate.read(mobi) == "2015-02-03", "MOBI head from disk")

pubdate.clearCache()
Archiver.reset()
Archiver.open_fails = true
T.check(pubdate.read(epub) == nil, "an archive that will not open")
Archiver.open_fails = false

T.rmrf(TMP)
T.finish("test_pubdate")
