-- stub of ui/widget/booklist.lua: fake registry of already opened books
local BookList = { registry = {} }

function BookList.setRegistry(t)
    BookList.registry = t or {}
end

function BookList.hasBookBeenOpened(file)
    return BookList.registry[file] ~= nil
end

function BookList.getDocSettings(file)
    local rec = BookList.registry[file]
    if not rec then
        return nil
    end
    return {
        readSetting = function(_, key)
            return rec[key]
        end,
        saveSetting = function(_, key, value)
            rec[key] = value
        end,
    }
end

-- mirrors the real setBookInfoCache(): status/percent/pages from doc settings
function BookList.getBookInfo(file)
    local rec = BookList.registry[file]
    if not rec then
        return { been_opened = false }
    end
    local summary = rec.summary
    local status = summary and summary.status
    if status ~= "reading" and status ~= "abandoned" and status ~= "complete" then
        status = "reading"
    end
    local pages = rec.doc_pages
    if not pages and rec.pagemap_use_page_labels then
        pages = rec.pagemap_doc_pages
    end
    if not pages and rec.stats and rec.stats.pages and rec.stats.pages ~= 0 then
        pages = rec.stats.pages
    end
    return {
        been_opened = true,
        status = status,
        pages = pages,
        percent_finished = rec.percent_finished,
    }
end

return BookList
