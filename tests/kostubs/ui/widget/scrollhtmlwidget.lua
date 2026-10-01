-- stub of ui/widget/scrollhtmlwidget.lua: keeps the last instance
-- (especially its css) so the tests can assert the plugin's sans
-- stylesheet reached what HtmlBoxWidget:setContent would receive
local ScrollHtmlWidget = { last = nil }

function ScrollHtmlWidget:new(o)
    ScrollHtmlWidget.last = o
    return o
end

return ScrollHtmlWidget
