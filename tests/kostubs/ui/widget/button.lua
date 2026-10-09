-- stub of ui/widget/button.lua: keeps the buttons created so the
-- About popup tests can check the tappable URLs (last = the most
-- recent, all = every button, oldest first)
local Button = { last = nil, all = {} }

function Button:new(o)
    o = o or {}
    o.__widget = "Button"
    Button.last = o
    Button.all[#Button.all + 1] = o
    return o
end

return Button
