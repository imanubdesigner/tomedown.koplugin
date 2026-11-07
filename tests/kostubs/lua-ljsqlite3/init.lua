--[[--
stub of lua-ljsqlite3/init: just the two read-only queries
tomedown_metadata:dateStarted runs, answered from a table the tests
fill in:

  SQ3.books = {
      ["partial-md5"] = { id = 1, start = 1760000000 },
  }
--]]

local SQ3 = { books = {} }

function SQ3.reset()
    SQ3.books = {}
end

function SQ3.open(path)
    local conn = { path = path }

    function conn:rowexec(sql)
        local checksum = sql:match("WHERE md5 = '([^']+)'")
        if checksum then
            local book = SQ3.books[checksum]
            return book and book.id or nil
        end
        local id = sql:match("id_book = (%d+)")
        if id then
            for __, book in pairs(SQ3.books) do
                if tonumber(book.id) == tonumber(id) then
                    return book.start
                end
            end
        end
        return nil
    end

    function conn:close()
        return true
    end

    return conn
end

return SQ3
