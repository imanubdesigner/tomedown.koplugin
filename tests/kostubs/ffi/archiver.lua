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
    -- when true, extractToPath really writes the files: the install flow
    -- checks the extracted tree before swapping it in, so the fake has to
    -- produce one
    write_files = false,
    contents = {},
}

Archiver.Reader = {}

function Archiver.reset()
    Archiver.entries = {}
    Archiver.extracted = {}
    Archiver.open_fails = false
    Archiver.extract_fails = false
    Archiver.write_files = false
    Archiver.contents = {}
end

function Archiver.Reader:new()
    return setmetatable({ err = nil, entries = {}, size = 0 },
        { __index = Archiver.Reader })
end

function Archiver.Reader:open(path)
    if Archiver.open_fails then
        self.err = "could not open archive"
        return false
    end
    self.path = path
    self.entries = {}
    self.size = 0
    return true
end

function Archiver.Reader:iterate()
    local i = 0
    return function()
        i = i + 1
        local p = Archiver.entries[i]
        if p then
            local entry = self.entries[p] or { path = p, index = i }
            self.entries[i] = entry
            self.entries[p] = entry
            self.size = math.max(self.size or 0, i)
            return entry
        end
    end
end

-- the in-memory half of the real Reader: tomedown_pubdate reads the
-- small archive entries this way
function Archiver.Reader:extractToMemory(key)
    return Archiver.contents[key]
end

function Archiver.Reader:extractToPath(src, dest)
    if Archiver.extract_fails then
        self.err = "extract failed"
        return false
    end
    Archiver.extracted[#Archiver.extracted + 1] = { src = src, dest = dest }
    if Archiver.write_files then
        if dest:sub(-1) == "/" then
            os.execute('mkdir -p "' .. dest .. '"')
        else
            local parent = dest:match("^(.*)/[^/]*$")
            if parent then
                os.execute('mkdir -p "' .. parent .. '"')
            end
            local file = assert(io.open(dest, "wb"))
            file:write(Archiver.contents[src] or "")
            file:close()
        end
    end
    return true
end

function Archiver.Reader:close() end

return Archiver
