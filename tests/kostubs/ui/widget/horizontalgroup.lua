local HorizontalGroup = {}

function HorizontalGroup:new(o)
    o = o or {}
    o.__widget = "HorizontalGroup"
    return o
end

return HorizontalGroup
