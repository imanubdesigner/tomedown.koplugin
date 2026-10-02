-- stub of ui/widget/infomessage.lua: keeps track of the last text shown
-- and the face it was built with
local InfoMessage = { last_text = nil, last_face = nil }

function InfoMessage:new(o)
    o = o or {}
    o.__widget = "InfoMessage"
    if type(o.text) == "table" then
        o.text = table.concat(o.text, "\n")
    end
    InfoMessage.last_text = o.text
    InfoMessage.last_face = o.face
    return o
end

return InfoMessage
