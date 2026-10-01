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
    -- like the real class, the HTML formats get a ScrollHtmlWidget with
    -- the css TextViewer would pass (the plugin appends its stylesheet
    -- through a wrapper around ScrollHtmlWidget.new)
    if o.text_format and TextViewer.html_text_formats
            and TextViewer.html_text_formats[o.text_format] then
        local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
        o.scroll_widget = ScrollHtmlWidget:new{
            html_body = o.text,
            css = "@page { margin: 0; }\nbody { margin: 0; line-height: 1.3; }",
            dialog = o,
        }
    end
    return o
end

return TextViewer
