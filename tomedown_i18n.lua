--[[
Traduzione del plugin.

KOReader NON carica in automatico le .po dei plugin (gettext del core usa solo
l10n/<lang>/koreader.mo), quindi questo modulo legge lui stesso
languages/<lang>.po in base alla lingua attiva di KOReader.

Uso: local _ = require("tomedown_i18n")  poi  _("stringa inglese")
Fuori da una lingua tradotta (inglese o nessuna lingua) ritorna il msgid.
]]

local GetText = require("gettext")

local tomedown_i18n = {}
local catalog = {}
local loaded_lang = false -- false = mai caricato, stringa = lingua già caricata

local function pluginDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then
        return src:sub(2):match("^(.*)/[^/]+$")
    end
end

local function field(t, k)
    return t[k]
end

local function currentLang()
    local lang
    if type(GetText) == "table" then
        local ok, value = pcall(field, GetText, "current_lang")
        if ok then lang = value end
    end
    if not lang or lang == "" or lang == "C" then
        local settings = rawget(_G, "G_reader_settings")
        if settings and settings.readSetting then
            local ok, value = pcall(settings.readSetting, settings, "language")
            if ok and value then lang = value end
        end
    end
    if not lang or lang == "" or lang == "C" then return nil end
    return lang
end

local function unescape(s)
    return (s:gsub("\\(.)", {
        ['"'] = '"',
        ["\\"] = "\\",
        ["n"] = "\n",
        ["r"] = "\r",
        ["t"] = "\t",
    }))
end

-- lettore minimale di .po: msgid/msgstr, righe "..." continue, commenti
local function loadPO(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()

    local cat = {}
    local cur_id, cur_str, mode
    local function flush()
        if mode == "str" and cur_id and cur_id ~= "" and cur_str and cur_str ~= "" then
            cat[cur_id] = cur_str
        end
        cur_id, cur_str, mode = nil, nil, nil
    end

    for line in text:gmatch("[^\r\n]+") do
        local first = line:sub(1, 1)
        if first == "#" then
            if mode == "str" then flush() end
        elseif line:match("^msgid%s") then
            flush()
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
            if mode == "str" then flush() end
        end
    end
    flush()
    return cat
end

local function ensure()
    local lang = currentLang()
    if lang == loaded_lang then return end
    loaded_lang = lang
    catalog = {}
    if not lang or lang:match("^en") then return end
    local dir = pluginDir()
    if not dir then return end
    local po = loadPO(dir .. "/languages/" .. lang .. ".po")
        or loadPO(dir .. "/languages/" .. lang:sub(1, 2) .. ".po")
    if po then
        catalog = po
    end
end

function tomedown_i18n.gettext(msgid)
    ensure()
    return catalog[msgid] or msgid
end

setmetatable(tomedown_i18n, {
    __call = function(_, msgid)
        return tomedown_i18n.gettext(msgid)
    end,
})

return tomedown_i18n
