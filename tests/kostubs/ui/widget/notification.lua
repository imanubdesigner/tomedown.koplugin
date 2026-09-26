-- stub of ui/widget/notification.lua: keeps track of the last notification
local Notification = { last_text = nil }

function Notification:new(o)
    o = o or {}
    o.__widget = "Notification"
    if type(o.text) == "table" then
        o.text = table.concat(o.text, "\n")
    end
    Notification.last_text = o.text
    return o
end

return Notification
