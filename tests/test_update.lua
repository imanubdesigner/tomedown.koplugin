--[[--
Tests for tomedown_update.lua and the update entries in Settings:
version display, manual check (up to date / fixes shown / failure /
offline gate), version jumps (0.2.0 -> 1.0), background check
(throttle, Wi-Fi gate, notification) and the install flow
("Update and restart": download, unpack over the plugin folder,
restart prompt, fallbacks) - all against a fake GitHub response, so
nothing here touches the network.
--]]
local HERE = arg[0]:match("^(.*)/") or "."
package.path = HERE .. "/?.lua;" .. package.path
local T = require("common")

-- --------------------------------------------------------------- environment

local store = {}
G_reader_settings = {
    readSetting = function(_, key, default)
        if store[key] == nil then
            return default
        end
        return store[key]
    end,
    saveSetting = function(_, key, value)
        store[key] = value
    end,
    isTrue = function()
        return false
    end,
}

local GetText = require("gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local ConfirmBox = require("ui/widget/confirmbox")
local Notification = require("ui/widget/notification")
local Device = require("device")
local NetworkMgr = require("ui/network/manager")
GetText.current_lang = nil

local Update = require("tomedown_update")

local RELEASES_PAGE = "https://github.com/imanubdesigner/tomedown.koplugin/releases"
local urls = {}

local function fakeReleases(list)
    urls = {}
    Update.httpGetJSON = function(url)
        urls[#urls + 1] = url
        return list
    end
end

local function release(tag, body, extra)
    local rel = { tag_name = tag, body = body or "" }
    if extra then
        for k, v in pairs(extra) do
            rel[k] = v
        end
    end
    return rel
end

local function clearStore()
    for k in pairs(store) do
        store[k] = nil
    end
end

local function resetWidgets()
    UIManager:reset()
    Device:reset()
    NetworkMgr:reset()
    InfoMessage.last_text = nil
    TextViewer.last = nil
    ConfirmBox.last = nil
    Notification.last_text = nil
end

-- ------------------------------------------------------------ 1. version

local INSTALLED = Update.getInstalledVersion()
T.check(INSTALLED:match("^%d+%.%d+") ~= nil,
    "installed version from _meta.lua: " .. INSTALLED)
T.check(Update.getAvailableVersion() == nil, "no update known yet")

-- fake versions always newer than the installed one, whatever it is:
-- PATCH < MINOR < MAJOR, all strictly above INSTALLED
local function versionParts(v)
    local p = {}
    for x in tostring(v):gsub("^v", ""):gmatch("([^.]+)") do
        p[#p + 1] = tonumber(x) or 0
    end
    return p
end
local function bumped(part)
    local q = versionParts(INSTALLED)
    for n = 1, 3 do
        q[n] = q[n] or 0
    end
    q[part] = q[part] + 1
    for n = part + 1, 3 do
        q[n] = 0
    end
    return table.concat(q, ".")
end
local PATCH = bumped(3)
local MINOR = bumped(2)
local MAJOR = bumped(1)

-- ------------------------------------------------------- 2. version jumps

local cases = {
    { "0.2.0", "0.1.0", true },
    { "1.0", "0.3.1", true },
    { "1.0.0", "1.0", false },
    { "0.3.1", "0.3.1", false },
    { "0.10.0", "0.9.0", true },
    { "0.9.0", "0.10.0", false },
    { "0.3.1", "0.3.0", true },
    { "1.0.0", "0.2.0", true },
    { "v0.5.0", "0.1.0", true },
    { "0.1.0", "0.2.0", false },
}
for __, c in ipairs(cases) do
    T.check(Update.isNewer(c[1], c[2]) == c[3],
        "isNewer(" .. c[1] .. ", " .. c[2] .. ") = " .. tostring(c[3]))
end

-- --------------------------------------------------------- 3. settings UI

local ui = {
    cloudstorage = nil,
    menu = { registerToMainMenu = function() end },
    bookinfo = {},
    document = { file = nil },
    annotation = nil,
}
local MdBook = require("main")
local plugin = MdBook:new { ui = ui }

resetWidgets()
fakeReleases({})

local settings = plugin:genSettingsMenu()
T.check(#settings == 9, "settings entries: " .. #settings)
T.check(settings[6].text == "Include page bookmarks", "page bookmarks row")
T.check(settings[7].text_func() == "Version " .. INSTALLED,
    "version row: " .. settings[7].text_func())
T.check(settings[8].text == "Check for updates…", "check row")
T.check(settings[9].text == "Check for updates in background",
    "background toggle row")
T.check(settings[9].checked_func() == false, "background check off by default")

settings[9].callback()
T.check(store.tomedown and store.tomedown.update_check == true,
    "background check toggled on")
T.check(settings[9].checked_func() == true, "toggle reflects the setting")
settings[9].callback()
T.check(store.tomedown.update_check == false, "background check toggled off")

-- ------------------------------------------- 4. manual check: up to date

resetWidgets()
Update._resetState()
NetworkMgr.connected = true
fakeReleases({ release("v" .. INSTALLED, "same as installed") })
Update.check()
UIManager:runPending()
T.check(T.contains(InfoMessage.last_text or "", "up to date"),
    "up to date message: " .. tostring(InfoMessage.last_text))
T.check(T.contains(InfoMessage.last_text or "", INSTALLED),
    "current version in the message")
T.check(TextViewer.last == nil, "no viewer when up to date")
T.check(#urls == 1, "one request: " .. #urls)
T.check(urls[1]:find("per_page=100", 1, true) ~= nil,
    "release list fetched with per_page=100: " .. tostring(urls[1]))
T.check(Update.getAvailableVersion() == nil, "nothing cached")

-- --------------------------------------- 5. manual check: fixes shown

resetWidgets()
Update._resetState()
fakeReleases({
    release("v9.9.9", "draft only", { draft = true }),
    release("v2.0.0-beta", "prerelease only", { prerelease = true }),
    release("v" .. MAJOR, "# Fixes\n- **bold** and `code` and *italic*"),
    release("v" .. MINOR, "Fix A"),
    release("v" .. PATCH, "Fix B for issue #12"),
    release("v0.0.0", "old"),
})
Update.check()
UIManager:runPending()
local viewer = TextViewer.last
T.check(viewer ~= nil, "viewer shown")
T.check(viewer.title == "Update available!", "viewer title: " .. tostring(viewer.title))
T.check(T.contains(viewer.text, "Installed: v" .. INSTALLED), "installed line")
T.check(T.contains(viewer.text, "Latest: v" .. MAJOR),
    "latest skips draft and prerelease")
T.check(not T.contains(viewer.text, "9.9.9") and not T.contains(viewer.text, "beta"),
    "draft and prerelease absent: " .. tostring(viewer.text))
T.check(T.contains(viewer.text, "v" .. MAJOR) and T.contains(viewer.text, "v" .. PATCH)
    and T.contains(viewer.text, "v" .. MINOR), "header for every newer release")
T.check(T.contains(viewer.text, "Fix A") and T.contains(viewer.text, "Fix B")
    and T.contains(viewer.text, "Fixes"), "notes of every newer release")
T.check(viewer.text_format == "md",
    "notes rendered as markdown: " .. tostring(viewer.text_format))
T.check(T.contains(viewer.text, "**bold**") and T.contains(viewer.text, "# Fixes")
    and T.contains(viewer.text, "`code`"),
    "markdown kept for rendering: " .. tostring(viewer.text))
T.check(T.contains(viewer.text, "issue #12"), "inline #12 kept: " .. tostring(viewer.text))
T.check(Update.getAvailableVersion() == MAJOR,
    "cached available version: " .. tostring(Update.getAvailableVersion()))

local version_row = plugin:genSettingsMenu()[7]
T.check(T.contains(version_row.text_func(), "v" .. MAJOR .. " available"),
    "version row shows the update: " .. version_row.text_func())

local buttons = viewer.buttons_table[1]
T.check(buttons[1].text == "Close" and buttons[2].text == "Update and restart",
    "viewer buttons")
-- this fake release ships no zip asset: the button falls back to the
-- releases page instead of installing
buttons[2].callback()
T.check(ConfirmBox.last ~= nil
    and T.contains(ConfirmBox.last.text or "",
        "No download available for this release."),
    "no-zip fallback: " .. tostring(ConfirmBox.last and ConfirmBox.last.text))
ConfirmBox.last.ok_callback()
T.check(Device.links[1] == RELEASES_PAGE,
    "releases page opened: " .. tostring(Device.links[1]))
local viewer_still_open = false
for __, widget in ipairs(UIManager.shown) do
    if widget.__widget == "TextViewer" then
        viewer_still_open = true
    end
end
T.check(not viewer_still_open, "viewer closed")

-- a KOReader whose TextViewer cannot render markdown gets the plain,
-- stripped notes (what every version showed before)
local saved_formats = TextViewer.html_text_formats
TextViewer.html_text_formats = nil
resetWidgets()
Update._resetState()
Update.check()
UIManager:runPending()
local plain = TextViewer.last
T.check(plain ~= nil, "fallback viewer shown")
T.check(plain.text_format == nil,
    "fallback stays plain text: " .. tostring(plain.text_format))
T.check(not T.contains(plain.text, "**") and not T.contains(plain.text, "# "),
    "fallback strips markdown: " .. tostring(plain.text))
T.check(T.contains(plain.text, "Fix A"), "fallback keeps the notes")
TextViewer.html_text_formats = saved_formats

-- ------------------------------------------------ 6. manual check: failure

resetWidgets()
Update._resetState()
urls = {}
Update.httpGetJSON = function(url)
    urls[#urls + 1] = url
    return nil
end
Update.check()
UIManager:runPending()
T.check(ConfirmBox.last ~= nil, "confirm box on failure")
T.check(T.contains(ConfirmBox.last.text or "", "Could not check for updates."),
    "failure message: " .. tostring(ConfirmBox.last and ConfirmBox.last.text))
ConfirmBox.last.ok_callback()
T.check(Device.links[1] == RELEASES_PAGE, "releases page offered on failure")

-- ------------------------------------------------ 7. manual check: offline

resetWidgets()
Update._resetState()
fakeReleases({ release("v" .. INSTALLED, "") })
NetworkMgr.connected = false
Update.check()
T.check(#urls == 0, "no request while offline")
T.check(NetworkMgr.pending ~= nil, "waiting for the connection")
NetworkMgr:goConnected()
UIManager:runPending()
T.check(#urls == 1, "request once connected: " .. #urls)

-- --------------------------------------------------- 8. background check

resetWidgets()
Update._resetState()
fakeReleases({ release("v" .. MAJOR, "brand new") })
NetworkMgr.wifi_on = false
Update.checkBackground()
T.check(#urls == 0 and UIManager:pendingCount() == 0,
    "no background check with Wi-Fi off")

NetworkMgr.wifi_on = true
Update.checkBackground()
T.check(UIManager:pendingCount() == 1, "background check scheduled")
UIManager:runPending()
T.check(#urls == 1, "background fetched once: " .. #urls)
T.check(Notification.last_text == "Tomedown update available: v" .. MAJOR,
    "notification: " .. tostring(Notification.last_text))
T.check(Update.getAvailableVersion() == MAJOR, "background caches the version")

Update.checkBackground()
T.check(#urls == 1, "throttled for the next hour")

resetWidgets()
Update._resetState()
fakeReleases({ release("v" .. INSTALLED, "") })
Update.checkBackground()
UIManager:runPending()
T.check(Notification.last_text == nil, "silent when up to date")

-- --------------------------------------- 9. the menu triggers the check

resetWidgets()
Update._resetState()
clearStore()
fakeReleases({ release("v" .. MAJOR, "") })

-- background off: starting KOReader and opening the menu do nothing
MdBook:new { ui = ui }
local menu_items = {}
plugin:addToMainMenu(menu_items)
T.check(UIManager:pendingCount() == 0, "nothing scheduled while disabled")

-- background on: start schedules the slow check, menu open the quick one
store.tomedown = { update_check = true }
MdBook:new { ui = ui }
T.check(UIManager:pendingCount() == 1, "start schedules the check")
T.check(UIManager.delay_log[1] == 10, "start waits 10s: " .. tostring(UIManager.delay_log[1]))

plugin:addToMainMenu(menu_items)
T.check(UIManager:pendingCount() == 2, "menu open schedules the check too")
T.check(UIManager.delay_log[2] == 0.1, "menu check is immediate")

UIManager:runPending()
T.check(#urls >= 1, "the scheduled check ran: " .. #urls)
T.check(Notification.last_text == "Tomedown update available: v" .. MAJOR,
    "scheduled check notifies: " .. tostring(Notification.last_text))

-- --------------------------------------- 10. install: update and restart

local Archiver = require("ffi/archiver")
local lfs = require("libs/libkoreader-lfs")
local cache_dir = require("datastorage"):getSettingsDir() .. "/tomedown_cache"

-- 10a. happy path: download the zip, unpack it over the plugin folder,
-- ask for the restart, restart on confirm
resetWidgets()
Update._resetState()
Archiver.reset()
NetworkMgr.connected = true
fakeReleases({
    release("v" .. MAJOR, "# New\n- auto update", {
        assets = {
            {
                name = "tomedown.koplugin-v" .. MAJOR .. ".zip",
                browser_download_url = "https://github.com/example/dl.zip",
            },
        },
    }),
})
Update.check()
UIManager:runPending()
viewer = TextViewer.last
buttons = viewer.buttons_table[1]

local downloads = {}
Update.httpDownload = function(url, path)
    downloads[#downloads + 1] = { url = url, path = path }
    return true
end
Archiver.entries = {
    "tomedown.koplugin/",
    "tomedown.koplugin/main.lua",
    "tomedown.koplugin/_meta.lua",
    "tomedown.koplugin/languages/it.po",
    "tomedown.koplugin/tomedown_update.lua",
}
buttons[2].callback()
UIManager:runPending()
T.check(#downloads == 1
    and downloads[1].url == "https://github.com/example/dl.zip",
    "zip fetched from the release asset: "
        .. tostring(downloads[1] and downloads[1].url))
T.check(downloads[1].path:find("tomedown_cache/tomedown.koplugin.zip", 1, true)
        ~= nil,
    "zip lands in the cache dir: " .. tostring(downloads[1].path))
T.check(#Archiver.extracted == 4,
    "bare root folder skipped, 4 files extracted: " .. #Archiver.extracted)
local first = Archiver.extracted[1]
T.check(first.src == "tomedown.koplugin/main.lua"
        and first.dest == T.plugin .. "/main.lua",
    "root folder stripped: " .. first.src .. " -> " .. tostring(first.dest))
T.check(not T.fileExists(cache_dir .. "/tomedown.koplugin.zip"),
    "zip removed after unpacking")
T.check(ConfirmBox.last ~= nil
        and T.contains(ConfirmBox.last.text, "Tomedown updated to v" .. MAJOR)
        and T.contains(ConfirmBox.last.text, "Restart KOReader now?"),
    "restart prompt: " .. tostring(ConfirmBox.last and ConfirmBox.last.text))
T.check(ConfirmBox.last.ok_text == "Restart", "restart button label")
T.check(UIManager.restarted == 0, "no restart before the prompt is confirmed")
ConfirmBox.last.ok_callback()
T.check(UIManager.restarted == 1, "restart requested")

-- 10b. download failure: reason attached, releases page offered
resetWidgets()
Update._resetState()
Update.httpDownload = function()
    return false, "the connection timed out"
end
Update.install("https://example/nope.zip", "1.0.0")
UIManager:runPending()
T.check(ConfirmBox.last ~= nil
        and T.contains(ConfirmBox.last.text,
            "Download failed (the connection timed out)"),
    "download failure with reason: "
        .. tostring(ConfirmBox.last and ConfirmBox.last.text))
T.check(UIManager.restarted == 0, "no restart after a failed download")
ConfirmBox.last.ok_callback()
T.check(Device.links[1] == RELEASES_PAGE,
    "releases page opened after the download failure")

-- 10c. unpack failure: message with the reason, no restart prompt
resetWidgets()
Update._resetState()
Archiver.reset()
Archiver.entries = { "tomedown.koplugin/main.lua" }
Archiver.extract_fails = true
Update.httpDownload = function()
    return true
end
Update.install("https://example/x.zip", "1.0.0")
UIManager:runPending()
T.check(T.contains(InfoMessage.last_text or "",
        "Installation failed: extract failed"),
    "unpack failure message: " .. tostring(InfoMessage.last_text))
T.check(ConfirmBox.last == nil, "no restart prompt on unpack failure")
T.check(UIManager.restarted == 0, "no restart after a failed unpack")
Archiver.reset()
T.rmrf(cache_dir)

-- ------------------------------- 11. errors inside scheduled actions
-- an error escaping the scheduler kills the whole reader on device
-- (crash.log: "attempt to use a closed file" in httpDownload took
-- KOReader down mid-update): every scheduled body must report instead

resetWidgets()
Update._resetState()
NetworkMgr.connected = true
Update.httpGetJSON = function()
    error("boom-check")
end
Update.check()
local check_survived = pcall(UIManager.runPending, UIManager)
T.check(check_survived, "errors in the check body are caught")
T.check(ConfirmBox.last ~= nil
        and T.contains(ConfirmBox.last.text or "", "Could not check for updates."),
    "check failure reported: "
        .. tostring(ConfirmBox.last and ConfirmBox.last.text))

resetWidgets()
Update._resetState()
Update.httpDownload = function()
    error("boom-download")
end
Update.install("https://example/x.zip", "1.0.0")
local install_survived = pcall(UIManager.runPending, UIManager)
T.check(install_survived, "errors in the install body are caught")
T.check(T.contains(InfoMessage.last_text or "", "Installation failed:")
        and T.contains(InfoMessage.last_text, "boom-download"),
    "install failure reported: " .. tostring(InfoMessage.last_text))
T.check(UIManager.restarted == 0, "no restart after an unexpected error")
T.rmrf(cache_dir)

T.finish("test_update")
