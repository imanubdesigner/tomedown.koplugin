--[[--
Shared test helpers: plugin path, environment stubs and assertions.

Every test starts with:
    local HERE = arg[0]:match("^(.*)/") or "."
    package.path = HERE .. "/?.lua;" .. package.path
    local T = require("common")
--]]

local M = {}

local HERE = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
if HERE == "" then
    HERE = "."
end

M.dir = HERE
M.plugin = os.getenv("TOMEDOWN_PLUGIN_DIR") or (HERE .. "/..")

package.path = table.concat({
    HERE .. "/?.lua",
    HERE .. "/kostubs/?.lua",
    M.plugin .. "/?.lua",
    package.path,
}, ";")

M.tests = 0
M.failed = 0

function M.check(cond, msg)
    M.tests = M.tests + 1
    if cond then
        return true
    end
    M.failed = M.failed + 1
    local info = debug.getinfo(2, "Sl")
    local where = info and (info.short_src .. ":" .. info.currentline) or "?"
    print("  FAIL " .. where .. " -> " .. tostring(msg))
    return false
end

function M.finish(name)
    local status = M.failed == 0 and "green" or ("FAILED: " .. M.failed)
    print(string.format("%s: %d assertions %s", name, M.tests, status))
    if M.failed > 0 then
        os.exit(1)
    end
end

function M.readFile(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

function M.fileExists(path)
    return M.readFile(path) ~= nil
end

function M.rmrf(path)
    os.execute('rm -rf "' .. path .. '"')
end

function M.contains(haystack, needle)
    return type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil
end

return M
