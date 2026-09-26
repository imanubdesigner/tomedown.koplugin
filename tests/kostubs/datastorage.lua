-- stub di frontend/datastorage.lua: i test puntano a una cartella locale
-- (tests/kodata), ricavata dalla posizione di questo file
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DataStorage = {
    data_dir = HERE .. "/../kodata",
}

function DataStorage:getFullDataDir()
    return self.data_dir
end

function DataStorage:getDataDir()
    return self.data_dir
end

function DataStorage:insertDataDir(path)
    return self.data_dir .. "/" .. path
end

return DataStorage
