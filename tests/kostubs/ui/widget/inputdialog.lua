--[[--
stub di ui/widget/inputdialog.lua: i test impostano dialog.input_text e
invocano il callback Salva come farebbe la UI.
--]]

local InputDialog = { last = nil }

function InputDialog:new(o)
    o = o or {}
    o.__widget = "InputDialog"
    o.input_text = o.input or ""
    o.getInputText = function(self)
        return self.input_text
    end
    o.setText = function(_, v)
        o.input_text = v
    end
    setmetatable(o, { __index = InputDialog })
    InputDialog.last = o
    return o
end

-- buttons è una lista di righe, ogni riga una lista di pulsanti:
-- riga 1 = Annulla, riga 2 = Salva
function InputDialog:simulateSave()
    local row = self.buttons and self.buttons[2]
    local save = row and row[1]
    if save and save.callback then
        save.callback()
    end
end

return InputDialog
