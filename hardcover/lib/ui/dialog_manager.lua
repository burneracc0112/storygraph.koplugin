local _ = require("gettext")
local json = require("json")

local UIManager = require("ui/uimanager")

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local FileSearcher = require("apps/filemanager/filemanagerfilesearcher")

local Api = require("hardcover/lib/hardcover_api")
local Book = require("hardcover/lib/book")
local User = require("hardcover/lib/user")

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SETTING = require("hardcover/lib/constants/settings")

local JournalDialog = require("hardcover/lib/ui/journal_dialog")
local SearchDialog = require("hardcover/lib/ui/search_dialog")

local DialogManager = {}
DialogManager.__index = DialogManager

function DialogManager:new(o)
  return setmetatable(o or {}, self)
end

local function mapJournalData(data)
  return {
    book_id = data.book_id,
    entry = data.text,
    progress = data.progress,
    date = data.date
  }
end

function DialogManager:buildSearchDialog(title, items, active_item, book_callback, search_callback, search)
  local callback = function(book)
    self.search_dialog:onClose()
    book_callback(book)
  end

  if self.search_dialog then
    self.search_dialog:free()
  end

  self.search_dialog = SearchDialog:new {
    compatibility_mode = self.settings:compatibilityMode(),
    title = title,
    items = items,
    active_item = active_item,
    select_book_cb = callback,
    search_callback = search_callback,
    search_value = search
  }

  UIManager:show(self.search_dialog)
end

function DialogManager:confirm(options)
  options.text = options.text or "Are you sure"

  UIManager:show(ConfirmBox:new(options))
end

function DialogManager:maybeConfirm(options)
  local original_callback = options.ok_callback

  local manual_confirm_callback = options.no_confirm_callback
  options.no_confirm_callback = nil

  if self.settings:menuConfirm() then
    options.ok_callback = function()
      original_callback()
      if manual_confirm_callback then
        manual_confirm_callback()
      end
    end

    self:confirm(options)
  else
    original_callback()
  end
end

function DialogManager:buildBookListDialog(title, items, icon_callback, disable_wifi_after)
  if self.search_dialog then
    self.search_dialog:free()
  end

  self.search_dialog = SearchDialog:new {
    compatibility_mode = self.settings:compatibilityMode(),
    title = title,
    items = items,
    left_icon_callback = icon_callback,
    left_icon = "cre.render.reload",
    select_book_cb = function(book)
      local clean_title = book.title:gsub("^The ", ""):gsub("^An ", ""):gsub("^A ", ""):gsub(" ?%(%d+%)$", "")

      FileSearcher.search_path = G_reader_settings:readSetting("home_dir")
      FileSearcher.search_string = clean_title
      self.ui.filesearcher.case_sensitive = false
      self.ui.filesearcher.include_subfolders = true
      self.ui.filesearcher.include_metadata = true
      self.ui.filesearcher:doSearch()
    end,
    close_callback = function()
      if disable_wifi_after then
        UIManager:nextTick(function()
          self.wifi:wifiDisablePrompt()
        end)
      end
    end
  }

  UIManager:show(self.search_dialog)
end

function DialogManager:updateSearchResults(search)
  local books, error = Api:findBooks(search, nil, User:getId())
  if error then
    if not Api.enabled then
      UIManager:close(self.search_dialog)
    end

    return
  end

  self.search_dialog:setItems(self.search_dialog.title, books, self.search_dialog.active_item)
  self.search_dialog.search_value = search
end

function DialogManager:updateRandomBooks(books)
  self.search_dialog:setItems(self.search_dialog.title, books)
end

function DialogManager:journalEntryForm(text, document, page, remote_pages, initial_percent, remote_percent, event_type)
  local settings = self.settings:readBookSettings(document.file) or {}
  local total_pages = document:getPageCount()

  if not initial_percent then
    initial_percent = math.floor((page / total_pages) * 100)
  end

  -- Augment text with location info
  local include_location = (event_type == "quote") or (self.settings:readSetting(SETTING.INCLUDE_LOCATION_IN_NOTES) == true)

  if include_location then
    local chapter
    if self.ui.toc and self.ui.toc.getTocTitleOfCurrentPage then
      chapter = self.ui.toc:getTocTitleOfCurrentPage()
    elseif self.ui.toc and self.ui.toc.getChapterName then
      chapter = self.ui.toc:getChapterName()
    end

    local location_info = string.format("\n\n(Chapter: %s, Page %d of %d, %d%%)", 
      chapter or "N/A", page, total_pages, initial_percent)

    if text and text ~= "" then
      text = text .. location_info
    else
      text = location_info
    end
  end

  local wifi_was_off = false
  local dialog
  dialog = JournalDialog:new {
    input = text,
    book_id = settings.book_id,
    page = initial_percent,
    remote_page = remote_percent,
    save_dialog_callback = function(book_data)
      local api_data = mapJournalData(book_data)
      local result = Api:createJournalEntry(api_data)
      if result then
        UIManager:nextTick(function()
          UIManager:close(dialog)

          if wifi_was_off then
            UIManager:nextTick(function()
              self.wifi:wifiDisablePrompt()
            end)
          end
        end)

        return true, _("StoryGraph progress updated")
      else
        return false, _("Failed to update StoryGraph")
      end
    end,

    close_callback = function()
      if wifi_was_off then
        UIManager:nextTick(function()
          self.wifi:wifiDisablePrompt()
        end)
      end
    end
  }
  -- scroll to the bottom instead of overscroll displayed
  dialog._input_widget:scrollToBottom()

  self.wifi:wifiPrompt(function(wifi_enabled)
    wifi_was_off = wifi_enabled

    UIManager:show(dialog)
    dialog:onShowKeyboard()
  end)
end

function DialogManager:showError(err)
  UIManager:show(InfoMessage:new {
    text = err,
    icon = "notice-warning",
    timeout = 2
  })
end

return DialogManager
