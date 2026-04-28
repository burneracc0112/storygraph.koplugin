local _ = require("gettext")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local logger = require("logger")
local math = require("math")

local NetworkManager = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")

local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")

local WidgetContainer = require("ui/widget/container/widgetcontainer")

local _t = require("hardcover/lib/table_util")
local Api = require("hardcover/lib/hardcover_api")
local AutoWifi = require("hardcover/lib/auto_wifi")
local Cache = require("hardcover/lib/cache")
local debounce = require("hardcover/lib/debounce")
local Hardcover = require("hardcover/lib/hardcover")
local HardcoverSettings = require("hardcover/lib/hardcover_settings")
local PageMapper = require("hardcover/lib/page_mapper")
local Scheduler = require("hardcover/lib/scheduler")
local throttle = require("hardcover/lib/throttle")
local User = require("hardcover/lib/user")

local DialogManager = require("hardcover/lib/ui/dialog_manager")
local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SETTING = require("hardcover/lib/constants/settings")

local HardcoverApp = WidgetContainer:extend {
  name = "storygraph",
  is_doc_only = false,
  state = nil,
  settings = nil,
  width = nil,
  enabled = true
}

local HIGHLIGHT_MENU_NAME = "13_0_make_storygraph_highlight_item"

function HardcoverApp:onDispatcherRegisterActions()
  Dispatcher:registerAction("storygraph_link", {
    category = "none",
    event = "StoryGraphLink",
    title = _("StoryGraph: Link book"),
    general = true,
  })

  Dispatcher:registerAction("storygraph_track", {
    category = "none",
    event = "StoryGraphTrack",
    title = _("StoryGraph: Track progress"),
    general = true,
  })

  Dispatcher:registerAction("storygraph_stop_track", {
    category = "none",
    event = "StoryGraphStopTrack",
    title = _("StoryGraph: Stop tracking progress"),
    general = true,
  })

  Dispatcher:registerAction("storygraph_update_progress", {
    category = "none",
    event = "StoryGraphUpdateProgress",
    title = _("StoryGraph: Update progress"),
    general = true,
  })


end

function HardcoverApp:init()
  self.state = {
    page = nil,
    pos = nil,
    search_results = {},
    book_status = {},
    page_update_pending = false
  }
  --logger.warn("HARDCOVER app init")
  self.settings = HardcoverSettings:new(
    ("%s/%s"):format(DataStorage:getSettingsDir(), "storygraphsync_settings.lua"),
    self.ui
  )
  self.settings:subscribe(function(field, change, original_value) self:onSettingsChanged(field, change, original_value) end)

  User.settings = self.settings
  Api.settings = self.settings
  Api.on_error = function(err)
    if not err or not self.enabled then
      return
    end

    if err == "Unauthorized" or (err.message and string.find(err.message, "login")) then
      self:disable()
      UIManager:show(InfoMessage:new {
        text = "Your StoryGraph session cookie is not valid or has expired. Please update it.",
        icon = "notice-warning",
      })
    end
  end

  self.cache = Cache:new {
    settings = self.settings,
    state = self.state,
    ui = self.ui
  }
  self.page_mapper = PageMapper:new {
    state = self.state,
    ui = self.ui,
  }
  self.wifi = AutoWifi:new {
    settings = self.settings
  }
  self.dialog_manager = DialogManager:new {
    page_mapper = self.page_mapper,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
    wifi = self.wifi
  }
  self.hardcover = Hardcover:new {
    cache = self.cache,
    dialog_manager = self.dialog_manager,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
    wifi = self.wifi
  }

  self.menu = HardcoverMenu:new {
    app = self,
    enabled = true,

    cache = self.cache,
    dialog_manager = self.dialog_manager,
    hardcover = self.hardcover,
    page_mapper = self.page_mapper,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
  }

  self:onDispatcherRegisterActions()
  self:initializePageUpdate()
  self.ui.menu:registerToMainMenu(self)
end

function HardcoverApp:_bookSettingChanged(setting, key)
  return setting[key] ~= nil or _t.contains(_t.dig(setting, "_delete"), key)
end

-- Open note dialog
--
-- UIManager:broadcastEvent(Event:new("HardcoverNote", note_params))
--
-- note_params can contain:
--   text: Value will prepopulate the note section
--   page_number: The local page number
--   remote_page (optional): The mapped page in the linked book edition
--   note_type: one of "quote" or "note"
function HardcoverApp:onStoryGraphNote(note_params)
  if not self:isActive() then return end
  -- Fetch latest progress from API for quotes/notes
  local book_id = self.settings:getLinkedBookId()
  local remote_percent = self.state.book_status.last_reached_percent or 0
  
  if book_id then
    self.wifi:wifiPrompt(function()
      local latest_status = Api:findUserBook(book_id, User:getId())
      if latest_status and latest_status.last_reached_percent then
        remote_percent = latest_status.last_reached_percent
        self.state.book_status = latest_status
      end
      
      self.dialog_manager:journalEntryForm(
        note_params.text,
        self.ui.document,
        note_params.page_number,
        self.settings:pages(),
        note_params.remote_page or nil,
        remote_percent,
        note_params.note_type or "quote"
      )
    end)
    return
  end

  -- Fallback if no book linked
  self.dialog_manager:journalEntryForm(
    note_params.text,
    self.ui.document,
    note_params.page_number,
    self.settings:pages(),
    note_params.remote_page or nil,
    remote_percent,
    note_params.note_type or "quote"
  )
end

function HardcoverApp:disable()
  self.enabled = false
  if self.menu then
    self.menu.enabled = false
  end
  self:registerHighlight()
end

function HardcoverApp:onStoryGraphLink()
  self.hardcover:showLinkBookDialog(false, function(book)
    UIManager:show(Notification:new {
      text = _("Linked to: " .. book.title),
    })
  end)
end

function HardcoverApp:onStoryGraphTrack()
  self.settings:setSync(true)
  UIManager:nextTick(function()
    UIManager:show(Notification:new {
      text = _("Progress tracking enabled")
    })
  end)
end

function HardcoverApp:onStoryGraphStopTrack()
  self.settings:setSync(false)
  UIManager:show(Notification:new {
    text = _("Progress tracking disabled")
  })
end

function HardcoverApp:onStoryGraphPullPosition()
  if not self.ui.document or not self.settings:bookLinked() then return end

  local ConfirmBox = require("ui/widget/confirmbox")
  local book_id = self.settings:getLinkedBookId()

  UIManager:show(Notification:new {
    text = _("Fetching position from StoryGraph..."),
    timeout = 3,
  })

  self.wifi:withWifi(function()
    local status = Api:findUserBook(book_id, User:getId())
    if not status or not status.last_reached_percent then
      UIManager:show(InfoMessage:new {
        text = _("Could not fetch position from StoryGraph."),
        icon = "notice-warning",
      })
      return
    end

    local remote_percent = tonumber(status.last_reached_percent) or 0
    if remote_percent == 0 then
      UIManager:show(InfoMessage:new {
        text = _("StoryGraph shows no progress recorded yet."),
      })
      return
    end

    local document_pages = self.ui.document:getPageCount()
    local target_page = math.max(1, math.floor((remote_percent / 100) * document_pages))

    UIManager:show(ConfirmBox:new {
      text = _(string.format(
        "StoryGraph shows %d%% progress.\nJump to page %d of %d?",
        remote_percent, target_page, document_pages
      )),
      ok_text = _("Jump"),
      ok_callback = function()
        self.ui:handleEvent(Event:new("GotoPage", target_page))
        -- Update cached status
        self.state.book_status = status
      end,
    })
  end)
end

function HardcoverApp:onStoryGraphUpdateProgress()
  if self.ui.document and self.settings:bookLinked() then
    self:updatePageNow(function(result)
      if result then
        UIManager:show(Notification:new {
          text = _("Progress updated")
        })
      else
        logger.warn("Unsuccessful updating page progress", self.ui.document.file)
      end
    end)
  else
    logger.warn(self.state.book_status)
    local error
    if not self.ui.document then
      error = "No book active"
    elseif not self.state.book_status.id then
      error = "Book has not been mapped"
    end

    local error_message = error and "Unable to update reading progress: " .. error or "Unable to update reading progress"
    UIManager:show(InfoMessage:new {
      text = error_message,
      icon = "notice-warning",
    })
  end
end

function HardcoverApp:onSettingsChanged(field, change, original_value)
  if field == SETTING.BOOKS then
    local book_settings = change.config
    if self:_bookSettingChanged(book_settings, "sync") then
      if book_settings.sync then
        if not self.state.book_status.id then
          self:startReadCache()
        end
      else
        self:cancelPendingUpdates()
      end
    end

    if self:_bookSettingChanged(book_settings, "book_id") then
      self:registerHighlight()
    end
  elseif field == SETTING.TRACK_METHOD then
    self:cancelPendingUpdates()
    self:initializePageUpdate()
  elseif field == SETTING.LINK_BY_ISBN or field == SETTING.LINK_BY_TITLE then
    if change then
      self.hardcover:tryAutolink()
    end
  end
end

function HardcoverApp:_handlePageUpdate(filename, value, immediate, callback, update_type)
  update_type = update_type or "percentage"
  --logger.warn("HARDCOVER: Throttled progress update", value, update_type)
  self.page_update_pending = false

  if not self:syncFileUpdates(filename) then
    return
  end

  if self.state.book_status.status_id ~= HARDCOVER.STATUS.READING then
    return
  end

  -- Don't push progress if local is behind remote (prevents accidental downgrade)
  -- Configurable via Settings > "Skip update if behind remote"
  local skip_behind = self.settings:readSetting(SETTING.SKIP_BEHIND_PROGRESS) ~= false
  if skip_behind and update_type == "percentage" then
    local remote_percent = tonumber(self.state.book_status.percent_finished) or 0
    if not immediate and value < remote_percent then
      logger.info("StoryGraph: Local progress (" .. value .. "%) is behind remote (" .. remote_percent .. "%). Skipping update.")
      return
    end
  elseif skip_behind and update_type == "pages" then
    local remote_page = tonumber(self.state.book_status.last_reached_pages) or 0
    if not immediate and value < remote_page then
      logger.info("StoryGraph: Local progress (" .. value .. " pages) is behind remote (" .. remote_page .. " pages). Skipping update.")
      return
    end
  end

  local reads = self.state.book_status.user_book_reads
  local current_read = reads and reads[#reads]
  if not current_read then
    return
  end

  local immediate_update = function()
    self.wifi:withWifi(function()
      local result = Api:updatePage(current_read.id, current_read.edition_id, value, current_read.started_at, update_type)
      if result then
        self.state.book_status = result
        self:registerHighlight()
      end
      if callback then
        callback(result)
      end
    end)
  end

  local trapped_update = function()
    Trapper:wrap(immediate_update)
  end

  if immediate then
    immediate_update()
  else
    UIManager:scheduleIn(1, trapped_update)
  end
end

function HardcoverApp:initializePageUpdate()
  local track_frequency = math.max(math.min(self.settings:trackFrequency(), 120), 1) * 60

  HardcoverApp._throttledHandlePageUpdate, HardcoverApp._cancelPageUpdate = throttle(
    track_frequency,
    HardcoverApp._handlePageUpdate
  )

  HardcoverApp.onPageUpdate, HardcoverApp._cancelPageUpdateEvent = debounce(2, HardcoverApp.pageUpdateEvent)
end

function HardcoverApp:pageUpdateEvent(page)
  self.state.last_page = self.state.page
  self.state.page = page

  if not (self.state.book_status.id and self.settings:syncEnabled()) then
    return
  end
  --logger.warn("HARDCOVER page update event pending")
  local document_pages = self.ui.document:getPageCount()
  local remote_pages = self.settings:pages()

  if self.settings:trackByTime() then
    local decimal_percent, mapped_page = self.page_mapper:getRemotePagePercent(
      self.state.page,
      self.ui.document:getPageCount(),
      self.settings:pages()
    )
    local value, update_type
    if self.settings:syncByRemotePages() and mapped_page then
      value = mapped_page
      update_type = "pages"
    else
      value = math.floor(decimal_percent * 100 + 0.5)
      update_type = "percentage"
    end

    self:_throttledHandlePageUpdate(self.ui.document.file, value, false, nil, update_type)
    self.page_update_pending = true
  elseif (self.settings:trackByProgress() or self.settings:trackByPages()) and self.state.last_page then
    local previous_percent, previous_mapped_page = self.page_mapper:getRemotePagePercent(
      self.state.last_page,
      document_pages,
      remote_pages
    )

    local current_percent, current_mapped_page = self.page_mapper:getRemotePagePercent(
      self.state.page,
      document_pages,
      remote_pages
    )

    local should_sync = false
    if self.settings:trackByProgress() then
      local percent_interval = self.settings:trackPercentageInterval()
      local last_compare = math.floor(previous_percent * 100 / percent_interval)
      local current_compare = math.floor(current_percent * 100 / percent_interval)
      should_sync = (last_compare ~= current_compare)
    elseif self.settings:trackByPages() then
      local page_step = self.settings:trackPageStep()
      local last_compare = math.floor(previous_mapped_page / page_step)
      local current_compare = math.floor(current_mapped_page / page_step)
      should_sync = (last_compare ~= current_compare)
    end

    if should_sync then
      local percentage = math.floor(current_percent * 100 + 0.5)
      local last_percent = math.floor(previous_percent * 100 + 0.5)
      local remote_percent = self.state.book_status.percent_finished or 0
      if percentage > last_percent and percentage >= remote_percent then
        if self.settings:syncByRemotePages() and current_mapped_page then
          self:_handlePageUpdate(self.ui.document.file, current_mapped_page, false, nil, "pages")
        else
          self:_handlePageUpdate(self.ui.document.file, percentage)
        end
      end
    end
  end
end

function HardcoverApp:onPosUpdate(_, page)
  if self.state.process_page_turns then
    self:pageUpdateEvent(page)
  end
end

function HardcoverApp:onUpdatePos()
  self.page_mapper:cachePageMap()
end

function HardcoverApp:onReaderReady()
  self.page_mapper:cachePageMap()
  self:registerHighlight()
  self.state.page = self.ui:getCurrentPage()
 
  if self.ui.document and (self.settings:bookLinked() or self.settings:autolinkEnabled()) then
    UIManager:scheduleIn(1, self.startReadCache, self)
  end
  UIManager:scheduleIn(1, self.initiateVersionCheck, self)
end

function HardcoverApp:initiateVersionCheck()
  if self.state.version_checked then return end

  local last_check = self.settings:readSetting(SETTING.LAST_VERSION_CHECK) or 0
  local interval = self.settings:readSetting(SETTING.VERSION_CHECK_INTERVAL) or 1
  local now = os.time()
  
  -- Always check on first startup of the session, otherwise respect interval
  if not self.state.session_checked or (now - last_check >= (interval * 24 * 3600)) then
    self.state.session_checked = true
    self:checkForUpdates()
  else
    -- Schedule it for when it's next due
    local next_check_in = math.max(1, (interval * 24 * 3600) - (now - last_check))
    UIManager:scheduleIn(next_check_in, self.checkForUpdates, self)
  end
end

function HardcoverApp:checkForUpdates()
  -- If we're already out of date and NOT ignoring, no need to keep checking
  if not self.enabled and not self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) then
    return
  end

  self.wifi:withWifi(function()
    local Github = require("hardcover/lib/github")
    local info = Github:fetchVersionInfo()
    if not info then return end

    self.state.version_checked = true
    self.settings:updateSetting(SETTING.LAST_VERSION_CHECK, os.time())

    -- Check for mandatory update
    local plugin_path = self.path or (DataStorage:getPluginDir() .. "/storygraph.koplugin")
    local Meta = dofile(plugin_path .. "/_meta.lua")

    if info.api_version and Meta.api_version < info.api_version then
      -- Always mark as disabled internally if version is outdated
      self.enabled = false
      self.menu.enabled = false

      if self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) then
        UIManager:show(Notification:new {
          text = _("StoryGraph: Mandatory update available (Ignored)"),
          timeout = 5
        })
      else
        self:cancelPendingUpdates()
        
        if self.settings:readSetting(SETTING.SHOW_VERSION_DIALOG) ~= false then
          UIManager:show(Notification:new {
            text = info.message or _("StoryGraph: Mandatory update required!"),
            timeout = 10
          })
        end
        return
      end
    else
      -- Up to date, schedule the next check
      local interval = self.settings:readSetting(SETTING.VERSION_CHECK_INTERVAL) or 1
      UIManager:scheduleIn(interval * 24 * 3600, self.checkForUpdates, self)
    end
  end)
end

function HardcoverApp:cancelPendingUpdates()
  if self._cancelPageUpdate then
    self:_cancelPageUpdate()
  end

  if self._cancelPageUpdateEvent then
    self:_cancelPageUpdateEvent()
  end

  self.page_update_pending = false
end

function HardcoverApp:onDocumentClose()
  UIManager:unschedule(self.startCacheRead)

  self:cancelPendingUpdates()
  self.state.read_cache_started = false

  if not self.state.book_status.id and not self.settings:syncEnabled() then
    return
  end

  if self.page_update_pending then
    self:updatePageNow()
  end

  self.process_page_turns = false
  self.page_update_pending = false
  self.state.book_status = {}
  self.state.page_map = nil
end

function HardcoverApp:onSuspend()
  self:cancelPendingUpdates()

  Scheduler:clear()
  self.state.read_cache_started = false
end

function HardcoverApp:onResume()
  if self.settings:readSetting(SETTING.ENABLE_WIFI) and self.ui.document and self.settings:syncEnabled() then
    UIManager:scheduleIn(2, self.startReadCache, self)
  end
end

function HardcoverApp:updatePageNow(callback, value, update_type)
  if not value then
    local decimal_percent, mapped_page = self.page_mapper:getRemotePagePercent(
      self.state.page,
      self.ui.document:getPageCount(),
      self.settings:pages()
    )
    if self.settings:syncByRemotePages() and mapped_page then
      value = mapped_page
      update_type = "pages"
    else
      value = math.floor(decimal_percent * 100 + 0.5)
      update_type = "percentage"
    end
  end
  self:_handlePageUpdate(self.ui.document.file, value, true, callback, update_type)
end

function HardcoverApp:onNetworkDisconnecting()
  --logger.warn("HARDCOVER on disconnecting")
  if self.settings:readSetting(SETTING.ENABLE_WIFI) then
    return
  end

  self:cancelPendingUpdates()

  Scheduler:clear()
  self.state.read_cache_started = false

  if self.page_update_pending and self.ui.document and self.state.book_status.id and self.settings:syncEnabled() and self.settings:trackByTime() then
    self:updatePageNow()
  end
  self.page_update_pending = false
end

function HardcoverApp:onNetworkConnected()
  if self.ui.document and self.settings:syncEnabled() and not self.state.read_cache_started then
    --logger.warn("HARDCOVER on connected", self.state.read_cache_started)

    self:startReadCache()
  end
end

function HardcoverApp:onEndOfBook()
  local file_path = self.ui.document.file

  if not self:syncFileUpdates(file_path) then
    return
  end

  local mark_read = false
  if G_reader_settings:isTrue("end_document_auto_mark") then
    mark_read = true
  end

  if not mark_read then
    local action = G_reader_settings:readSetting("end_document_action") or "pop-up"
    mark_read = action == "mark_read"

    if action == "pop-up" then
      mark_read = 'later'
    end
  end

  if not mark_read then
    return
  end

  local user_id = User:getId()

  local marker = function()
    local book_id = self.settings:readBookSetting(file_path, "book_id")
    local user_book = Api:findUserBook(book_id, user_id) or {}
    self.cache:updateBookStatus(file_path, HARDCOVER.STATUS.FINISHED)
  end

  if mark_read == 'later' then
    UIManager:scheduleIn(30, function()
      local status = "reading"
      if DocSettings:hasSidecarFile(file_path) then
        local summary = DocSettings:open(file_path):readSetting("summary")
        if summary and summary.status and summary.status ~= "" then
          status = summary.status
        end
      end
      if status == "complete" then
        self.wifi:withWifi(function()
          marker()
        end)
      end
    end)
  else
    self.wifi:withWifi(function()
      marker()
      UIManager:show(InfoMessage:new {
        text = _("StoryGraph status saved"),
        timeout = 2
      })
    end)
  end
end

function HardcoverApp:syncFileUpdates(filename)
  return self.settings:readBookSetting(filename, "book_id") and self.settings:fileSyncEnabled(filename)
end

function HardcoverApp:onDocSettingsItemsChanged(file, doc_settings)
  if not self:syncFileUpdates(file) or not doc_settings then
    return
  end

  local status
  if doc_settings.summary.status == "complete" then
    status = HARDCOVER.STATUS.FINISHED
  elseif doc_settings.summary.status == "reading" then
    status = HARDCOVER.STATUS.READING
  end

  if status then
    local book_id = self.settings:readBookSetting(file, "book_id")
    local user_book = Api:findUserBook(book_id, User:getId()) or {}
    self.wifi:withWifi(function()
      self.cache:updateBookStatus(file, status)

      UIManager:show(InfoMessage:new {
        text = _("StoryGraph status saved"),
        timeout = 2
      })
    end)
  end
end

function HardcoverApp:startReadCache()
  logger.info("StoryGraph: startReadCache triggered")
  if not self:isActive() then
    logger.info("StoryGraph: startReadCache aborted - app not active")
    return
  end

  if self.state.read_cache_started then
    logger.info("StoryGraph: startReadCache aborted - already started")
    return
  end

  if not self.ui.document then
    --logger.warn("HARDCOVER read cache fired outside of document")
    return
  end

  self.state.read_cache_started = true

  local cancel

  local restart = function(delay)
    --logger.warn("HARDCOVER restart cache fetch")
    delay = delay or 60
    cancel()
    self.state.read_cache_started = false
    UIManager:scheduleIn(delay, self.startReadCache, self)
  end

  cancel = Scheduler:withRetries(6, 3, function(success, fail)
      Trapper:wrap(function()
        if not self.ui.document then
          -- fail, but cancel retries
          return success()
        end
        local book_settings = self.settings:readBookSettings(self.ui.document.file) or {}
        --logger.warn("HARDCOVER", book_settings)
        if book_settings.book_id then
          if self.state.book_status.id then
            return success()
          else
            self.wifi:withWifi(function()
              if not NetworkManager:isConnected() then
                return restart()
              end

              local err = self.cache:cacheUserBook()
              self:registerHighlight()
              logger.info("StoryGraph: startReadCache - cacheUserBook completed, status=" .. (self.state.book_status.status_id or "nil"))
              if err and err.completed == false then
                return fail(err)
              end

              success()
              self:registerHighlight() -- redundant but safe
            end)
          end
        else
          self.hardcover:tryAutolink()
          if self.settings:bookLinked() and self.settings:syncEnabled() then
            return restart(2)
          end
        end
      end)
    end,

    function()
      if self.settings:syncEnabled() then
        --logger.warn("HARDCOVER enabling page turns")

        self.state.process_page_turns = true
      end
    end,

    function()
      if NetworkManager:isConnected() then
        UIManager:show(Notification:new {
          text = _("Failed to fetch book information from StoryGraph"),
        })
      end
    end)
end

function HardcoverApp:isActive()
  return self.enabled or self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) == true
end

function HardcoverApp:registerHighlight()
  self.ui.highlight:removeFromHighlightDialog(HIGHLIGHT_MENU_NAME)

  if self.settings:bookLinked() then
    self.ui.highlight:addToHighlightDialog(HIGHLIGHT_MENU_NAME, function(this)
      return {
        text_func = function()
          return _("StoryGraph: Add note")
        end,
        enabled_func = function()
          local status = self.state.book_status.status_id
          return self:isActive() and status and status ~= HARDCOVER.STATUS.FINISHED and status ~= HARDCOVER.STATUS.DNF and status ~= HARDCOVER.STATUS.TO_READ
        end,
        callback = function()
          if not self:isActive() then return end
          local selected_text = this.selected_text
          local raw_page = selected_text.pos0.page
          if not raw_page then
            raw_page = self.view.document:getPageFromXPointer(selected_text.pos0)
          end
          -- open journal dialog
          self:onStoryGraphNote({
            text = selected_text.text,
            page_number = raw_page,
            note_type = "quote"
          })

          this:onClose()
        end,
      }
    end)
  end
end

function HardcoverApp:addToMainMenu(menu_items)
  menu_items.storygraph = self.menu:mainMenu()
end

return HardcoverApp
