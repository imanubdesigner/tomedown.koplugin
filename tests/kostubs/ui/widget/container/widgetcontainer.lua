-- stub di ui/widget/container/widgetcontainer.lua
local WidgetContainer = {}

function WidgetContainer:extend(t)
    local class = t or {}
    class.__index = class
    setmetatable(class, {
        __index = WidgetContainer,
        __call = function(c, o)
            return c:new(o)
        end,
    })
    function class:new(o)
        local obj = o or {}
        setmetatable(obj, class)
        if obj.init then
            obj:init()
        end
        return obj
    end
    return class
end

function WidgetContainer:new(o)
    local obj = o or {}
    setmetatable(obj, { __index = self })
    if obj.init then
        obj:init()
    end
    return obj
end

return WidgetContainer
