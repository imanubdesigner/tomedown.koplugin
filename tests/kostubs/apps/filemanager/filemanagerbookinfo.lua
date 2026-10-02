-- stub of apps/filemanager/filemanagerbookinfo.lua
local BookInfo = {}

-- mirrors the real signature (filemanagerbookinfo.lua v2026.07.2):
-- display_title = title, or the file name without its extension
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

-- test hook: tests set BookInfo.cover_bb to a fake BlitBuffer (or nil
-- to simulate a book without any cover image)
BookInfo.cover_bb = nil

function BookInfo:getCoverImage(document, file, force_orig)
    return BookInfo.cover_bb
end

return BookInfo
