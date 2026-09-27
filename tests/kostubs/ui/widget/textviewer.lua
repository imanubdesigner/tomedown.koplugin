-- stub of ui/widget/textviewer.lua: keeps track of the last viewer shown
local TextViewer = { last = nil }

function TextViewer:new(o)
    o = o or {}
    o.__widget = "TextViewer"
    if type(o.text) == "table" then
        o.text = table.concat(o.text, "\n")
    end
    TextViewer.last = o
    return o
end

return TextViewer
