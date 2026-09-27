--[[
Update check for tomedown.

Settings shows the installed version and a "Check for updates…" entry;
with the optional background check enabled, a new release is noticed on
its own (KOReader start and menu open, at most once an hour). When one
is found the release notes of every newer release are shown together
(the fixes, newest first) and the releases page can be opened in the
browser: installing is still the zip from that page, so any installed
version can jump to any newer one without migrations.

Everything goes through the GitHub releases API of this repository.
The release LIST is fetched (not just the latest) so that someone on
0.2.0 who updates to 1.0 sees the notes of 0.3.0, 0.3.1 and 1.0 in one
window; per_page=100 keeps those intermediate notes from falling past
GitHub's default page of 30.

Compatibility rules for future versions (so the updater keeps working
from every old install):
  - repository and API URL never change;
  - tags are always vX.Y.Z;
  - release zips keep the tomedown.koplugin/ top-level folder;
  - settings keys are never renamed (add a migration instead).
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("tomedown_i18n")

local Update = {}

local RELEASES_URL = "https://api.github.com/repos/imanubdesigner/tomedown.koplugin/releases?per_page=100"
local RELEASES_PAGE = "https://github.com/imanubdesigner/tomedown.koplugin/releases"
local CHECK_INTERVAL = 3600 -- background check throttle, seconds

-- session-only state (nothing persisted)
local installed_version -- cache of getInstalledVersion()
local cached_version -- newest version newer than the installed one, or nil
local last_bg_check -- os.time() of the last background attempt
local bg_in_flight = false

local function pluginDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then
        return src:sub(2):match("^(.*)/[^/]+$")
    end
end

--- Version of this install, read from _meta.lua ("unknown" if unreadable).
function Update.getInstalledVersion()
    if installed_version then
        return installed_version
    end
    local dir = pluginDir()
    if dir then
        local ok, meta = pcall(dofile, dir .. "/_meta.lua")
        if ok and type(meta) == "table" and meta.version then
            installed_version = tostring(meta.version)
            return installed_version
        end
    end
    return "unknown"
end

--- Newest known update, or nil when everything is up to date.
function Update.getAvailableVersion()
    return cached_version
end

local function parseVersion(version)
    local parts = {}
    for part in tostring(version):gsub("^v", ""):gmatch("([^.]+)") do
        parts[#parts + 1] = tonumber(part) or 0
    end
    return parts
end

--- Numeric per-part comparison, missing parts count as 0, so jumps of
-- any size work: 1.0 > 0.3.1, 1.0.0 == 1.0, 0.10.0 > 0.9.0.
function Update.isNewer(candidate, installed)
    local a, b = parseVersion(candidate), parseVersion(installed)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x > y then
            return true
        end
        if x < y then
            return false
        end
    end
    return false
end

local function releaseTag(rel)
    return (tostring(rel.tag_name or ""):gsub("^v", ""))
end

--- GET url and decode the JSON body, or nil.
-- LuaSocket first (e-reader path), curl as a fallback where SSL or the
-- socket stack misbehaves (Android, desktop). Test seam: tests replace
-- Update.httpGetJSON with a fake and never reach the network.
function Update.httpGetJSON(url)
    local json = require("json")
    local ok_require, http, ltn12, socket, socketutil =
        pcall(function()
            return require("socket/http"),
                   require("ltn12"),
                   require("socket"),
                   require("socketutil")
        end)
    if ok_require then
        local body = {}
        local ok_req, code = pcall(function()
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT,
                socketutil.LARGE_TOTAL_TIMEOUT)
            local c = socket.skip(1, http.request{
                url = url,
                method = "GET",
                headers = {
                    ["User-Agent"] = "KOReader-Tomedown/" .. Update.getInstalledVersion(),
                    ["Accept"] = "application/vnd.github.v3+json",
                },
                sink = ltn12.sink.table(body),
                redirect = true,
            })
            socketutil:reset_timeout()
            return c
        end)
        if ok_req and code == 200 then
            local ok, data = pcall(json.decode, table.concat(body))
            if ok then
                return data
            end
        end
        pcall(function()
            socketutil:reset_timeout()
        end)
    end
    local ok_popen, handle = pcall(io.popen, string.format(
        "curl -s -L -H %q -H %q %q",
        "KOReader-Tomedown/" .. Update.getInstalledVersion(),
        "Accept: application/vnd.github.v3+json",
        url))
    if not ok_popen or not handle then
        return nil
    end
    local response = handle:read("*a")
    handle:close()
    if response and response ~= "" then
        local ok, data = pcall(json.decode, response)
        if ok then
            return data
        end
    end
    return nil
end

--- Wi-Fi gate: false = proceed now, true = waiting for the connection
-- (the callback re-enters once it is up; cancelling is a no-op).
function Update.gateOnConnection(retry)
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isConnected() then
        return false
    end
    NetworkMgr:runWhenConnected(function()
        if NetworkMgr:isConnected() then
            retry()
        end
    end)
    return true
end

function Update.offerReleasesPage(message)
    if Device:canOpenLink() then
        UIManager:show(ConfirmBox:new{
            text = message .. "\n\n" .. _("Open the releases page in a browser?"),
            ok_text = _("Open"),
            ok_callback = function()
                Device:openLink(RELEASES_PAGE)
            end,
        })
    else
        UIManager:show(InfoMessage:new{
            text = message,
            timeout = 3,
        })
    end
end

local function stripMarkdown(text)
    -- headings only at the start of a line: an inline "#12" must stay
    text = text:gsub("^#+%s*", "")
    text = text:gsub("\n#+%s*", "\n")
    text = text:gsub("%*%*(.-)%*%*", "%1")
    text = text:gsub("%*(.-)%*", "%1")
    text = text:gsub("`(.-)`", "%1")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Releases newer than the installed version, newest first, skipping
-- drafts and prereleases; each entry keeps version and raw body.
local function collectNewer(releases, installed)
    local newer = {}
    for __, rel in ipairs(releases) do
        if type(rel) == "table" and not rel.draft and not rel.prerelease then
            local version = releaseTag(rel)
            if Update.isNewer(version, installed) then
                newer[#newer + 1] = { version = version, body = rel.body }
            end
        end
    end
    return newer
end

--- Manual check from Settings: Wi-Fi gate, fetch, then either an
-- "up to date" notice or the TextViewer with all the fixes.
function Update.check()
    if Update.gateOnConnection(function()
        Update.check()
    end) then
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("Checking for updates…"),
        timeout = 1,
    })
    UIManager:scheduleIn(0.1, function()
        local installed = Update.getInstalledVersion()
        local releases = Update.httpGetJSON(RELEASES_URL)
        last_bg_check = os.time()
        if type(releases) ~= "table" or #releases == 0 then
            Update.offerReleasesPage(_("Could not check for updates."))
            return
        end
        local newer = collectNewer(releases, installed)
        if #newer == 0 then
            cached_version = nil
            UIManager:show(InfoMessage:new{
                text = T(_("Tomedown is up to date. Current version: %1"),
                    "v" .. installed),
                timeout = 3,
            })
            return
        end
        cached_version = newer[1].version
        local notes = {}
        for __, rel in ipairs(newer) do
            notes[#notes + 1] = "v" .. rel.version .. "\n" .. stripMarkdown(rel.body or "")
        end
        local viewer
        viewer = TextViewer:new{
            title = _("Update available!"),
            text = T(_("Installed: %1\nLatest: %2"), "v" .. installed,
                "v" .. cached_version)
                .. "\n\n" .. table.concat(notes, "\n\n"),
            buttons_table = {
                {
                    {
                        text = _("Close"),
                        callback = function()
                            UIManager:close(viewer)
                        end,
                    },
                    {
                        text = _("Open releases page"),
                        callback = function()
                            UIManager:close(viewer)
                            if Device:canOpenLink() then
                                Device:openLink(RELEASES_PAGE)
                            else
                                UIManager:show(InfoMessage:new{
                                    text = RELEASES_PAGE,
                                    timeout = 5,
                                })
                            end
                        end,
                    },
                },
            },
            add_default_buttons = false,
        }
        UIManager:show(viewer)
    end)
end

--- Background check: opt-in (the caller checks the setting), at most
-- once an hour, only with Wi-Fi already on, and quiet unless a newer
-- release exists - then a notification, with the fixes one tap away in
-- Settings.
function Update.checkBackground()
    if bg_in_flight then
        return
    end
    local now = os.time()
    if last_bg_check and (now - last_bg_check) < CHECK_INTERVAL then
        return
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isWifiOn() then
        return
    end
    bg_in_flight = true
    last_bg_check = now
    UIManager:scheduleIn(0.1, function()
        bg_in_flight = false
        local installed = Update.getInstalledVersion()
        local releases = Update.httpGetJSON(RELEASES_URL)
        if type(releases) ~= "table" then
            return
        end
        local newer = collectNewer(releases, installed)
        if #newer == 0 then
            cached_version = nil
            return
        end
        cached_version = newer[1].version
        UIManager:show(Notification:new{
            text = T(_("Tomedown update available: v%1"), cached_version),
        })
    end)
end

-- test hook: forget the session-only state
function Update._resetState()
    installed_version = nil
    cached_version = nil
    last_bg_check = nil
    bg_in_flight = false
end

return Update
