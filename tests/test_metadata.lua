--[[--
Tests for tomedown_metadata: the sources (summary, keywords, collection
file, statistics database, publication date), the field collection,
snapshots, import/removal and the automatic-update hooks.
--]]
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")

local BookList = require("ui/widget/booklist")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local ReadCollection = require("readcollection")
local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local shared = require("tomedown_shared")
local metadata = require("tomedown_metadata")

local DATA = DataStorage:getSettingsDir()
local COLLECTION = DATA .. "/collection.lua"
local DB = DATA .. "/statistics.sqlite3"

local store = {}
G_reader_settings = {
    readSetting = function(_, key, default)
        if store[key] == nil then
            return default
        end
        return store[key]
    end,
    saveSetting = function(_, key, value)
        store[key] = value
    end,
    flush = function() end,
}

local FILE = "/mnt/us/Books/A.epub"
local FILE2 = "/mnt/us/Books/B.epub"
local FILE3 = "/mnt/us/Books/NeverOpened.epub"

local function resetEnvironment()
    store = {}
    DocSettings.reset()
    SQ3.reset()
    os.remove(COLLECTION)
    os.remove(DB)
    local f = assert(io.open(DB, "wb"))
    f:write("")
    f:close()
end

local function writeCollections(content)
    local f = assert(io.open(COLLECTION, "wb"))
    f:write(content)
    f:close()
end

local function setSummary(book, summary)
    BookList.registry[book].summary = summary
end

local START = os.time({ year = 2026, month = 9, day = 10, hour = 12 })
local START_DATE = os.date("%Y-%m-%d", START)

resetEnvironment()
BookList.setRegistry({
    [FILE] = {
        summary = {
            rating = 4,
            note = "Bello\n\ne davvero intenso.",
            status = "complete",
            modified = "2026-10-01",
        },
        doc_props = {
            title = "A",
            authors = "Autore",
            keywords = "Fantasy, Avventura",
        },
        partial_md5_checksum = "abc123",
    },
    [FILE2] = {
        doc_props = { title = "B", authors = "Autore 2" },
    },
})
SQ3.books = {
    ["abc123"] = { id = 7, start = START },
}
writeCollections([[
return {
    ["Preferiti"] = {
        { file = "]] .. FILE .. [[", text = "A.epub" },
    },
    ["Fantascienza"] = {
        { file = "]] .. FILE .. [[", text = "A.epub" },
        { file = "]] .. FILE2 .. [[", text = "B.epub" },
    },
}
]])

-- ------------------------------------------------------------ the sources

local summary = metadata.summary(FILE)
T.check(summary.rating == 4, "the sidecar's summary rating")
T.check(summary.note == "Bello\n\ne davvero intenso.", "the sidecar's review")
T.check(metadata.keywordsText(FILE) == "Fantasy, Avventura",
    "the file's keywords: " .. metadata.keywordsText(FILE))
T.check(metadata.keywordsText(FILE, { keywords = { "Uno", "Due" } }) == "Uno, Due",
    "keywords already in the extended props win")
local tags = metadata.tags(FILE)
T.check(#tags == 2 and tags[1] == "Fantasy" and tags[2] == "Avventura",
    "keywords become Obsidian tags")
local collections = metadata.collections(FILE)
T.check(#collections == 2 and collections[1] == "Fantascienza"
        and collections[2] == "Preferiti",
    "the collections are sorted: " .. table.concat(collections, ", "))
T.check(#metadata.collections(FILE2) == 1
        and metadata.collections(FILE2)[1] == "Fantascienza",
    "a book in one collection")
T.check(#metadata.collections(FILE3) == 0, "a book in no collection")
local map = metadata.collectionMap()
T.check(map[FILE] and #map[FILE] == 2 and map[FILE][1] == "Fantascienza"
        and map[FILE][2] == "Preferiti",
    "the one-pass map holds the same sorted memberships")
T.check(map[FILE2] and #map[FILE2] == 1, "the map keeps every book apart")

T.check(metadata.dateStarted(FILE) == START_DATE,
    "the first statistics entry: " .. tostring(metadata.dateStarted(FILE)))
T.check(metadata.dateStarted(FILE2) == nil, "no statistics entry")
T.check(metadata.dateStarted(FILE3) == nil, "no sidecar checksum")
T.check(metadata.publishedDate(FILE) == nil,
    "an EPUB the stub cannot open has no publication date")

-- ------------------------------------------------------------- the fields

shared.setBookOverride(FILE, "published", "1999-05")
T.check(metadata.effectiveDate(FILE, "published", "complete") == "1999-05",
    "the reader's publication date override wins")
local fields = metadata.collect(FILE, "complete")
T.check(fields.rating == 4, "rating: " .. tostring(fields.rating))
T.check(fields.review == "Bello e davvero intenso.",
    "the review folds to one line: " .. tostring(fields.review))
T.check(fields.published == "1999-05", "publication date")
T.check(fields.date_started == START_DATE, "reading start from statistics")
T.check(fields.date_finished == "2026-10-01",
    "finished date from summary.modified")
T.check(fields.collections and #fields.collections == 2, "collections")

local reading = metadata.collect(FILE, "reading")
T.check(reading.date_finished == nil,
    "a book still being read has no finish date")
T.check(reading.published == "1999-05",
    "the publication override does not depend on the status")

setSummary(FILE, { rating = 4.6, status = "complete" })
local rounded = metadata.collect(FILE, "complete")
T.check(rounded.rating == 5, "a fractional rating rounds: " .. tostring(rounded.rating))
setSummary(FILE, { rating = 0 })
T.check(metadata.collect(FILE, "complete").rating == nil, "zero is no rating")
setSummary(FILE, { rating = 9 })
T.check(metadata.collect(FILE, "complete").rating == nil, "out-of-range rating")
setSummary(FILE, { rating = 4, note = "Bello\n\ne davvero intenso.",
    status = "complete", modified = "2026-10-01" })

-- --------------------------------------------------------------- snapshots

shared.clearBookOverrides(FILE)
metadata.saveSnapshot(FILE)
T.check(not metadata.changed(FILE), "an untouched book has not changed")
local snap = shared.getBookInfoSnapshot(FILE)
T.check(snap and snap.keywords == "Fantasy\31Avventura",
    "the snapshot joins the keywords with the unit separator")
T.check(snap and snap.collections == "Fantascienza\31Preferiti",
    "the snapshot joins the collections")

setSummary(FILE, { rating = 5, status = "complete", modified = "2026-10-01" })
T.check(metadata.changed(FILE), "a new rating is a change")
metadata.saveSnapshot(FILE)
T.check(not metadata.changed(FILE), "saving the snapshot clears the change")
setSummary(FILE, { rating = 5, status = "abandoned", modified = "2026-10-02" })
T.check(metadata.changed(FILE), "a new status is a change")
metadata.saveSnapshot(FILE)

shared.setBookTags(FILE, { "legacy" })
T.check(metadata.changed(FILE) == false,
    "a Tomedown-only tag is not part of the shared snapshot")
shared.clearBookTags(FILE)
setSummary(FILE, { rating = 4, note = "Bello\n\ne davvero intenso.",
    status = "complete", modified = "2026-10-01" })
metadata.saveSnapshot(FILE)

-- ----------------------------------------------------------- import/remove

shared.setBookTags(FILE, { "Legacy", "fantasy" })
T.check(metadata.import(FILE), "an opened book can be imported")
T.check(shared.getBookImported(FILE), "the import flag is set")
T.check(shared.getBookTags(FILE) == nil,
    "the legacy tag list is gone after the migration")
local written = DocSettings.getCustomProps(FILE)
T.check(written and written.keywords == "Fantasy, Avventura, Legacy",
    "the legacy tags joined the shared keywords: "
        .. tostring(written and written.keywords))
T.check(metadata.tags(FILE)[3] == "Legacy",
    "the shared keywords are read back")
T.check(shared.getBookInfoSnapshot(FILE) ~= nil,
    "the import saves a snapshot at once")
T.check(metadata.import(FILE), "importing again is harmless")
T.check(not metadata.import(FILE3), "a book KOReader never opened cannot be imported")
T.check(not shared.getBookImported(FILE3), "and its flag stays off")

T.check(metadata.writeKeywords(FILE, {}), "the keyword list can be cleared")
T.check(DocSettings.getCustomProps(FILE).keywords == "",
    "an empty keyword override is written as an empty string, not removed")
T.check(#metadata.tags(FILE) == 0, "the cleared keywords read back empty")

T.check(metadata.writeKeywords(FILE, { "Uno", "Due" }),
    "the keyword list can be written again")
T.check(metadata.tags(FILE)[1] == "Uno" and metadata.tags(FILE)[2] == "Due",
    "the new keywords read back")

shared.setBookOverride(FILE, "published", "2001")
shared.setBookOverride(FILE, "date_started", "2002-03")
metadata.forget(FILE)
T.check(not shared.getBookImported(FILE), "forget clears the import flag")
T.check(shared.getBookOverride(FILE, "published") == nil
        and shared.getBookOverride(FILE, "date_started") == nil,
    "forget clears the date overrides")
T.check(shared.getBookInfoSnapshot(FILE) == nil,
    "forget clears the snapshot")
local kept = shared.getBookTags(FILE)
T.check(kept and #kept == 2 and kept[1] == "Uno" and kept[2] == "Due",
    "the tags stay, as the book's own chosen list")

-- --------------------------------------------------------- automatic update

local exported = {}
local fake_plugin = {
    runExport = function(_, files, opts)
        exported[#exported + 1] = { files = files, opts = opts }
    end,
}
metadata.attach(fake_plugin)

local function flushSidecar(file)
    DocSettings.flush({ data = { doc_path = file } })
end

local function newExport()
    UIManager:reset()
    exported = {}
end

-- imported and changed: one export, two seconds later
shared.setBookImported(FILE, true)
metadata.saveSnapshot(FILE)
setSummary(FILE, { rating = 5, status = "complete", modified = "2026-10-02" })
newExport()
flushSidecar(FILE)
T.check(#UIManager.delay_log == 1 and UIManager.delay_log[1] == 2,
    "a sidecar write schedules one export after 2 s")
T.check(#exported == 0, "nothing is exported before the delay")
UIManager:runPending()
T.check(#exported == 1, "the delayed export runs")
T.check(exported[1].files[1] == FILE, "only the changed book is exported")
T.check(exported[1].opts.auto == "bookinfo", "the export is a book-info one")

-- imported but unchanged: no export
metadata.saveSnapshot(FILE)
newExport()
flushSidecar(FILE)
UIManager:runPending()
T.check(#exported == 0, "an unchanged imported book is not exported")

-- not imported: no schedule at all
shared.setBookImported(FILE, false)
setSummary(FILE, { rating = 3, status = "complete", modified = "2026-10-03" })
newExport()
flushSidecar(FILE)
T.check(#UIManager.delay_log == 0, "a normal book is never watched")

-- automatic updates off: no schedule, even for an imported book
shared.setBookImported(FILE, true)
shared.setAutoBookInfo(false)
newExport()
flushSidecar(FILE)
T.check(#UIManager.delay_log == 0, "the global switch off stops the watching")
shared.setAutoBookInfo(true)

-- the switch is checked again when the callback fires
metadata.saveSnapshot(FILE)
setSummary(FILE, { rating = 1, status = "complete", modified = "2026-10-04" })
newExport()
flushSidecar(FILE)
shared.setAutoBookInfo(false)
UIManager:runPending()
T.check(#exported == 0, "turning the switch off before the delay cancels it")
shared.setAutoBookInfo(true)

-- collections: the write hook notices the membership change
shared.setBookImported(FILE, true)
metadata.saveSnapshot(FILE)
setSummary(FILE, { rating = 1, status = "complete", modified = "2026-10-04" })
writeCollections([[
return {
    ["Nuova"] = {
        { file = "]] .. FILE .. [[" },
    },
}
]])
newExport()
ReadCollection.write()
T.check(#UIManager.delay_log == 1,
    "a collection write schedules the book it changed")
UIManager:runPending()
T.check(#exported == 1 and exported[1].opts.auto == "bookinfo",
    "the collection change is exported")
T.check(exported[1] and exported[1].files[1] == FILE, "the right book")
T.check(metadata.collections(FILE)[1] == "Nuova",
    "the collection reader sees the new membership")
writeCollections("return {}\n")

metadata.detach()
os.remove(COLLECTION)
os.remove(DB)
T.finish("test_metadata")
