-- stub di apps/filemanager/filemanagerbookinfo.lua
local BookInfo = {}

-- replica la firma reale (filemanagerbookinfo.lua v2026.07.2):
-- display_title = title, oppure nome file senza estensione
function BookInfo.extendProps(props, file)
    local out = {}
    for k, v in pairs(props or {}) do
        out[k] = v
    end
    local fallback = file and file:match("([^/]+)%..*$") or file
    out.display_title = out.title or fallback
    if not out.authors and out.author then
        out.authors = out.author
    end
    return out
end

return BookInfo
