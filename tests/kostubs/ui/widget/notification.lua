-- stub di ui/widget/notification.lua: tiene traccia dell'ultima notifica
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
