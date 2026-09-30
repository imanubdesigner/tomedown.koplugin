-- stub of ui/widget/verticalgroup.lua: the popup builds it as a plain
-- array of children, so `new` returning the table as-is is enough
local VerticalGroup = {}

function VerticalGroup:new(o)
    o = o or {}
    o.__widget = "VerticalGroup"
    return o
end

return VerticalGroup
