-- stub of ui/font.lua: faces are plain tables here
local Font = {}

function Font:getFace(name, size)
    return { name = name, size = size }
end

return Font
