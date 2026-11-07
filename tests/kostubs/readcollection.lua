--[[--
stub of frontend/readcollection.lua: the hooks only wrap write(), and
the tests call it to simulate a collection edited in KOReader.
--]]

local ReadCollection = { writes = 0 }

function ReadCollection.write()
    ReadCollection.writes = ReadCollection.writes + 1
    return true
end

function ReadCollection.reset()
    ReadCollection.writes = 0
end

return ReadCollection
