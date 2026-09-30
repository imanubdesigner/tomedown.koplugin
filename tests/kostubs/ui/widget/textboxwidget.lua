-- stub of ui/widget/textboxwidget.lua: keeps the last widget shown so
-- the About popup tests can read its text
local TextBoxWidget = { last = nil }

function TextBoxWidget:new(o)
    o = o or {}
    o.__widget = "TextBoxWidget"
    TextBoxWidget.last = o
    return o
end

return TextBoxWidget
