--[[--
Get Plugins - install KOReader plugins received through a leaf-casa relay.

Pairs with a leaf-casa instance (https://leaf.casa or self-hosted). The relay
queues files uploaded from a phone or desktop. Files flagged as plugins
(`target == "plugin"` / `.koplugin` / `.zip`) are downloaded and extracted into
`<koreader-data>/plugins/`, which KOReader already scans as a user plugin path.

@module koplugin.getplugins
--]]--

local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/getplugins.lua"
local CACHE_DIR = DataStorage:getDataDir() .. "/cache/getplugins"
local MAX_REDIRECTS = 3

-- Auto-sync cadence
local POLL_ACTIVE_SECONDS = 45
local POLL_BACKOFF_SECONDS = 300
local POLL_EMPTY_BACKOFF_AFTER = 3
local POLL_OFFLINE_RETRY_SECONDS = 60
local POLL_STARTUP_DELAY_SECONDS = 10
local POLL_RESUME_DELAY_SECONDS = 2

-- Only one plugin instance should own the background timer (FileManager vs Reader).
local active_poller = nil

local GetPlugins = WidgetContainer:extend{
    name = "getplugins",
    is_doc_only = false,
}

-- Helpers ------------------------------------------------------------------

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalizeServer(input)
    local server = trim(input)
    if server == "" then
        return nil
    end
    if not server:match("^https?://") then
        server = "https://" .. server
    end
    return (server:gsub("/+$", ""))
end

local function normalizeKey(input)
    return (tostring(input or ""):upper():gsub("[^A-Z0-9]", ""):sub(1, 4))
end

local function sanitizePluginName(name)
    name = tostring(name or "plugin")
    name = name:gsub("\\", "/")
    name = name:match("([^/]+)$") or name
    name = name:gsub("%.koplugin$", ""):gsub("%.zip$", "")
    name = name:gsub("[^%w%-%._ ]", "_")
    name = name:gsub("^%.+", "")
    name = trim(name:gsub("%s+", " "))
    if name == "" then
        name = "plugin"
    end
    return name
end

local function pluginDirName(name)
    name = sanitizePluginName(name)
    if name:sub(-9) == ".koplugin" then
        return name
    end
    return name .. ".koplugin"
end

local function isPluginFile(file)
    if file.target == "plugin" then
        return true
    end
    local format = tostring(file.format or ""):lower()
    return format == ".koplugin" or format == ".zip"
end

--- Splits a path into safe, normalized segments.
-- Returns nil for absolute paths, drive letters, or any `..` component.
local function pathSegments(path)
    local normalized = tostring(path or ""):gsub("\\", "/")
    if normalized == "" or normalized:sub(1, 1) == "/" or normalized:match("^%a:/") then
        return nil
    end
    local segments = {}
    for segment in normalized:gmatch("[^/]+") do
        if segment == ".." then
            return nil
        end
        if segment ~= "." and segment ~= "" then
            segments[#segments + 1] = segment
        end
    end
    if #segments == 0 then
        return nil
    end
    return segments
end

local function isMetadataNoise(segments, relative)
    return segments[1] == "__MACOSX"
        or relative == ".DS_Store"
        or relative:sub(-10) == "/.DS_Store"
end

-- Networking ---------------------------------------------------------------

function GetPlugins:httpGetToTable(url, block_timeout, total_timeout)
    local redirects = 0
    while true do
        local chunks = {}
        socketutil:set_timeout(
            block_timeout or socketutil.DEFAULT_BLOCK_TIMEOUT,
            total_timeout or 20
        )
        local code, headers, status = socket.skip(1, http.request{
            url = url,
            method = "GET",
            sink = socketutil.table_sink(chunks),
            headers = {
                ["Accept"] = "application/json",
                ["User-Agent"] = socketutil.USER_AGENT,
            },
        })
        socketutil:reset_timeout()

        if type(code) == "number" and code >= 300 and code < 400 and headers and headers.location then
            redirects = redirects + 1
            if redirects > MAX_REDIRECTS then
                return nil, _("Too many redirects.")
            end
            local next_url = socket_url.absolute(url, headers.location)
            if not next_url then
                return nil, _("Invalid redirect location.")
            end
            url = next_url
        elseif code == 200 then
            local data, err = rapidjson.decode(table.concat(chunks))
            if not data then
                logger.warn("GetPlugins: invalid JSON:", err)
                return nil, err or _("Invalid JSON response.")
            end
            return data
        else
            return nil, status or T(_("HTTP %1"), tostring(code))
        end
    end
end

function GetPlugins:httpGetToFile(url, filepath, block_timeout, total_timeout)
    local redirects = 0
    while true do
        local file, open_err = io.open(filepath, "wb")
        if not file then
            return nil, open_err or _("Could not open the temporary file.")
        end

        socketutil:set_timeout(
            block_timeout or socketutil.FILE_BLOCK_TIMEOUT,
            total_timeout or 300
        )

        local code, headers, status = socket.skip(1, http.request{
            url = url,
            method = "GET",
            sink = socketutil.file_sink(file),
            headers = {
                ["User-Agent"] = socketutil.USER_AGENT,
            },
        })
        socketutil:reset_timeout()

        if type(code) == "number" and code >= 300 and code < 400 and headers and headers.location then
            redirects = redirects + 1
            os.remove(filepath)
            if redirects > MAX_REDIRECTS then
                return nil, _("Too many redirects.")
            end
            local next_url = socket_url.absolute(url, headers.location)
            if not next_url then
                return nil, _("Invalid redirect location.")
            end
            url = next_url
        elseif code == 200 then
            local size = lfs.attributes(filepath, "size")
            if not size or size == 0 then
                os.remove(filepath)
                return nil, _("Downloaded file is empty.")
            end
            local expected = headers and tonumber(headers["content-length"])
            if expected and size ~= expected then
                os.remove(filepath)
                return nil, T(_("Incomplete download (%1 of %2 bytes)."), size, expected)
            end
            return true
        else
            os.remove(filepath)
            return nil, status or T(_("HTTP %1"), tostring(code))
        end
    end
end

-- Archive installation -----------------------------------------------------

--- Extracts a plugin archive into `plugins_dir`.
-- Supports archives that already contain `*.koplugin/` folders, archives whose
-- root is the plugin itself, and archives with a single top-level plugin folder.
-- @return installed folder name, or nil + error message
function GetPlugins:installArchive(archive_path, original_name, plugins_dir)
    local arc = Archiver.Reader:new()
    if not arc:open(archive_path) then
        return nil, arc.err or _("Could not open the plugin archive.")
    end

    local file_entries = {}
    local top_info = {}
    local root_has_main, root_has_meta = false, false

    for entry in arc:iterate() do
        if entry.mode ~= "file" and entry.mode ~= "directory" then
            arc:close()
            return nil, T(_("Archive contains an unsupported entry type: %1"), entry.path)
        end

        if entry.mode == "file" then
            local segments = pathSegments(entry.path)
            if not segments then
                arc:close()
                return nil, T(_("Archive contains an unsafe path: %1"), entry.path)
            end

            local relative = table.concat(segments, "/")
            if not isMetadataNoise(segments, relative) then
                file_entries[#file_entries + 1] = {
                    key = entry.path,
                    relative = relative,
                    segments = segments,
                }

                if #segments == 1 then
                    if relative == "main.lua" then
                        root_has_main = true
                    elseif relative == "_meta.lua" then
                        root_has_meta = true
                    end
                else
                    local top = segments[1]
                    local info = top_info[top] or { has_main = false, has_meta = false }
                    local under = table.concat(segments, "/", 2)
                    if under == "main.lua" then
                        info.has_main = true
                    elseif under == "_meta.lua" then
                        info.has_meta = true
                    end
                    top_info[top] = info
                end
            end
        end
    end

    local plugin_roots = {}
    for top, info in pairs(top_info) do
        if top:sub(-9) == ".koplugin" and info.has_main and info.has_meta then
            plugin_roots[top] = true
        end
    end

    local mode
    local destination_base
    local single_top
    local installed_name

    if next(plugin_roots) ~= nil then
        mode = "roots"
        local names = {}
        for top in pairs(plugin_roots) do
            names[#names + 1] = top
        end
        table.sort(names)
        installed_name = table.concat(names, ", ")
    elseif root_has_main and root_has_meta then
        mode = "wrap"
        installed_name = pluginDirName(original_name)
        destination_base = plugins_dir .. "/" .. installed_name
    else
        local candidates = {}
        for top, info in pairs(top_info) do
            if info.has_main and info.has_meta then
                candidates[#candidates + 1] = top
            end
        end
        if #candidates ~= 1 then
            arc:close()
            return nil, _("This archive does not contain a KOReader plugin (main.lua + _meta.lua).")
        end
        mode = "single"
        single_top = candidates[1]
        installed_name = pluginDirName(single_top)
        destination_base = plugins_dir .. "/" .. installed_name
    end

    local extracted = 0
    for _, entry in ipairs(file_entries) do
        local destination
        if mode == "roots" then
            if plugin_roots[entry.segments[1]] then
                destination = plugins_dir .. "/" .. entry.relative
            end
        elseif mode == "wrap" then
            destination = destination_base .. "/" .. entry.relative
        elseif entry.segments[1] == single_top and #entry.segments > 1 then
            destination = destination_base .. "/" .. table.concat(entry.segments, "/", 2)
        end

        if destination then
            local parent = destination:match("^(.*)/[^/]*$")
            if parent then
                local ok, mkdir_err = util.makePath(parent)
                if not ok then
                    arc:close()
                    return nil, mkdir_err or T(_("Could not create folder %1"), parent)
                end
            end

            local ok, extract_err = arc:extractToPath(entry.key, destination)
            if not ok then
                arc:close()
                return nil, extract_err or T(_("Could not extract %1"), entry.relative)
            end
            extracted = extracted + 1
        end
    end

    arc:close()

    if extracted == 0 then
        return nil, _("No plugin files were extracted.")
    end

    return installed_name
end

-- Configuration ------------------------------------------------------------

function GetPlugins:loadSettings()
    if self._settings_loaded then
        return
    end
    self._settings_loaded = true
    self.settings = LuaSettings:open(SETTINGS_FILE)
    self.server = normalizeServer(self.settings:readSetting("server"))
    self.key = normalizeKey(self.settings:readSetting("key"))
    local auto_sync = self.settings:readSetting("auto_sync")
    self.auto_sync = auto_sync == nil and true or auto_sync == true
end

function GetPlugins:saveConfig(server, key)
    self:loadSettings()
    self.server = server
    self.key = key
    self.settings:saveSetting("server", server)
    self.settings:saveSetting("key", key)
    self.settings:flush()

    self.empty_polls = 0
    if self.auto_sync then
        self:schedulePoll(POLL_RESUME_DELAY_SECONDS)
    end
end

-- Auto-sync ----------------------------------------------------------------

function GetPlugins:isAutoSyncEnabled()
    self:loadSettings()
    return self.auto_sync == true
end

function GetPlugins:setAutoSync(enabled)
    self:loadSettings()
    self.auto_sync = enabled and true or false
    self.settings:saveSetting("auto_sync", self.auto_sync)
    self.settings:flush()

    self.empty_polls = 0
    if self.auto_sync then
        self:schedulePoll(1)
    else
        self:cancelPoll()
    end
end

function GetPlugins:canAutoSync()
    return self.auto_sync == true
        and not self._closed
        and not self.is_suspended
        and self.server ~= nil and self.server ~= ""
        and self.key ~= nil and #self.key == 4
end

function GetPlugins:nextPollDelay()
    if (self.empty_polls or 0) >= POLL_EMPTY_BACKOFF_AFTER then
        return POLL_BACKOFF_SECONDS
    end
    return POLL_ACTIVE_SECONDS
end

function GetPlugins:cancelPoll()
    if self._poll_fn then
        UIManager:unschedule(self._poll_fn)
        self._poll_fn = nil
    end
    if active_poller == self then
        active_poller = nil
    end
end

function GetPlugins:schedulePoll(delay)
    if not self:canAutoSync() then
        self:cancelPoll()
        return
    end

    self:cancelPoll()
    active_poller = self

    local action
    action = function()
        self._poll_fn = nil
        self:runPoll()
    end
    self._poll_fn = action
    UIManager:scheduleIn(delay or self:nextPollDelay(), action)
end

function GetPlugins:runPoll()
    if not self:canAutoSync() then
        return
    end

    if not NetworkMgr:isOnline() then
        self:schedulePoll(POLL_OFFLINE_RETRY_SECONDS)
        return
    end

    -- Blocking request; reschedule only after it returns so a slow poll
    -- cannot queue up overlapping requests.
    self:pollOnce()
    self:schedulePoll(self:nextPollDelay())
end

function GetPlugins:statusUrl()
    return string.format("%s/api/status/%s?t=%d", self.server, self.key, os.time())
end

function GetPlugins:collectPending(status)
    local pending = {}
    for _, file in ipairs(status.files or {}) do
        if not file.downloaded and isPluginFile(file) then
            pending[#pending + 1] = file
        end
    end
    return pending
end

function GetPlugins:prepareDirs()
    local plugins_dir = DataStorage:getDataDir() .. "/plugins"

    local ok, err = util.makePath(CACHE_DIR)
    if not ok then
        return nil, T(_("Could not create the download cache:\n%1"), err or CACHE_DIR)
    end

    ok, err = util.makePath(plugins_dir)
    if not ok then
        return nil, T(_("Could not create the plugins folder:\n%1"), err or plugins_dir)
    end

    return plugins_dir
end

function GetPlugins:downloadAndInstallFile(file, plugins_dir, background)
    local filename = file.filename or "plugin.koplugin"
    local temp_path = string.format(
        "%s/%s-%s",
        CACHE_DIR,
        tostring(file.id or ""),
        sanitizePluginName(filename)
    )
    local download_url = string.format(
        "%s/api/download/%s/%s/%s",
        self.server,
        self.key,
        util.urlEncode(tostring(file.id or "")),
        util.urlEncode(filename)
    )

    local block_timeout = background and 5 or socketutil.FILE_BLOCK_TIMEOUT
    local total_timeout = background and 60 or 300

    local downloaded, download_err = self:httpGetToFile(
        download_url,
        temp_path,
        block_timeout,
        total_timeout
    )

    local installed_name
    if downloaded then
        local ok, result, install_err = pcall(
            self.installArchive,
            self,
            temp_path,
            filename,
            plugins_dir
        )
        if ok then
            installed_name = result
            download_err = install_err
        else
            installed_name = nil
            download_err = tostring(result)
        end
    end
    os.remove(temp_path)

    return installed_name, download_err
end

function GetPlugins:showInstallSummary(installed, failed)
    local lines = {}
    if #installed > 0 then
        lines[#lines + 1] = T(_("Installed:\n%1"), table.concat(installed, "\n"))
    end
    if #failed > 0 then
        lines[#lines + 1] = T(_("Failed:\n%1"), table.concat(failed, "\n"))
    end
    if #lines == 0 then
        return
    end

    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n\n"),
        timeout = #failed > 0 and 10 or 5,
    })

    if #installed > 0 then
        self:promptRestart()
    end
end

function GetPlugins:promptRestart()
    if self.restart_prompted then
        return
    end
    self.restart_prompted = true
    UIManager:askForRestart(_("Restart KOReader to load the newly installed plugin(s)."))
end

--- Background check: silent when empty, installs only plugin files.
function GetPlugins:pollOnce()
    if self.is_syncing then
        return
    end
    self.is_syncing = true

    local pok, status = pcall(self.httpGetToTable, self, self:statusUrl(), 5, 10)
    if not pok or not status then
        if not pok then
            logger.warn("GetPlugins: poll failed:", status)
        end
        self.empty_polls = (self.empty_polls or 0) + 1
        self.is_syncing = false
        return
    end

    local pending = self:collectPending(status)
    if #pending == 0 then
        self.empty_polls = (self.empty_polls or 0) + 1
        self.is_syncing = false
        return
    end

    local plugins_dir, dir_err = self:prepareDirs()
    if not plugins_dir then
        logger.warn("GetPlugins: cannot prepare directories:", dir_err)
        self.empty_polls = 0
        self.is_syncing = false
        return
    end

    self.empty_polls = 0
    local installed, failed = {}, {}
    for _, file in ipairs(pending) do
        local installed_name, install_err = self:downloadAndInstallFile(file, plugins_dir, true)
        if installed_name then
            installed[#installed + 1] = installed_name
        else
            failed[#failed + 1] = string.format(
                "%s: %s",
                file.filename or "plugin",
                install_err or _("unknown error")
            )
        end
    end

    self.is_syncing = false
    self:showInstallSummary(installed, failed)
end

-- UI -----------------------------------------------------------------------

function GetPlugins:showSetupDialog()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("leaf-casa plugin sync"),
        fields = {
            {
                description = _("Relay server (leaf.casa or your own instance)"),
                text = self.server or "",
                hint = "https://leaf.casa",
            },
            {
                description = _("4-character pairing code shown on the sender page"),
                text = self.key or "",
                hint = "ABCD",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Sync now"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local server = normalizeServer(fields[1])
                        local key = normalizeKey(fields[2])

                        if not server then
                            UIManager:show(InfoMessage:new{
                                text = _("Enter the relay server URL."),
                            })
                            return
                        end
                        if #key ~= 4 then
                            UIManager:show(InfoMessage:new{
                                text = _("Enter the 4-character pairing code."),
                            })
                            return
                        end

                        UIManager:close(dialog)
                        self:saveConfig(server, key)
                        self:startSync()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function GetPlugins:startSync()
    self:loadSettings()

    if not self.server or self.server == "" or not self.key or self.key == "" then
        self:showSetupDialog()
        return
    end

    self.server = normalizeServer(self.server) or self.server
    self.key = normalizeKey(self.key)
    if #self.key ~= 4 then
        UIManager:show(InfoMessage:new{
            text = _("The saved pairing code is invalid. Please set it again."),
        })
        self:showSetupDialog()
        return
    end

    if NetworkMgr:willRerunWhenOnline(function()
        self:startSync()
    end) then
        return
    end

    self:doSync()
end

function GetPlugins:doSync()
    -- Manual sync: temporarily stop background polling, then resume.
    self:cancelPoll()
    if self.is_syncing then
        return
    end
    self.is_syncing = true

    local progress = InfoMessage:new{
        text = _("Contacting the leaf-casa relay…"),
    }
    UIManager:show(progress)
    UIManager:forceRePaint()

    local status, status_err = self:httpGetToTable(
        self:statusUrl(),
        socketutil.DEFAULT_BLOCK_TIMEOUT,
        20
    )

    UIManager:close(progress)

    if not status then
        self.is_syncing = false
        local message = status_err or _("Unknown error")
        if message:find("404", 1, true) then
            message = _("The pairing code expired or does not exist.\nOpen the leaf-casa receiver page on your e-reader to get a fresh code.")
        end
        UIManager:show(InfoMessage:new{
            text = T(_("Could not reach %1.\n\n%2"), self.server, message),
        })
        self:schedulePoll()
        return
    end

    local pending = self:collectPending(status)
    if #pending == 0 then
        self.is_syncing = false
        self.empty_polls = 0
        UIManager:show(InfoMessage:new{
            text = _("No new plugin files are waiting for this pairing code.\n(Book files in the queue are ignored by this plugin.)"),
        })
        self:schedulePoll()
        return
    end

    local plugins_dir, dir_err = self:prepareDirs()
    if not plugins_dir then
        self.is_syncing = false
        UIManager:show(InfoMessage:new{
            text = dir_err,
        })
        self:schedulePoll()
        return
    end

    local installed, failed = {}, {}
    for index, file in ipairs(pending) do
        local filename = file.filename or "plugin.koplugin"
        local download_progress = InfoMessage:new{
            text = T(_("Downloading %1 (%2/%3)…"), filename, index, #pending),
        }
        UIManager:show(download_progress)
        UIManager:forceRePaint()

        local installed_name, install_err = self:downloadAndInstallFile(file, plugins_dir, false)
        UIManager:close(download_progress)

        if installed_name then
            installed[#installed + 1] = installed_name
        else
            failed[#failed + 1] = string.format("%s: %s", filename, install_err or _("unknown error"))
        end
    end

    self.is_syncing = false
    self.empty_polls = 0
    self:showInstallSummary(installed, failed)
    self:schedulePoll()
end

function GetPlugins:addToMainMenu(menu_items)
    menu_items.getplugins = {
        text = _("Get KOReader plugins"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Set up or change pairing…"),
                callback = function()
                    self:loadSettings()
                    self:showSetupDialog()
                end,
            },
            {
                text = _("Sync plugins now"),
                enabled_func = function()
                    self:loadSettings()
                    return self.server ~= nil and self.server ~= ""
                        and self.key ~= nil and self.key ~= ""
                end,
                callback = function()
                    self:startSync()
                end,
            },
            {
                text = _("Auto-sync while awake on Wi-Fi"),
                checked_func = function()
                    return self:isAutoSyncEnabled()
                end,
                callback = function(touchmenu_instance)
                    self:setAutoSync(not self:isAutoSyncEnabled())
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        },
    }
end

-- Lifecycle / events -------------------------------------------------------

function GetPlugins:init()
    self:loadSettings()
    self.is_suspended = false
    self.is_syncing = false
    self._closed = false
    self.empty_polls = 0
    self.restart_prompted = false

    if self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Take over from a previous UI instance's timer, if any.
    if active_poller and active_poller ~= self then
        active_poller:cancelPoll()
    end
    if self:canAutoSync() then
        self:schedulePoll(POLL_STARTUP_DELAY_SECONDS)
    end
end

function GetPlugins:onSuspend()
    self.is_suspended = true
    self:cancelPoll()
end

function GetPlugins:onResume()
    self.is_suspended = false
    self.empty_polls = 0
    self:schedulePoll(POLL_RESUME_DELAY_SECONDS)
end

function GetPlugins:onNetworkConnected()
    self.empty_polls = 0
    self:schedulePoll(POLL_RESUME_DELAY_SECONDS)
end

function GetPlugins:onNetworkDisconnected()
    self:cancelPoll()
end

function GetPlugins:onCloseWidget()
    self._closed = true
    self:cancelPoll()
end

return GetPlugins
