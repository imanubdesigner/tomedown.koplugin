-- stub del logger di KOReader: registra in logger.history invece di stampare
local logger = { history = {} }

local function record(level, ...)
    local parts = { level }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    logger.history[#logger.history + 1] = table.concat(parts, " ")
end

function logger.dbg(...) record("DBG", ...) end
function logger.info(...) record("INFO", ...) end
function logger.warn(...) record("WARN", ...) end
function logger.err(...) record("ERR", ...) end

function logger.reset()
    logger.history = {}
end

function logger.tail(n)
    local out = {}
    for i = math.max(1, #logger.history - (n or 5) + 1), #logger.history do
        out[#out + 1] = logger.history[i]
    end
    return table.concat(out, "\n")
end

return logger
