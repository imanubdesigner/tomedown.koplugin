--[[--
stub of frontend/luasettings.lua, enough for the modules Tomedown reads
directly: collection.lua (LuaSettings:open) and the custom metadata
files (through the docsettings stub, which shares the same contract).

The file is a plain Lua table returned by dofile, like the real one.
--]]

local LuaSettings = {}
LuaSettings.__index = LuaSettings

function LuaSettings:open(path)
    local new = setmetatable({ file = path }, LuaSettings)
    local ok, stored = pcall(dofile, path)
    if ok and type(stored) == "table" then
        new.data = stored
    else
        new.data = {}
    end
    return new
end

function LuaSettings:readSetting(key, default)
    if self.data[key] == nil then
        if default ~= nil then
            self.data[key] = default
        end
        return default
    end
    return self.data[key]
end

function LuaSettings:saveSetting(key, value)
    self.data[key] = value
    return self
end

function LuaSettings:has(key)
    return self.data[key] ~= nil
end

function LuaSettings:flush()
    return true
end

return LuaSettings
