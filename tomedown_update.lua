--[[
Update check for tomedown.

Settings groups this under "Updates": a check row that doubles as the
installed-version display, a changelog viewer, the optional background
check, the Beta Releases toggle and a reset to the latest stable
release. With the background check enabled, a new release is noticed on
its own (KOReader start and menu open, at most once an hour). When one
is found the release notes of every newer release are shown together
(the fixes, newest first) with an "Update and restart" button that
downloads the release zip, unpacks it over the plugin folder and asks
to restart KOReader - any failure falls back to opening the releases
page so the zip can be taken by hand.

Everything goes through the GitHub releases API of this repository.
The release LIST is fetched (not just the latest) so that someone on
0.2.0 who updates to 1.0 sees the notes of 0.3.0, 0.3.1 and 1.0 in one
window; per_page=100 keeps those intermediate notes from falling past
GitHub's default page of 30.

Compatibility rules for future versions (so the updater keeps working
from every old install):
  - repository and API URL never change;
  - tags are always vX.Y.Z, prereleases vX.Y.Z-beta.N;
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

--- Numeric parts of a tag plus its prerelease counter: "v0.4.0-beta.1"
-- parses to {0, 4, 0} and 1, a plain "0.4.0" to {0, 4, 0} and no
-- counter ("-beta" with no number counts as 0).
local function parseVersion(version)
    local text = tostring(version):gsub("^v", "")
    local base = text:match("^([^%-]+)") or text
    local prerelease
    if base ~= text then
        prerelease = tonumber(text:sub(#base + 2):match("(%d+)$")) or 0
    end
    local parts = {}
    for part in base:gmatch("([^.]+)") do
        parts[#parts + 1] = tonumber(part) or 0
    end
    return parts, prerelease
end

--- Numeric per-part comparison, missing parts count as 0, so jumps of
-- any size work: 1.0 > 0.3.1, 1.0.0 == 1.0, 0.10.0 > 0.9.0. On a full
-- tie the stable release wins over its own prerelease (0.4.0 >
-- 0.4.0-beta.1) and a higher counter wins between prereleases
-- (beta.2 > beta.1), so a beta tester is always offered the release.
function Update.isNewer(candidate, installed)
    local a, ra = parseVersion(candidate)
    local b, rb = parseVersion(installed)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x > y then
            return true
        end
        if x < y then
            return false
        end
    end
    if ra and not rb then
        return false
    end
    if rb and not ra then
        return true
    end
    if ra and rb then
        return ra > rb
    end
    return false
end

local function releaseTag(rel)
    return (tostring(rel.tag_name or ""):gsub("^v", ""))
end

--- Download URL of the release's zip asset, or nil (the releases page
-- is the fallback when a release ships without one).
local function releaseZip(rel)
    if type(rel.assets) == "table" then
        for __, asset in ipairs(rel.assets) do
            if type(asset) == "table"
                and type(asset.name) == "string"
                and asset.name:match("%.zip$")
                and type(asset.browser_download_url) == "string" then
                return asset.browser_download_url
            end
        end
    end
    return nil
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

--- Whether this KOReader's TextViewer can render Markdown natively
--- (text_format = "md" converts the notes to HTML, so bold, headings
--- and lists are shown formatted instead of as raw markers). Older
--- versions fall back to the plain, stripped text above.
local function canRenderMarkdown()
    if type(TextViewer.html_text_formats) ~= "table"
        or not TextViewer.html_text_formats.md then
        return false
    end
    local ok, Converter = pcall(require, "apps/filemanager/filemanagerconverter")
    return ok and type(Converter) == "table"
        and type(Converter.mdToHtml) == "function"
end

--- The "Beta Releases" Settings toggle (default off): with it on, the
-- prereleases are offered too. Reads the same settings key as main.lua.
local function betaEnabled()
    local settings = G_reader_settings
        and G_reader_settings:readSetting("tomedown", {})
    return settings and settings.beta_releases == true
end

--- Releases newer than the installed version, newest first, skipping
-- drafts and - unless the Beta Releases toggle is on - prereleases;
-- each entry keeps version, raw body and the zip download URL of that
-- release.
local function collectNewer(releases, installed)
    local newer = {}
    local beta = betaEnabled()
    for __, rel in ipairs(releases) do
        if type(rel) == "table" and not rel.draft
                and (beta or not rel.prerelease) then
            local version = releaseTag(rel)
            if Update.isNewer(version, installed) then
                newer[#newer + 1] = {
                    version = version,
                    body = rel.body,
                    zip = releaseZip(rel),
                }
            end
        end
    end
    return newer
end

-- --------------------------------------------------------------- changelog

-- The releases list is fetched by every check anyway, so its notes are
-- folded into a persisted cache (newest first, capped) and "View
-- changelog" can page through them offline; Refresh re-fetches.
local CHANGELOG_KEY = "tomedown_changelog"
local CHANGELOG_MAX = 25
local CHANGELOG_BODY_MAX = 8 * 1024

--- Fold a releases list into the persisted cache. Drafts are always
-- dropped; prereleases only while the Beta Releases toggle is on, so
-- the changelog shows exactly what this install would be offered.
-- Duplicates by tag are dropped too (GitHub can repeat a release across
-- pages of the list).
local function changelogSeed(releases)
    if type(releases) ~= "table" then
        return
    end
    local beta = betaEnabled()
    local out, seen = {}, {}
    for __, rel in ipairs(releases) do
        if type(rel) == "table" and not rel.draft
                and (beta or not rel.prerelease) then
            local tag = tostring(rel.tag_name or "")
            if tag ~= "" and not seen[tag] then
                seen[tag] = true
                out[#out + 1] = {
                    tag = tag,
                    date = type(rel.published_at) == "string"
                        and rel.published_at:sub(1, 10) or nil,
                    body = tostring(rel.body or ""):sub(1, CHANGELOG_BODY_MAX),
                }
                if #out >= CHANGELOG_MAX then
                    break
                end
            end
        end
    end
    if #out > 0 then
        G_reader_settings:saveSetting(CHANGELOG_KEY, out)
    end
end

local function changelogCached()
    local rels = G_reader_settings:readSetting(CHANGELOG_KEY)
    if type(rels) == "table" and #rels > 0 then
        return rels
    end
end

-- forward declaration: the viewer's Refresh button refetches through it
local changelogFetchShow

--- The paginated viewer. idx 1 = newest; Markdown rendered when this
-- KOReader can, the raw markers stripped otherwise. Chevrons (U+2039/
-- U+203A) rather than Nerd Font glyphs: a stock TextViewer button only
-- carries the standard UI font.
local function changelogShow(rels, idx)
    local as_md = canRenderMarkdown()
    local rel = rels[idx]
    local head = "v" .. (tostring(rel.tag or ""):gsub("^v", ""))
    if rel.date then
        head = head .. "  (" .. rel.date .. ")"
    end
    local body = tostring(rel.body or "")
    if not as_md then
        body = stripMarkdown(body)
    end
    if body:match("^%s*$") then
        body = _("(no notes for this release)")
    end
    local text = (as_md and ("## " .. head) or head) .. "\n\n" .. body
    local viewer
    local function repage(new_idx)
        UIManager:close(viewer)
        changelogShow(rels, new_idx)
    end
    viewer = TextViewer:new{
        title = T(_("Changelog (%1 of %2)"), idx, #rels),
        text = text,
        text_format = as_md and "md" or nil,
        buttons_table = {
            {
                {
                    text = "\xE2\x80\xB9 " .. _("Older"),
                    enabled = idx < #rels,
                    callback = function() repage(idx + 1) end,
                },
                {
                    text = _("Newer") .. " \xE2\x80\xBA",
                    enabled = idx > 1,
                    callback = function() repage(idx - 1) end,
                },
            },
            {
                {
                    text = _("Refresh"),
                    callback = function()
                        UIManager:close(viewer)
                        changelogFetchShow()
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(viewer)
                    end,
                },
            },
        },
        add_default_buttons = false,
    }
    UIManager:show(viewer)
end

--- Always fetch: the cold cache and the viewer's Refresh both land here.
function changelogFetchShow()
    if Update.gateOnConnection(function()
        changelogFetchShow()
    end) then
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("Fetching changelog..."),
        timeout = 1,
    })
    UIManager:scheduleIn(0.1, function()
        -- safety net: a scheduled body must not take the reader down
        local shown = false
        local ok_run = pcall(function()
            local releases = Update.httpGetJSON(RELEASES_URL)
            if type(releases) ~= "table" or #releases == 0 then
                return
            end
            changelogSeed(releases)
            local rels = changelogCached()
            if rels then
                changelogShow(rels, 1)
                shown = true
            end
        end)
        if not (ok_run and shown) then
            UIManager:show(InfoMessage:new{
                text = _("Could not fetch the changelog."),
                timeout = 3,
            })
        end
    end)
end

--- "View changelog": the persisted notes right away (works offline);
-- only a cold cache goes to the network.
function Update.showChangelog()
    local rels = changelogCached()
    if rels then
        changelogShow(rels, 1)
        return
    end
    changelogFetchShow()
end

--- Manual check from Settings: Wi-Fi gate, fetch, then either an
-- "up to date" notice or the TextViewer with all the fixes.
--- Body of the scheduled manual check, kept separate so the caller can
-- run it behind pcall (see Update.check).
local function checkBody()
    local installed = Update.getInstalledVersion()
    local releases = Update.httpGetJSON(RELEASES_URL)
    last_bg_check = os.time()
    if type(releases) ~= "table" or #releases == 0 then
        Update.offerReleasesPage(_("Could not check for updates."))
        return
    end
    changelogSeed(releases)
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
    local as_md = canRenderMarkdown()
    local notes = {}
    for __, rel in ipairs(newer) do
        if as_md then
            notes[#notes + 1] = "## v" .. rel.version .. "\n\n" .. (rel.body or "")
        else
            notes[#notes + 1] = "v" .. rel.version .. "\n" .. stripMarkdown(rel.body or "")
        end
    end
    local viewer
    viewer = TextViewer:new{
        title = _("Update available!"),
        text = T(_("Installed: %1\nLatest: %2"), "v" .. installed,
            "v" .. cached_version)
            .. "\n\n" .. table.concat(notes, "\n\n"),
        text_format = as_md and "md" or nil,
        buttons_table = {
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(viewer)
                    end,
                },
                {
                    text = _("Update and restart"),
                    callback = function()
                        UIManager:close(viewer)
                        local zip = newer[1].zip
                        if not zip then
                            Update.offerReleasesPage(
                                _("No download available for this release."))
                            return
                        end
                        Update.install(zip, newer[1].version)
                    end,
                },
            },
        },
        add_default_buttons = false,
    }
    UIManager:show(viewer)
end

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
        -- safety net: an unhandled error here would kill the whole
        -- reader (it runs in the scheduler, not behind our own pcall)
        local ok_run = pcall(checkBody)
        if not ok_run then
            Update.offerReleasesPage(_("Could not check for updates."))
        end
    end)
end

-- ------------------------------------------------- reset to stable

--- Body of the reset, behind pcall from the caller (see
-- Update._resetFetchStable): fetch the release list, take the first
-- stable one (GitHub returns them newest first) and install it even
-- when it is OLDER than a beta install - Update.check only ever
-- offers newer versions, so a beta tester would have no way back.
local function resetBody()
    local releases = Update.httpGetJSON(RELEASES_URL)
    if type(releases) ~= "table" or #releases == 0 then
        Update.offerReleasesPage(_("Could not fetch latest release."))
        return
    end
    changelogSeed(releases)
    local stable
    for __, rel in ipairs(releases) do
        if type(rel) == "table" and not rel.draft and not rel.prerelease then
            stable = rel
            break
        end
    end
    if not stable then
        Update.offerReleasesPage(_("Could not fetch latest release."))
        return
    end
    local version = releaseTag(stable)
    local installed = Update.getInstalledVersion()
    if version == installed then
        UIManager:show(InfoMessage:new{
            text = T(_("Tomedown is up to date. Current version: %1"),
                "v" .. installed),
            timeout = 3,
        })
        return
    end
    local zip = releaseZip(stable)
    if not zip then
        Update.offerReleasesPage(_("Latest release has no downloadable zip."))
        return
    end
    -- the point of the reset is to be on stable: drop the beta channel
    -- so this release is not re-offered by the next check (the round
    -- and round bookshelf's updater documents)
    local settings = G_reader_settings:readSetting("tomedown", {})
    if type(settings) == "table" and settings.beta_releases then
        settings.beta_releases = false
        G_reader_settings:saveSetting("tomedown", settings)
    end
    Update.clearAvailableCache()
    Update.install(zip, version)
end

--- Fetch step of the reset, kept separate from the confirmation so
-- the Wi-Fi gate can retry it without asking the user again.
function Update._resetFetchStable()
    if Update.gateOnConnection(function()
        Update._resetFetchStable()
    end) then
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("Checking for updates…"),
        timeout = 1,
    })
    UIManager:scheduleIn(0.1, function()
        local ok_run = pcall(resetBody)
        if not ok_run then
            Update.offerReleasesPage(_("Could not fetch latest release."))
        end
    end)
end

--- "Reset to latest stable release" from Settings: confirm first (it
-- overwrites this install), then fetch and install the newest stable.
function Update.resetToStable()
    UIManager:show(ConfirmBox:new{
        text = _("This will install the latest stable release of Tomedown, then restart KOReader. Continue?"),
        ok_text = _("Reset"),
        ok_callback = function()
            Update._resetFetchStable()
        end,
    })
end

--- "Download failed." without the trailing dot, plus the reason in
-- parentheses, so the message stays a stable msgid for the .po.
local function withReason(label, reason)
    if not reason then
        return label
    end
    return (tostring(label):gsub("%.%s*$", "")) .. " (" .. tostring(reason) .. ")"
end

--- GET url and write the body to path, or nil, reason.
-- LuaSocket first, curl as a fallback (mirrors httpGetJSON). Test seam:
-- tests replace Update.httpDownload with a fake and never hit the net.
function Update.httpDownload(url, path)
    local ok_require, http, ltn12, socket, socketutil =
        pcall(function()
            return require("socket/http"),
                   require("ltn12"),
                   require("socket"),
                   require("socketutil")
        end)
    local downloaded, reason = false, nil
    if ok_require then
        pcall(os.remove, path .. ".tmp")
        local file = io.open(path .. ".tmp", "wb")
        if file then
            local ok_req, code, headers, status = pcall(function()
                socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, 300)
                local sink = socketutil.file_sink
                    and socketutil.file_sink(file)
                    or ltn12.sink.file(file)
                local c, h, st = socket.skip(1, http.request{
                    url = url,
                    method = "GET",
                    headers = {
                        ["User-Agent"] = "KOReader-Tomedown/"
                            .. Update.getInstalledVersion(),
                        ["Accept"] = "application/zip, application/octet-stream, */*",
                    },
                    sink = sink,
                    redirect = true,
                })
                socketutil:reset_timeout()
                return c, h, st
            end)
            -- socketutil.file_sink closes the handle itself (on completion
            -- or sink timeout), so a bare file:close() can raise "attempt
            -- to use a closed file" and take the whole reader down
            pcall(file.close, file)
            if not ok_req then
                pcall(function()
                    socketutil:reset_timeout()
                end)
                reason = _("the connection failed")
            elseif code == socketutil.TIMEOUT_CODE
                    or code == socketutil.SINK_TIMEOUT_CODE then
                reason = _("the connection timed out")
            elseif code == socketutil.SSL_HANDSHAKE_CODE then
                reason = _("the secure connection failed")
            elseif not headers then
                reason = _("there was no response")
            elseif tonumber(code) ~= 200 then
                reason = status or ("HTTP " .. tostring(code))
            else
                downloaded = true
            end
            if downloaded and not os.rename(path .. ".tmp", path) then
                -- same directory, so this only fails on a full/read-only disk
                downloaded = false
                reason = _("the file could not be saved")
            end
            if not downloaded then
                pcall(os.remove, path .. ".tmp")
            end
        else
            reason = _("the file could not be saved")
        end
    end
    if not downloaded then
        local ret = os.execute(string.format("curl -sfL -o %q %q", path, url))
        downloaded = ret == 0 or ret == true
        if not downloaded then
            pcall(os.remove, path)
            if not reason then
                reason = _("the connection failed")
            end
        end
    end
    if downloaded then
        return true
    end
    return false, reason
end

--- Unpack zip over dest, stripping the zip's single top-level folder
-- (tomedown.koplugin/…) so files land inside the installed plugin dir.
local function unpackStripRoot(zip_path, dest)
    local ok_req, Archiver = pcall(require, "ffi/archiver")
    if not (ok_req and Archiver and Archiver.Reader) then
        return false, "archive extractor unavailable"
    end
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then
        local err = arc.err
        arc:close()
        return false, err or "could not open archive"
    end
    local extract_err
    local extracted = 0
    for entry in arc:iterate() do
        local rel = entry.path and entry.path:match("^[^/]+/(.+)$")
        if rel and rel ~= "" then
            if not arc:extractToPath(entry.path, dest .. "/" .. rel) then
                extract_err = arc.err or "extract failed"
                break
            end
            extracted = extracted + 1
        end
    end
    arc:close()
    if extract_err then
        return false, extract_err
    end
    if extracted == 0 then
        return false, "empty archive"
    end
    return true
end
Update._unpackStripRoot = unpackStripRoot

--- Restart KOReader (seam: tests override Update.restartKOReader).
function Update.restartKOReader()
    UIManager:restartKOReader()
end

--- Body of the scheduled install step, kept separate so the caller can
-- run it behind pcall (see Update.install).
local function installBody(zip_url, new_version)
    local dest = pluginDir()
    if not dest then
        UIManager:show(InfoMessage:new{
            text = T(_("Installation failed: %1"), "unknown plugin folder"),
            timeout = 5,
        })
        return
    end
    local lfs = require("libs/libkoreader-lfs")
    local cache_dir = require("datastorage"):getSettingsDir()
        .. "/tomedown_cache"
    if lfs.attributes(cache_dir, "mode") ~= "directory" then
        lfs.mkdir(cache_dir)
    end
    local zip_path = cache_dir .. "/tomedown.koplugin.zip"
    local ok_dl, reason = Update.httpDownload(zip_url, zip_path)
    if not ok_dl then
        pcall(os.remove, zip_path)
        Update.offerReleasesPage(withReason(_("Download failed."), reason))
        return
    end
    local ok, err = Update._unpackStripRoot(zip_path, dest)
    pcall(os.remove, zip_path)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Installation failed: %1"), tostring(err)),
            timeout = 5,
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Tomedown updated to v%1."), new_version)
            .. "\n\n" .. _("Restart KOReader now?"),
        ok_text = _("Restart"),
        ok_callback = function()
            Update.restartKOReader()
        end,
    })
end

--- Install the release zip: gate, download into a cache dir, unpack it
-- over this plugin's own folder, then ask to restart KOReader. Any
-- failure falls back to the releases page (manual zip) or an error
-- message - the old version keeps running either way.
function Update.install(zip_url, new_version)
    if Update.gateOnConnection(function()
        Update.install(zip_url, new_version)
    end) then
        return
    end
    UIManager:show(InfoMessage:new{
        text = _("Downloading update…"),
        timeout = 1,
    })
    UIManager:scheduleIn(0.1, function()
        -- safety net: an unexpected error inside a scheduled action
        -- propagates to the top level and kills the whole reader, so
        -- everything here runs behind pcall and reports instead
        local ok_run, run_err = pcall(installBody, zip_url, new_version)
        if not ok_run then
            UIManager:show(InfoMessage:new{
                text = T(_("Installation failed: %1"), tostring(run_err)),
                timeout = 5,
            })
        end
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
        -- safety net, silent: the background check must never take the
        -- reader down for a transient error
        pcall(function()
            local installed = Update.getInstalledVersion()
            local releases = Update.httpGetJSON(RELEASES_URL)
            if type(releases) ~= "table" then
                return
            end
            changelogSeed(releases)
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
    end)
end

-- test hook: forget the session-only state
function Update._resetState()
    installed_version = nil
    cached_version = nil
    last_bg_check = nil
    bg_in_flight = false
end

--- Forget the cached "newer version" and the background throttle, so a
-- Settings change (the Beta Releases toggle) is picked up by the next
-- check instead of up to an hour later. The changelog cache goes with
-- them: its content depends on the same toggle.
function Update.clearAvailableCache()
    cached_version = nil
    last_bg_check = nil
    if G_reader_settings then
        G_reader_settings:saveSetting(CHANGELOG_KEY, nil)
    end
end

return Update
