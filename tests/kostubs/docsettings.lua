--[[--
stub of frontend/docsettings.lua for the book-info tests.

It keeps custom metadata (custom_props) in memory instead of writing
sidecar files: the real contract is what writeKeywords needs -
findCustomMetadataFile, openSettingsFile, readSetting/saveSetting and
flushCustomMetadata - plus a flush() the write hooks can observe.

Test helpers:
  DocSettings.reset()
  DocSettings.setCustomProps(file, props)
  DocSettings.getCustomProps(file)
  DocSettings.flushed          list of files whose flush() ran
--]]

local LuaSettings = require("luasettings")

local DocSettings = setmetatable({}, { __index = LuaSettings })
DocSettings.__index = DocSettings

DocSettings.files = {}
DocSettings.by_path = {}
DocSettings.flushed = {}

function DocSettings.reset()
    DocSettings.files = {}
    DocSettings.by_path = {}
    DocSettings.flushed = {}
end

function DocSettings:findCustomMetadataFile(file)
    return DocSettings.files[file]
end

function DocSettings.setCustomProps(file, props)
    local path = "custom:" .. file
    DocSettings.files[file] = path
    DocSettings.by_path[path] = { custom_props = props or {} }
end

function DocSettings.getCustomProps(file)
    local path = DocSettings.files[file]
    local data = path and DocSettings.by_path[path] or nil
    return data and data.custom_props or nil
end

function DocSettings.openSettingsFile(path)
    local new = setmetatable({ sidecar_file = path }, DocSettings)
    new.data = path and DocSettings.by_path[path] or {}
    return new
end

-- the sidecar write: the real one stores summary, doc_props and the
-- rest; the tests only need to see that the hook ran
function DocSettings:flush(data)
    local path = (self.data and self.data.doc_path) or self.doc_path
    if path then
        DocSettings.flushed[#DocSettings.flushed + 1] = path
    end
    return true
end

-- called on an opened settings object, as in
-- DocSettings.openSettingsFile(path):flushCustomMetadata(file)
function DocSettings:flushCustomMetadata(file)
    if not file then
        return false
    end
    if not self.sidecar_file then
        self.sidecar_file = "custom:" .. file
        DocSettings.files[file] = self.sidecar_file
    end
    DocSettings.by_path[self.sidecar_file] = self.data
    return true
end

return DocSettings
