-- stub of ui/widget/button.lua: keeps the last button created so the
-- About popup tests can check the tappable URL
local Button = { last = nil }

function Button:new(o)
    o = o or {}
    o.__widget = "Button"
    Button.last = o
    return o
end

return Button
