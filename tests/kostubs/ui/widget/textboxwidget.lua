-- stub of ui/widget/textboxwidget.lua: keeps the last widget shown so
-- the About popup tests can read its text, plus the Poor Text
-- Formatting constants (same private-use chars as the real widget)
local TextBoxWidget = {
    last = nil,
    PTF_HEADER = "\u{FFF1}",
    PTF_BOLD_START = "\u{FFF2}",
    PTF_BOLD_END = "\u{FFF3}",
}

function TextBoxWidget:new(o)
    o = o or {}
    o.__widget = "TextBoxWidget"
    TextBoxWidget.last = o
    return o
end

return TextBoxWidget
