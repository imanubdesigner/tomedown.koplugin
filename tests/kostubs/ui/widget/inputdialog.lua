--[[--
stub of ui/widget/inputdialog.lua: the tests set dialog.input_text and
invoke the Save callback the way the UI would.
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

-- buttons is a list of rows, each row a list of buttons:
-- row 1 = Cancel, row 2 = Save
function InputDialog:simulateSave()
    local row = self.buttons and self.buttons[2]
    local save = row and row[1]
    if save and save.callback then
        save.callback()
    end
end

return InputDialog
