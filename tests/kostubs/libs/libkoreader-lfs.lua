--[[--
stub di libs/libkoreader-lfs (solo dir/attributes/mkdir), in Lua puro.

lfs.dir deve: (a) fare error() se la cartella non esiste (main.lua fa pcall
sul suo ritorno) e (b) restituire un iteratore da usare come
`for entry in iter, dir_obj do`.
--]]

local lfs = {}

local function shell_capture(cmd)
    local p = io.popen(cmd)
    if not p then
        return nil, nil
    end
    local out = p:read("*a")
    local ok, how, code = p:close()
    if ok == true or (how == "exit" and (code or 0) == 0) then
        return out, true
    end
    return out, false
end

function lfs.dir(path)
    local out, ok = shell_capture('ls -A "' .. path .. '" 2>/dev/null')
    if not ok then
        error("lfs.dir: impossibile aprire " .. tostring(path))
    end
    local entries = {}
    for line in (out or ""):gmatch("[^\n]+") do
        entries[#entries + 1] = line
    end
    local i = 0
    return function()
        i = i + 1
        return entries[i]
    end, {}
end

function lfs.attributes(path, field)
    local out, ok = shell_capture(
        'if [ -d "' .. path .. '" ]; then echo directory;'
        .. 'elif [ -e "' .. path .. '" ]; then echo file; fi')
    local mode = ok and out and out:gsub("%s+$", "") or nil
    if not mode or mode == "" then
        return nil
    end
    local info = { mode = mode }
    if mode == "file" then
        local size = shell_capture('stat -c %s "' .. path .. '" 2>/dev/null')
        info.size = tonumber((size or ""):match("%d+"))
    end
    if field then
        return info[field]
    end
    return info
end

function lfs.mkdir(path)
    if lfs.attributes(path, "mode") == "directory" then
        return true
    end
    local ok = os.execute('mkdir "' .. path .. '"')
    if ok == true or ok == 0 then
        return true
    end
    return nil, "mkdir failed"
end

function lfs.rmdir(path)
    local ok = os.execute('rmdir "' .. path .. '"')
    if ok == true or ok == 0 then
        return true
    end
    return nil, "rmdir failed"
end

return lfs
