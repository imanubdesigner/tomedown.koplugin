-- stub di frontend/util.lua: solo le funzioni usate da main.lua
local util = {}

function util.tableDeepCopy(t)
    if type(t) ~= "table" then
        return t
    end
    local out = {}
    for k, v in pairs(t) do
        out[k] = util.tableDeepCopy(v)
    end
    return out
end

function util.makePath(path)
    local ok = os.execute('mkdir -p "' .. path .. '"')
    if ok == true or ok == 0 then
        return true
    end
    return nil, "mkdir failed"
end

function util.writeToFile(data, filepath, force_flush, lua_dofile_ready, directory_updated)
    if not filepath then
        return
    end
    if lua_dofile_ready then
        data = "-- " .. filepath .. "\nreturn " .. data .. "\n"
    end
    local file, err = io.open(filepath, "wb")
    if not file then
        return nil, err
    end
    file:write(data)
    file:close()
    return true
end

-- main.lua chiama getSafeFilename(name, nil, nil, -1): nessun limite e
-- nessuna gestione dell'estensione. Replica util.replaceAllInvalidChars di
-- KOReader: caratteri invalidi -> "_" e spazi/punti finali tolti.
function util.getSafeFilename(str, path, limit, limit_ext)
    local name = tostring(str)
    name = name:gsub("[%c]", "_")
    name = name:gsub('[\\/:*?"<>|]', "_")
    return (name:gsub("[.%s]+$", ""))
end

return util
