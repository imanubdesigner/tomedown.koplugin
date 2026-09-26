-- stub of ffi/util.lua
local ffiUtil = {}

-- template("%1 of %2", a, b) -> "a of b" (KOReader syntax)
function ffiUtil.template(fmt, ...)
    local args = { ... }
    return (tostring(fmt):gsub("%%(%d+)", function(n)
        local v = args[tonumber(n)]
        return v == nil and "" or tostring(v)
    end))
end

function ffiUtil.basename(path)
    return tostring(path):match("([^/]+)$")
end

return ffiUtil
