-- stub of ui/network/manager.lua: the tests drive connected/wifi_on and
-- release the queued runWhenConnected callback themselves
local NetworkMgr = {
    connected = true,
    wifi_on = true,
    pending = nil,
    run_calls = 0,
}

function NetworkMgr:isConnected()
    return self.connected
end

function NetworkMgr:isWifiOn()
    return self.wifi_on
end

function NetworkMgr:runWhenConnected(callback)
    self.run_calls = self.run_calls + 1
    if self.connected then
        callback()
        return
    end
    self.pending = callback
end

-- test hook: the connection came up, run the queued callback
function NetworkMgr:goConnected()
    self.connected = true
    local callback = self.pending
    self.pending = nil
    if callback then
        callback()
    end
end

function NetworkMgr:reset()
    self.connected = true
    self.wifi_on = true
    self.pending = nil
    self.run_calls = 0
end

return NetworkMgr
