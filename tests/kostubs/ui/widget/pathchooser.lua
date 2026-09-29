--[[--
stub of ui/widget/pathchooser.lua: the tests simulate a navigation followed
by the long-press + "Choose" by calling PathChooser.last.onConfirm(path);
closing without choosing is doing nothing.
--]]

local PathChooser = { last = nil }

function PathChooser:new(o)
    o = o or {}
    o.__widget = "PathChooser"
    setmetatable(o, { __index = PathChooser })
    PathChooser.last = o
    return o
end

return PathChooser
