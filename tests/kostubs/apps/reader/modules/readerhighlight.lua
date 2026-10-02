-- stub of apps/reader/modules/readerhighlight.lua: only what the
-- Tomedown special-row hook needs — showHighlightDialog building its
-- compact edit menu, with the exact name KOReader gives that dialog
local ReaderHighlight = {}

function ReaderHighlight:showHighlightDialog(index)
    local ButtonDialog = require("ui/widget/buttondialog")
    local buttons = {
        {   -- the first row: trash, Style, Color…
            { text = "trash" },
            { text = "Style" },
            { text = "Color" },
        },
        {   -- the boundary arrows
            { text = "◁" },
            { text = "▷" },
        },
    }
    self.last_edit_buttons = buttons
    self.last_edit_index = index
    self.last_dialog = ButtonDialog:new{
        name = "edit_highlight_dialog",
        buttons = buttons,
    }
end

return ReaderHighlight
