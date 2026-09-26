-- stub of KOReader's gettext: callable as _("...") and exposing
-- current_lang like the real module (nil/"C" = no translation).
local gettext = { current_lang = nil }
setmetatable(gettext, {
    __call = function(_, s)
        return s
    end,
})
return gettext
