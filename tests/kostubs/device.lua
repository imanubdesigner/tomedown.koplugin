-- stub of device.lua: records the links opened by the plugin
local Device = {
    links = {},
    can_link = true,
    -- enough screen for the About popup (fixed, not scaled)
    screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
        scaleBySize = function(_, size) return size end,
    },
}

function Device:canOpenLink()
    return self.can_link
end

-- both false: the About popup registers no gestures and no keys here,
-- so the tests never need a real input context
function Device:isTouchDevice()
    return false
end

function Device:hasKeys()
    return false
end

function Device:openLink(url)
    self.links[#self.links + 1] = url
end

function Device:reset()
    self.links = {}
    self.can_link = true
end

return Device
