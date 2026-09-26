--[[--
stub of ui/uimanager.lua.

Key point of the backoff patch: UIManager:scheduleIn does NOT block, it only
records the callback. The tests run it with runPending() and can read the
recorded delays (delay_log) to check the 2s/4s backoff.
--]]

local UIManager = {
    shown = {},
    scheduled = {},
    delay_log = {},
}

function UIManager:show(widget)
    self.shown[#self.shown + 1] = widget
end

function UIManager:close(widget)
    for i = #self.shown, 1, -1 do
        if self.shown[i] == widget then
            table.remove(self.shown, i)
            break
        end
    end
end

function UIManager:forceRePaint() end

function UIManager:scheduleIn(delay, fn)
    self.scheduled[#self.scheduled + 1] = { delay = delay, fn = fn }
    self.delay_log[#self.delay_log + 1] = delay
end

function UIManager:nextDelay()
    return self.delay_log[1]
end

-- runs every queued callback (in registration order)
function UIManager:runPending()
    local guard = 0
    while #self.scheduled > 0 do
        guard = guard + 1
        if guard > 1000 then
            error("UIManager:runPending: loop infinito")
        end
        local item = table.remove(self.scheduled, 1)
        item.fn()
    end
end

function UIManager:pendingCount()
    return #self.scheduled
end

function UIManager:reset()
    self.shown = {}
    self.scheduled = {}
    self.delay_log = {}
end

return UIManager
