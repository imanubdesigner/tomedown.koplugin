-- stub of apps/filemanager/filemanagerconverter.lua: detects Markdown
-- rendering support and, like the real one, accepts an optional
-- stylesheet that ends up in a <style> block of the returned HTML
local FileConverter = {}
FileConverter.last_stylesheet = nil

function FileConverter:mdToHtml(markdown, title, stylesheet)
    FileConverter.last_stylesheet = stylesheet
    local head = stylesheet
        and ("<style>\n" .. stylesheet .. "\n</style>\n")
        or ""
    return "<!DOCTYPE html>\n<html>\n<head>\n" .. head .. "</head>\n"
        .. "<body>\n" .. tostring(markdown) .. "\n</body>\n</html>"
end

return FileConverter
