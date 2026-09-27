--[[--
Checks that the English source strings and languages/it.po stay in sync:
every _("...") has an entry and every entry has the string.
--]]
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")

local SOURCES = { "main.lua", "tomedown_render.lua", "tomedown_update.lua", "_meta.lua" }
local PO = T.plugin .. "/languages/it.po"

-- extracts the strings passed to _( ... ), handling escapes
local function extract(path)
    local src = T.readFile(path)
    if not src then
        T.check(false, "source readable: " .. path)
        return {}
    end
    local out, i = {}, 1
    while true do
        local pos = src:find("_(", i, true)
        if not pos then
            break
        end
        local before = pos > 1 and src:sub(pos - 1, pos - 1) or ""
        if before:match("[%w_]") then
            i = pos + 2
        else
            local k = pos + 2
            while src:sub(k, k):match("%s") do
                k = k + 1
            end
            local literal, stop
            if src:sub(k, k + 1) == "[[" then
                -- _( [[ long string ]] ) as in _meta.lua
                local close = src:find("]]", k + 2, true)
                literal = close and src:sub(k + 2, close - 1) or nil
                stop = close and (close + 2) or #src + 1
            elseif src:sub(k, k) == '"' then
                local j, buf = k + 1, {}
                while j <= #src do
                    local c = src:sub(j, j)
                    if c == "\\" then
                        buf[#buf + 1] = src:sub(j, j + 1)
                        j = j + 2
                    elseif c == '"' then
                        break
                    else
                        buf[#buf + 1] = c
                        j = j + 1
                    end
                end
                literal = table.concat(buf)
                literal = literal:gsub("\\(.)", { ['"'] = '"', ["\\"] = "\\", ["n"] = "\n",
                    ["r"] = "\r", ["t"] = "\t" })
                stop = j + 1
            else
                literal = nil
                stop = pos + 2
            end
            if literal and literal ~= "" then
                out[literal] = (out[literal] or 0) + 1
            end
            i = stop or (pos + 2)
        end
    end
    return out
end

-- minimal .po parser: msgid/msgstr on single and continued lines
local function parsePO(path)
    local text = T.readFile(path)
    if not text then
        T.check(false, "po readable: " .. path)
        return {}, {}
    end
    local entries, order = {}, {}
    local cur_id, cur_str, mode
    local function unescape(s)
        return (s:gsub("\\(.)", { ['"'] = '"', ["\\"] = "\\", ["n"] = "\n",
            ["r"] = "\r", ["t"] = "\t" }))
    end
    local function flush()
        if cur_id ~= nil then
            entries[cur_id] = cur_str or ""
            order[#order + 1] = cur_id
        end
        cur_id, cur_str, mode = nil, nil, nil
    end
    for line in text:gmatch("[^\r\n]+") do
        local first = line:sub(1, 1)
        if first == "#" then
            -- comment: closes the previous entry
            if mode then flush() end
        elseif line:match("^msgid%s") then
            if mode then flush() end
            cur_id = unescape(line:match('^msgid%s+"(.*)"%s*$') or "")
            mode = "id"
        elseif line:match("^msgstr%s") then
            cur_str = unescape(line:match('^msgstr%s+"(.*)"%s*$') or "")
            mode = "str"
        elseif first == '"' then
            local chunk = unescape(line:match('^"(.*)"%s*$') or "")
            if mode == "id" then
                cur_id = (cur_id or "") .. chunk
            elseif mode == "str" then
                cur_str = (cur_str or "") .. chunk
            end
        elseif line == "" then
            if mode then flush() end
        end
    end
    flush()
    return entries, order
end

local function collectAll()
    local all, total = {}, 0
    for __, name in ipairs(SOURCES) do
        local found = extract(T.plugin .. "/" .. name)
        for str, n in pairs(found) do
            all[str] = (all[str] or 0) + n
            total = total + n
        end
    end
    return all, total
end

local source_strings, source_total = collectAll()
local po, order = parsePO(PO)

T.check(source_total > 30, "enough strings extracted from the sources (" .. source_total .. ")")
T.check(#order > 40, "po with enough entries (" .. #order .. ")")

-- header
T.check(T.contains(T.readFile(PO), "Language: it"), "header Language: it")
T.check(T.contains(T.readFile(PO), "charset=UTF-8"), "header UTF-8")
T.check(T.contains(T.readFile(PO), "Plural-Forms:"), "header plural forms")

-- no empty msgid apart from the header
local header = po[""]
T.check(header ~= nil, "po header present")
T.check(#order >= 2, "header + at least one entry")

-- duplicate entries
local seen, dup = {}, 0
for __, id in ipairs(order) do
    if seen[id] then
        dup = dup + 1
    end
    seen[id] = true
end
T.check(dup == 0, "no duplicate msgid (dup=" .. dup .. ")")

-- every source string is translated
local missing = {}
for str in pairs(source_strings) do
    if po[str] == nil then
        missing[#missing + 1] = str
    end
end
T.check(#missing == 0, "missing msgstr: " .. (#missing > 0 and ("'" .. missing[1] .. "'") or "nessuna"))

-- every po entry exists in the sources
local orphan = {}
for __, id in ipairs(order) do
    if id ~= "" and source_strings[id] == nil then
        orphan[#orphan + 1] = id
    end
end
T.check(#orphan == 0,
    "orphan entries in the po: " .. (#orphan > 0 and ("'" .. orphan[1] .. "'") or "nessuna"))

-- every entry (header excluded) has a translation
local empty = 0
for id, str in pairs(po) do
    if id ~= "" and (str == nil or str == "") then
        empty = empty + 1
    end
end
T.check(empty == 0, "empty translations: " .. empty)

-- same number of entries
T.check(#order - 1 == (function()
    local n = 0
    for str in pairs(source_strings) do
        n = n + 1
    end
    return n
end)(), "po and source entry counts match")

-- the modules that require tomedown_i18n declare it
for __, name in ipairs({ "main.lua", "tomedown_render.lua", "tomedown_update.lua" }) do
    T.check(T.contains(T.readFile(T.plugin .. "/" .. name), 'require("tomedown_i18n")'),
        name .. " requires tomedown_i18n")
end

-- tomedown_i18n points at languages/<lang>.po
local i18n_src = T.readFile(T.plugin .. "/tomedown_i18n.lua")
T.check(T.contains(i18n_src, "/languages/"), "tomedown_i18n legge da languages/")
T.check(T.contains(i18n_src, "GetText"), "tomedown_i18n uses KOReader's language")

T.finish("test_po")
