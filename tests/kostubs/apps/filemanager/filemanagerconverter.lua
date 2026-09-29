-- stub of apps/filemanager/filemanagerconverter.lua: only what the
-- update check needs to detect Markdown rendering support
local FileConverter = {}

function FileConverter:mdToHtml(markdown, title)
    return "<!DOCTYPE html><html><body>" .. tostring(markdown) .. "</body></html>"
end

return FileConverter
