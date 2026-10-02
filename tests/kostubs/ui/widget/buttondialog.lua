-- stub of ui/widget/buttondialog.lua: records the options of the last
-- dialog built (the special-row hook injects into them) and returns
-- them as the "instance", which is all the hook needs
local ButtonDialog = { last_opts = nil }

function ButtonDialog.new(_, opts)
    ButtonDialog.last_opts = opts
    return opts
end

return ButtonDialog
