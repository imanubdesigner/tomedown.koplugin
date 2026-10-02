-- stub of frontend/ui/renderimage.lua: only scaleBlitBuffer is used by
-- tomedown_cover, and it just needs to return a fake BlitBuffer of the
-- requested size that writes a recognizable marker file
local RenderImage = {}

function RenderImage:scaleBlitBuffer(bb, width, height, free_orig_bb)
    if not width or not height then
        return bb
    end
    width, height = math.floor(width), math.floor(height)
    if bb.getWidth and bb:getWidth() == width and bb:getHeight() == height then
        return bb
    end
    if free_orig_bb ~= false and bb.free then
        bb:free()
    end
    return {
        getWidth = function() return width end,
        getHeight = function() return height end,
        free = function() end,
        writeToFile = function(_, path, format, quality)
            local f = io.open(path, "wb")
            if not f then
                return false
            end
            f:write(string.format("JPG:%dx%d:%s:%d",
                width, height, tostring(format), tonumber(quality) or 0))
            f:close()
            return true
        end,
    }
end

return RenderImage
