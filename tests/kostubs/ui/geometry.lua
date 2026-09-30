-- stub of ui/geometry.lua: the popup only builds boxes (its methods,
-- like notIntersectWith, live in gesture code the tests never reach)
local Geom = {}

function Geom:new(o)
    return o or {}
end

return Geom
