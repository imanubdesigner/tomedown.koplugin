-- stub of ui/widget/textwidget.lua: keeps the last widget shown, and every
-- one in order, so the About popup tests can read its text
local TextWidget = { last = nil, all = {} }

function TextWidget:new(o)
    o = o or {}
    o.__widget = "TextWidget"
    TextWidget.last = o
    TextWidget.all[#TextWidget.all + 1] = o
    return o
end

return TextWidget
