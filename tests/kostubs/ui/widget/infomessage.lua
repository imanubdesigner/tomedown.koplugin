-- stub di ui/widget/infomessage.lua: tiene traccia dell'ultimo testo mostrato
local InfoMessage = { last_text = nil }

function InfoMessage:new(o)
    o = o or {}
    o.__widget = "InfoMessage"
    if type(o.text) == "table" then
        o.text = table.concat(o.text, "\n")
    end
    InfoMessage.last_text = o.text
    return o
end

return InfoMessage
