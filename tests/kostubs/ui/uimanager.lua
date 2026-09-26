--[[--
stub di ui/uimanager.lua.

Punto importante per la patch di backoff: UIManager:scheduleIn NON blocca,
registra solo la callback. I test la eseguono con runPending() e possono
leggere i ritardi registrati (delay_log) per verificare il backoff 2s/4s.
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

-- esegue tutte le callback in coda (in ordine di registrazione)
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
