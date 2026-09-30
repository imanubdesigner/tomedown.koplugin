-- stub of ui/widget/notification.lua: keeps track of the last
-- notification and of every text shown, so tests can check the order
-- of the separate export/upload results
local Notification = { last_text = nil, log = {} }

function Notification:new(o)
    o = o or {}
    o.__widget = "Notification"
    if type(o.text) == "table" then
        o.text = table.concat(o.text, "\n")
    end
    Notification.last_text = o.text
    Notification.log[#Notification.log + 1] = o.text
    return o
end

return Notification
