--[[--
Tests for tomedown_update.lua and the update entries in Settings:
version display, manual check (up to date / fixes shown / failure /
offline gate), version jumps (0.2.0 -> 1.0), background check
(throttle, Wi-Fi gate, notification) - all against a fake GitHub
response, so nothing here touches the network.
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
T.check(#settings == 8, "settings entries: " .. #settings)
T.check(settings[6].text_func() == "Version " .. INSTALLED,
    "version row: " .. settings[6].text_func())
T.check(settings[7].text == "Check for updates…", "check row")
T.check(settings[8].text == "Check for updates in background",
    "background toggle row")
T.check(settings[8].checked_func() == false, "background check off by default")

settings[8].callback()
T.check(store.tomedown and store.tomedown.update_check == true,
    "background check toggled on")
T.check(settings[8].checked_func() == true, "toggle reflects the setting")
settings[8].callback()
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
    release("v1.0.0", "# Fixes\n- **bold** and `code` and *italic*"),
    release("v0.3.1", "Fix B for issue #12"),
    release("v0.3.0", "Fix A"),
    release("v0.1.0", "old"),
})
Update.check()
UIManager:runPending()
local viewer = TextViewer.last
T.check(viewer ~= nil, "viewer shown")
T.check(viewer.title == "Update available!", "viewer title: " .. tostring(viewer.title))
T.check(T.contains(viewer.text, "Installed: v" .. INSTALLED), "installed line")
T.check(T.contains(viewer.text, "Latest: v1.0.0"),
    "latest skips draft and prerelease")
T.check(not T.contains(viewer.text, "9.9.9") and not T.contains(viewer.text, "beta"),
    "draft and prerelease absent: " .. tostring(viewer.text))
T.check(T.contains(viewer.text, "v1.0.0") and T.contains(viewer.text, "v0.3.1")
    and T.contains(viewer.text, "v0.3.0"), "header for every newer release")
T.check(T.contains(viewer.text, "Fix A") and T.contains(viewer.text, "Fix B")
    and T.contains(viewer.text, "Fixes"), "notes of every newer release")
T.check(not T.contains(viewer.text, "**") and not T.contains(viewer.text, "`")
    and not T.contains(viewer.text, "# "), "markdown stripped: " .. tostring(viewer.text))
T.check(T.contains(viewer.text, "issue #12"), "inline #12 kept: " .. tostring(viewer.text))
T.check(Update.getAvailableVersion() == "1.0.0",
    "cached available version: " .. tostring(Update.getAvailableVersion()))

local version_row = plugin:genSettingsMenu()[6]
T.check(T.contains(version_row.text_func(), "v1.0.0 available"),
    "version row shows the update: " .. version_row.text_func())

local buttons = viewer.buttons_table[1]
T.check(buttons[1].text == "Close" and buttons[2].text == "Open releases page",
    "viewer buttons")
buttons[2].callback()
T.check(Device.links[1] == RELEASES_PAGE,
    "releases page opened: " .. tostring(Device.links[1]))
local viewer_still_open = false
for __, widget in ipairs(UIManager.shown) do
    if widget.__widget == "TextViewer" then
        viewer_still_open = true
    end
end
T.check(not viewer_still_open, "viewer closed")

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
fakeReleases({ release("v1.0.0", "brand new") })
NetworkMgr.wifi_on = false
Update.checkBackground()
T.check(#urls == 0 and UIManager:pendingCount() == 0,
    "no background check with Wi-Fi off")

NetworkMgr.wifi_on = true
Update.checkBackground()
T.check(UIManager:pendingCount() == 1, "background check scheduled")
UIManager:runPending()
T.check(#urls == 1, "background fetched once: " .. #urls)
T.check(Notification.last_text == "Tomedown update available: v1.0.0",
    "notification: " .. tostring(Notification.last_text))
T.check(Update.getAvailableVersion() == "1.0.0", "background caches the version")

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
fakeReleases({ release("v1.0.0", "") })

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
T.check(Notification.last_text == "Tomedown update available: v1.0.0",
    "scheduled check notifies: " .. tostring(Notification.last_text))

T.finish("test_update")
