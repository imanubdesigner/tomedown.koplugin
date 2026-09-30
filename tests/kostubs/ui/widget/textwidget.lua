-- stub of ui/widget/textwidget.lua: keeps the last widget shown so the
-- About popup tests can read its text
local TextWidget = { last = nil }

function TextWidget:new(o)
    o = o or {}
    o.__widget = "TextWidget"
    TextWidget.last = o
    return o
end

return TextWidget
