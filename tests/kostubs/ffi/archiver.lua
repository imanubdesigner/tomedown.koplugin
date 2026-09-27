--[[--
stub of ffi/archiver.lua: no real zip handling, the tests only need the
Reader contract used by tomedown_update (open/iterate/extractToPath/
close) and a record of what would be extracted where.

Knobs on the module:
  Archiver.entries        list of entry paths to iterate (default: {})
  Archiver.extracted      recorded { src = ..., dest = ... } per extract
  Archiver.open_fails     make open() fail with self.err
  Archiver.extract_fails  make extractToPath() fail with self.err
--]]

local Archiver = {
    entries = {},
    extracted = {},
    open_fails = false,
    extract_fails = false,
}

Archiver.Reader = {}

function Archiver.reset()
    Archiver.entries = {}
    Archiver.extracted = {}
    Archiver.open_fails = false
    Archiver.extract_fails = false
end

function Archiver.Reader:new()
    return setmetatable({ err = nil }, { __index = Archiver.Reader })
end

function Archiver.Reader:open(path)
    if Archiver.open_fails then
        self.err = "could not open archive"
        return false
    end
    self.path = path
    return true
end

function Archiver.Reader:iterate()
    local i = 0
    return function()
        i = i + 1
        local p = Archiver.entries[i]
        if p then
            return { path = p }
        end
    end
end

function Archiver.Reader:extractToPath(src, dest)
    if Archiver.extract_fails then
        self.err = "extract failed"
        return false
    end
    Archiver.extracted[#Archiver.extracted + 1] = { src = src, dest = dest }
    return true
end

function Archiver.Reader:close() end

return Archiver
