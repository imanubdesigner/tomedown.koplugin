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

return BookList
