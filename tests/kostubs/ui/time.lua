-- stub of ui/time.lua: tests never assert timings, a plain monotonic
-- counter that only moves when a test advances it is enough
local time = {}
local clock = 0

function time.now()
    return clock
end

function time.since(t)
    return clock - t
end

function time.to_ms(fts)
    return math.floor(fts * 1000)
end

function time.advance(seconds)
    clock = clock + seconds
end

return time
