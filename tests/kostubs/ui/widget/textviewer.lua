-- stub of ui/widget/textviewer.lua: keeps track of the last viewer shown
local TextViewer = { last = nil }

-- mirrors the real class: TextViewer renders text_format = "md" as HTML
-- when these formats are declared (see canRenderMarkdown in
-- tomedown_update.lua)
TextViewer.html_text_formats = {
    html = true,
    htm = true,
    md = true,
}

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
