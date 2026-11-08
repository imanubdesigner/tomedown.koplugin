--[[
Cover extraction for tomedown.koplugin.

Pulls the cover of a book (the embedded one, or the custom cover KOReader
knows about) into a small JPEG inside the export folder, so the exported
.md files can show it. The image keeps its aspect ratio and is capped to
800x1200 (never upscaled); Obsidian is the one sizing it, via a CSS box
in the markdown.

The file follows the same transient rule as the .md files: when the
upload succeeds it is removed from the device (the vault copy is the
master one), an offline upload keeps it locally until the flush.
]]

local BookInfo = require("apps/filemanager/filemanagerbookinfo")
local CanvasContext = require("document/canvascontext")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local cover = {}

-- export box: the shorter side wins, the aspect ratio is preserved
local MAX_W, MAX_H = 800, 1200
local JPEG_QUALITY = 50

--- The relative path a cover occupies inside the vault (POSIX, the
-- markdown always uses "/" even on Windows KOReader builds).
function cover.relPath(base, folder)
    local sub = (type(folder) == "string" and folder ~= "") and folder or "covers"
    return sub .. "/" .. base .. ".jpg"
end

--- Is this absolute path an exported cover of `dir`?
function cover.isCoverPath(path, dir, folder)
    local sub = (type(folder) == "string" and folder ~= "") and folder or "covers"
    local prefix = dir .. "/" .. sub .. "/"
    return type(path) == "string" and path:sub(1, #prefix) == prefix
end

--- Ensure the cover of `file` exists at `path`.
-- Reuses the file when it is already there (it was written by an
-- earlier export and never uploaded yet).
-- The extraction always forces colour rendering on: KOReader decodes
-- covers in greyscale on greyscale e-ink screens, while the exported
-- .jpg is meant to be shown in Obsidian, on a colour screen. Both
-- knobs are put back right after the call, whatever happened inside.
-- @tparam table|nil document the currently open document, when the
-- book is the one on screen (nil for every other book)
-- @string file the book's file path
-- @string path absolute target .jpg path
-- @treturn boolean true when the file is there after the call
function cover.extract(document, file, path)
    if lfs.attributes(path, "mode") == "file" then
        return true
    end
    local saved_has_color_screen = Device.hasColorScreen
    local saved_canvas_color = CanvasContext.is_color_rendering_enabled
    Device.hasColorScreen = function() return true end
    CanvasContext.is_color_rendering_enabled = true
    if document and document.updateColorRendering then
        pcall(document.updateColorRendering, document)
    end
    local ok_bb, bb = pcall(BookInfo.getCoverImage, BookInfo, document, file, false)
    Device.hasColorScreen = saved_has_color_screen
    CanvasContext.is_color_rendering_enabled = saved_canvas_color
    if document and document.updateColorRendering then
        pcall(document.updateColorRendering, document)
    end
    if not ok_bb or not bb then
        return false
    end
    local w, h = bb:getWidth(), bb:getHeight()
    if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then
        pcall(bb.free, bb)
        return false
    end
    local scale = math.min(MAX_W / w, MAX_H / h, 1)
    if scale < 1 then
        -- lazy: the real module pulls in ffi/mupdf, the tests only load
        -- their stub when a scaled cover is actually written
        local RenderImage = require("ui/renderimage")
        local ok_s, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage,
            bb, math.floor(w * scale + 0.5), math.floor(h * scale + 0.5))
        if not ok_s or not scaled then
            pcall(bb.free, bb)
            logger.err("tomedown: cannot scale cover of", file)
            return false
        end
        bb = scaled
    end
    local target_dir = path:match("^(.*)/[^/]+$")
    if target_dir then
        util.makePath(target_dir)
    end
    local ok_w = bb:writeToFile(path, "jpg", JPEG_QUALITY, false)
    pcall(bb.free, bb)
    if not ok_w then
        logger.err("tomedown: cannot write cover", path)
        return false
    end
    return lfs.attributes(path, "mode") == "file"
end

--- Remove the covers among `paths` that were just uploaded (the vault
-- copy is the master one, the device copy was only a transfer buffer).
-- Only called while "Include book covers" is still ticked: switching
-- it off means the reader wants to keep the files locally.
-- @treturn number how many files were removed
function cover.deleteUploaded(paths, dir, folder)
    local removed = 0
    for __, path in ipairs(paths) do
        if cover.isCoverPath(path, dir, folder) and os.remove(path) then
            removed = removed + 1
            logger.info("tomedown: uploaded cover removed:", path)
        end
    end
    return removed
end

--- Move an old covers folder to the new folder name and remove the old directory.
-- Reuses existing extracted covers so they don't have to be re-extracted,
-- and leaves no orphaned folder behind on the device.
function cover.migrateFolder(dir, old_folder, new_folder)
    if not dir or not old_folder or not new_folder or old_folder == new_folder then
        return false
    end
    local old_path = dir .. "/" .. old_folder
    local new_path = dir .. "/" .. new_folder
    if lfs.attributes(old_path, "mode") ~= "directory" then
        return false
    end
    if lfs.attributes(new_path, "mode") ~= "directory" then
        local ok = os.rename(old_path, new_path)
        if ok then
            logger.info("tomedown: renamed covers folder from", old_folder, "to", new_folder)
            return true
        end
    end
    util.makePath(new_path)
    local ok_iter, iter, obj = pcall(lfs.dir, old_path)
    if ok_iter and iter then
        for entry in iter, obj do
            if entry ~= "." and entry ~= ".." then
                local src = old_path .. "/" .. entry
                local dst = new_path .. "/" .. entry
                if lfs.attributes(src, "mode") == "file" then
                    if not os.rename(src, dst) then
                        local ffiUtil = require("ffi/util")
                        if ffiUtil.copyFile(src, dst) then
                            os.remove(src)
                        end
                    end
                end
            end
        end
    end
    pcall(lfs.rmdir, old_path)
    return lfs.attributes(old_path, "mode") ~= "directory"
end

return cover
