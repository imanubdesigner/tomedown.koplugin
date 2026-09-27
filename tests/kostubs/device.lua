-- stub of device.lua: records the links opened by the plugin
local Device = {
    links = {},
    can_link = true,
}

function Device:canOpenLink()
    return self.can_link
end

function Device:openLink(url)
    self.links[#self.links + 1] = url
end

function Device:reset()
    self.links = {}
    self.can_link = true
end

return Device
