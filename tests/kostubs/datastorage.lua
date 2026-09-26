-- stub of frontend/datastorage.lua: the tests point at a local folder
-- (tests/kodata), derived from this file's location
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
