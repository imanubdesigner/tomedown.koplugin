-- stub of ui/widget/confirmbox.lua: keeps track of the last confirm box
local ConfirmBox = { last = nil }

function ConfirmBox:new(o)
    o = o or {}
    o.__widget = "ConfirmBox"
    ConfirmBox.last = o
    return o
end

return ConfirmBox
