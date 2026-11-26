local LineWidget = {}

function LineWidget:new(o)
    o = o or {}
    o.__widget = "LineWidget"
    return o
end

return LineWidget
