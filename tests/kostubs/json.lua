--[[--
json in puro Lua: main.lua usa json.decode su "cloud_server_object" e
json.encode su "selected"/sync_server. Niente dipendenze esterne.
--]]

local json = {}

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b",
    ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode_string(s)
    s = s:gsub('[%z\1-\31\\"]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end)
    return '"' .. s .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then
            return false
        end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then
            return false
        end
    end
    return n > 0 or next(t) == nil
end

local encode_value

local function encode_table(t, depth)
    if depth > 32 then
        error("json: tabella troppo profonda")
    end
    local parts = {}
    if is_array(t) then
        for i = 1, #t do
            parts[#parts + 1] = encode_value(t[i], depth + 1)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, v in pairs(t) do
        parts[#parts + 1] = encode_string(tostring(k)) .. ":" .. encode_value(v, depth + 1)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encode_value = function(v, depth)
    depth = depth or 0
    local tv = type(v)
    if v == nil then
        return "null"
    elseif tv == "boolean" then
        return v and "true" or "false"
    elseif tv == "number" then
        if v % 1 == 0 then
            return string.format("%d", v)
        end
        return tostring(v)
    elseif tv == "string" then
        return encode_string(v)
    elseif tv == "table" then
        return encode_table(v, depth)
    end
    error("json: tipo non serializzabile " .. tv)
end

function json.encode(v)
    return encode_value(v, 0)
end

-- parser ricorsivo a discesa
local function skip_ws(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

local decode_value

local function decode_string(s, i)
    local out, k = {}, i + 1
    while k <= #s do
        local c = s:sub(k, k)
        if c == '"' then
            return table.concat(out), k + 1
        elseif c == "\\" then
            local n = s:sub(k + 1, k + 1)
            local map = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f",
                ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
            if n == "u" then
                local code = tonumber(s:sub(k + 2, k + 5), 16) or 63
                out[#out + 1] = string.char(code % 256)
                k = k + 6
            else
                out[#out + 1] = map[n] or n
                k = k + 2
            end
        else
            out[#out + 1] = c
            k = k + 1
        end
    end
    error("json: stringa non chiusa")
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then
        return decode_string(s, i)
    elseif c == "{" then
        local obj = {}
        i = i + 1
        i = skip_ws(s, i)
        if s:sub(i, i) == "}" then
            return obj, i + 1
        end
        while true do
            local key
            i = skip_ws(s, i)
            if s:sub(i, i) ~= '"' then
                error("json: attesa chiave a riga " .. i)
            end
            key, i = decode_string(s, i)
            i = skip_ws(s, i)
            if s:sub(i, i) ~= ":" then
                error("json: attesa ':' a riga " .. i)
            end
            local value
            value, i = decode_value(s, i + 1)
            obj[key] = value
            i = skip_ws(s, i)
            local sep = s:sub(i, i)
            if sep == "," then
                i = i + 1
            elseif sep == "}" then
                return obj, i + 1
            else
                error("json: attesa ',' o '}' a riga " .. i)
            end
        end
    elseif c == "[" then
        local arr = {}
        i = i + 1
        i = skip_ws(s, i)
        if s:sub(i, i) == "]" then
            return arr, i + 1
        end
        while true do
            local value
            value, i = decode_value(s, i)
            arr[#arr + 1] = value
            i = skip_ws(s, i)
            local sep = s:sub(i, i)
            if sep == "," then
                i = i + 1
            elseif sep == "]" then
                return arr, i + 1
            else
                error("json: attesa ',' o ']' a riga " .. i)
            end
        end
    elseif s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif s:sub(i, i + 3) == "null" then
        return nil, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[+%-]?%d*", i)
        if num and #num > 0 then
            return tonumber(num), i + #num
        end
        error("json: token inatteso a " .. i .. " (" .. c .. ")")
    end
end

function json.decode(s)
    if type(s) ~= "string" then
        return nil
    end
    local value = decode_value(s, 1)
    return value
end

return json
