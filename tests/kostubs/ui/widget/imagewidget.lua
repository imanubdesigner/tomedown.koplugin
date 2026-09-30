-- stub of ui/widget/imagewidget.lua: keeps the last widget created
-- (the About logo, when the plugin ships one)
local ImageWidget = { last = nil }

function ImageWidget:new(o)
    o = o or {}
    o.__widget = "ImageWidget"
    ImageWidget.last = o
    return o
end

return ImageWidget
