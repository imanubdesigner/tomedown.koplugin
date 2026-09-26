-- stub del gettext di KOReader: callabile con _("...") e con il campo
-- current_lang come il vero modulo (nil/"C" = nessuna traduzione).
local gettext = { current_lang = nil }
setmetatable(gettext, {
    __call = function(_, s)
        return s
    end,
})
return gettext
