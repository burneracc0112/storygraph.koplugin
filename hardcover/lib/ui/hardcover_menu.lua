local DataStorage = require("datastorage")
local Device = require("device")
local _ = require("gettext")
local math = require("math")
local os = require("os")
local logger = require("logger")

local T = require("ffi/util").template

local Event = require("ui/event")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")

local UpdateDoubleSpinWidget = require("hardcover/lib/ui/update_double_spin_widget")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local SpinWidget = require("ui/widget/spinwidget")

local Api = require("hardcover/lib/hardcover_api")
local Github = require("hardcover/lib/github")
local User = require("hardcover/lib/user")
local _t = require("hardcover/lib/table_util")

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local ICON = require("hardcover/lib/constants/icons")
local SETTING = require("hardcover/lib/constants/settings")
local VERSION = require("hardcover_version")

local HardcoverMenu = {}
HardcoverMenu.__index = HardcoverMenu

function HardcoverMenu:new(o)
  return setmetatable(o or {
    enabled = true
  }, self)
end

-- Removed privacy_labels

function HardcoverMenu:isActive()
  return self.enabled or self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) == true
end

function HardcoverMenu:mainMenu()
  return {
    enabled_func = function()
      return true
    end,
    text_func = function()
      return self.settings:bookLinked() and _("StoryGraph: " .. ICON.LINK) or _("StoryGraph")
    end,
    sub_item_table_func = function()
      local has_book = self.ui.document and true or false
      return self:getSubMenuItems(has_book)
    end,
  }
end

function HardcoverMenu:getSubMenuItems(book_view)
  local menu_items = {
    book_view and {
      text_func = function()
        if self.settings:bookLinked() then
          -- need to show link information somehow. Maybe store title
          local title = self.settings:getLinkedTitle()
          if not title then
            title = self.settings:getLinkedBookId()
          end
          return _("Linked book: " .. title)
        else
          return _("Link book")
        end
      end,
      enabled_func = function()
        return self:isActive()
      end,
      hold_callback = function(menu_instance)
        if self.settings:bookLinked() then
          self.settings:updateBookSetting(
            self.ui.document.file,
            {
              _delete = { 'book_id', 'edition_id', 'edition_format', 'pages', 'title' }
            }
          )

          menu_instance:updateItems()
        end
      end,
      keep_menu_open = true,
      callback = function(menu_instance)
        if not self:isActive() then
          return
        end

        local force_search = self.settings:bookLinked()

        self.hardcover:showLinkBookDialog(force_search, function()
          menu_instance:updateItems()
        end)
      end,
    },
    book_view and {
      text_func = function()
        local edition_format = self.settings:getLinkedEditionFormat()
        local title = "Change edition"

        if edition_format then
          title = title .. ": " .. edition_format
        elseif self.settings:getLinkedEditionId() then
          return title .. ": physical book"
        end

        return _(title)
      end,
      enabled_func = function()
        return self:isActive() and self.settings:bookLinked()
      end,
      callback = function(menu_instance)
        self.hardcover:showChangeEditionDialog(function()
          menu_instance:updateItems()
        end)
      end,
      keep_menu_open = true,
      separator = true
    },
    book_view and {
      text = _("Automatically track progress"),
      checked_func = function()
        return self.settings:syncEnabled()
      end,
      enabled_func = function()
        return self:isActive() and self.settings:bookLinked()
      end,
      callback = function()
        local sync = not self.settings:syncEnabled()
        self.settings:setSync(sync)
      end,
    },
    book_view and {
      text = _("Update status"),
      enabled_func = function()
        return self:isActive() and self.settings:bookLinked()
      end,
      sub_item_table_func = function()
        self.cache:cacheUserBook()

        return self:getStatusSubMenuItems()
      end,
      separator = true
    },
    book_view and {
      text = _("Jump to StoryGraph position"),
      enabled_func = function()
        return self:isActive() and self.settings:bookLinked()
      end,
      callback = function()
        UIManager:broadcastEvent(Event:new("StoryGraphPullPosition"))
      end,
      separator = true
    },

    {
      text = _("Settings"),
      sub_item_table_func = function()
        return self:getSettingsSubMenuItems()
      end,
    },
    {
      text = _("About"),
      callback = function()
        local info = Github:fetchVersionInfo()
        local version = table.concat(VERSION, ".")
        local new_release_str = ""
        if info and info.plugin_version and Github:isNewer(info.plugin_version) then
          new_release_str = " (latest v" .. info.plugin_version .. ")"
        end
        local settings_file = DataStorage:getSettingsDir() .. "/" .. "storygraphsync_settings.lua"

        UIManager:show(InfoMessage:new {
          text = [[
StoryGraph plugin
v]] .. version .. new_release_str .. [[


Updates book progress and status on thestorygraph.com

Project:
github.com/billiam/hardcoverapp.koplugin (forked for StoryGraph)

Settings:
]] .. settings_file,
          face = Font:getFace("cfont", 18),
          show_icon = false,
        })
      end,
      keep_menu_open = true
    }
  }
  return _t.filter(menu_items, function(v)
    return v
  end)
end

function HardcoverMenu:getStatusSubMenuItems()
  local items = {
    {
      text = _(ICON.BOOKMARK .. " Want To Read"),
      checked_func = function()
        return self.state.book_status.status_id == HARDCOVER.STATUS.TO_READ
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Mark book as Want To Read?",
          ok_callback = function()
            self.cache:updateBookStatus(self.ui.document.file, HARDCOVER.STATUS.TO_READ)
            menu_instance.item_table = self:getStatusSubMenuItems()
            menu_instance:updateItems()
          end,
          no_confirm_callback = function()
            menu_instance:updateItems()
          end
        })
      end,
      radio = true
    },
    {
      text = _(ICON.OPEN_BOOK .. " Currently Reading"),
      checked_func = function()
        return self.state.book_status.status_id == HARDCOVER.STATUS.READING
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Mark book as Currently Reading?",
          ok_callback = function()
            self.cache:updateBookStatus(self.ui.document.file, HARDCOVER.STATUS.READING)
            menu_instance.item_table = self:getStatusSubMenuItems()
            menu_instance:updateItems()
          end,
          no_confirm_callback = function()
            menu_instance:updateItems()
          end
        })
      end,
      radio = true
    },
    {
      text = _(ICON.CHECKMARK .. " Read"),
      checked_func = function()
        return self.state.book_status.status_id == HARDCOVER.STATUS.FINISHED
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Mark book as Read?",
          ok_callback = function()
            self.cache:updateBookStatus(self.ui.document.file, HARDCOVER.STATUS.FINISHED)
            menu_instance.item_table = self:getStatusSubMenuItems()
            menu_instance:updateItems()
          end,
          no_confirm_callback = function()
            menu_instance:updateItems()
          end
        })
      end,
      radio = true
    },
    {
      text = _(ICON.PAUSE .. " Paused"),
      checked_func = function()
        return self.state.book_status.status_id == HARDCOVER.STATUS.PAUSED
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Mark book as Paused?",
          ok_callback = function()
            self.cache:updateBookStatus(self.ui.document.file, HARDCOVER.STATUS.PAUSED)
            menu_instance.item_table = self:getStatusSubMenuItems()
            menu_instance:updateItems()
          end,
          no_confirm_callback = function()
            menu_instance:updateItems()
          end
        })
      end,
      radio = true
    },
    {
      text = _(ICON.STOP_CIRCLE .. " Did Not Finish"),
      checked_func = function()
        return self.state.book_status.status_id == HARDCOVER.STATUS.DNF
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Mark book as Did Not Finish?",
          ok_callback = function()
            self.cache:updateBookStatus(self.ui.document.file, HARDCOVER.STATUS.DNF)
            menu_instance.item_table = self:getStatusSubMenuItems()
            menu_instance:updateItems()
          end,
          no_confirm_callback = function()
            menu_instance:updateItems()
          end
        })
      end,
      radio = true,
    },
    {
      text = _(ICON.TRASH .. " Remove"),
      enabled_func = function()
        return self.enabled and self.state.book_status.status_id ~= nil
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Remove current book status?",
          ok_callback = function()
            local result = Api:removeRead(self.state.book_status.id)
            if result then
              self.state.book_status = {}
              menu_instance.item_table = self:getStatusSubMenuItems()
              menu_instance:updateItems()
            end
          end
        })
      end,
      keep_menu_open = true,
    },
    {
      text = _("Owned"),
      enabled_func = function()
        return self.state.book_status.id ~= nil
      end,
      checked_func = function()
        return self.state.book_status.is_owned == true
      end,
      callback = function(menu_instance)
        local new_status = not self.state.book_status.is_owned
        local success = Api:setOwned(self.state.book_status.id, new_status)
        if success then
          self.state.book_status.is_owned = new_status
          menu_instance:updateItems()
        end
      end,
      keep_menu_open = true,
    },
    {
      text = _("Favorite"),
      enabled_func = function()
        return self.state.book_status.id ~= nil
      end,
      checked_func = function()
        return self.state.book_status.is_favorite == true
      end,
      callback = function(menu_instance)
        local new_status = not self.state.book_status.is_favorite
        local success = Api:setFavorite(self.state.book_status.id, new_status)
        if success then
          self.state.book_status.is_favorite = new_status
          menu_instance:updateItems()
        end
      end,
      keep_menu_open = true,
      separator = true
    },
  }

  local status = self.state.book_status.status_id

  -- Update progress: only when NOT read, DNF, removed, or want to read
  if status and status ~= HARDCOVER.STATUS.FINISHED and status ~= HARDCOVER.STATUS.DNF and status ~= HARDCOVER.STATUS.TO_READ then
    table.insert(items, {
      text_func = function()
        local current_page = self.ui:getCurrentPage()
        local total_pages = self.ui.document:getPageCount()
        local remote_pages = self.settings:pages()
        if self.settings:syncByRemotePages() then
          local mapped_page = self.page_mapper:getMappedPage(current_page, total_pages, remote_pages)
          return T(_("Update progress: Page %1 / %2"), mapped_page, remote_pages or "?")
        else
          local current_percent = math.floor((current_page / total_pages) * 100 + 0.5)
          return T(_("Update progress: %1%"), current_percent)
        end
      end,
      callback = function()
        local current_page = self.ui:getCurrentPage()
        local remote_percent = self.state.book_status.last_reached_percent or 0

        self.dialog_manager:journalEntryForm(
          "",
          self.ui.document,
          current_page,
          self.settings:pages(),
          nil, -- let journalEntryForm handle it based on settings
          remote_percent,
          "note"
        )
      end,
      keep_menu_open = true
    })
  end

  -- Review: only when read or DNF or can_review
  if status and (status == HARDCOVER.STATUS.FINISHED or status == HARDCOVER.STATUS.DNF or self.state.book_status.can_review) then
    table.insert(items, {
      text = _("Review"),
      sub_item_table_func = function(menu_instance)
        return self:getReviewSubMenuItems(menu_instance)
      end,
      keep_menu_open = true,
      separator = true
    })
  end

  return items
end

function HardcoverMenu:getReviewSubMenuItems(menu_instance)
  if not self.state.review then
    local existing_review = nil
    if self.state.book_status.review_url then
      local InfoMessage = require("ui/widget/infomessage")
      local info = InfoMessage:new{
        text = _("Fetching existing review..."),
      }
      UIManager:show(info)
      existing_review = Api:getReview(self.state.book_status.review_url)
      UIManager:close(info)
    end

    if existing_review then
      self.state.review = existing_review
    else
      self.state.review = {
        stars = self.state.book_status.rating or 0,
        pace = "",
        driven = "",
        development = "",
        loveable = "",
        diverse = "",
        flaws = "",
        themes = "",
        thoughts = "",
        mood_ids = {}
      }
    end
  end

  local review = self.state.review
  local book_id = self.state.book_status.id

  local function make_options_items(key, options, menu_instance)
    local sub_items = {}
    for _, opt in ipairs(options) do
      local display_text
      if opt == "" then display_text = "Not selected"
      elseif opt == "n/a" then display_text = "N/A"
      else display_text = opt:gsub("^%l", string.upper)
      end
      table.insert(sub_items, {
        text = display_text,
        radio = true,
        checked_func = function() return review[key] == opt end,
        callback = function()
          review[key] = opt
          if menu_instance and menu_instance.updateItems then
            menu_instance:updateItems()
          end
        end
      })
    end
    return sub_items
  end

  local function get_display_val(val)
    if val == "" then return "Not selected" end
    if val == "n/a" then return "N/A" end
    return val:gsub("^%l", string.upper)
  end

  return {
    {
      text_func = function()
        local stars = review.stars or 0
        local whole = math.floor(stars)
        local star_string = string.rep(ICON.STAR, whole)
        if stars - whole >= 0.25 then star_string = star_string .. ICON.HALF_STAR end
        return "Rating: " .. stars .. " " .. star_string
      end,
      callback = function(menu_instance)
        local spinner = SpinWidget:new {
          value = review.stars or 2.5,
          value_min = 0,
          value_max = 5,
          value_step = 0.25,
          value_hold_step = 1,
          precision = "%.2f",
          ok_text = _("Set"),
          title_text = _("Set Rating"),
          callback = function(spin)
            review.stars = spin.value
            menu_instance:updateItems()
          end
        }
        UIManager:show(spinner)
      end,
      keep_menu_open = true,
    },
    {
      text = "Moods",
      sub_item_table_func = function(menu_instance)
        local moods = {
          "adventurous", "challenging", "dark", "emotional", "funny",
          "hopeful", "informative", "inspiring", "lighthearted",
          "mysterious", "reflective", "relaxing", "sad", "tense"
        }
        local sub_items = {}
        for i, mood in ipairs(moods) do
          table.insert(sub_items, {
            text = mood:gsub("^%l", string.upper),
            checked_func = function()
              for _, id in ipairs(review.mood_ids) do
                if id == i then return true end
              end
              return false
            end,
            callback = function()
              local found = false
              for idx, id in ipairs(review.mood_ids) do
                if id == i then
                  table.remove(review.mood_ids, idx)
                  found = true
                  break
                end
              end
              if not found then
                table.insert(review.mood_ids, i)
              end
              if menu_instance then menu_instance:updateItems() end
            end,
            keep_menu_open = true,
          })
        end
        return sub_items
      end
    },
    {
      text_func = function() return "Pace: " .. get_display_val(review.pace) end,
      sub_item_table_func = function(menu_instance)
        return make_options_items("pace", {"", "slow", "medium", "fast", "n/a"}, menu_instance)
      end
    },
    {
      text_func = function() return "Driven by: " .. get_display_val(review.driven) end,
      sub_item_table_func = function(menu_instance)
        return make_options_items("driven", {"", "plot", "character", "a mix", "n/a"}, menu_instance)
      end
    },
    {
      text_func = function() return "Character Development: " .. get_display_val(review.development) end,
      sub_item_table_func = function(menu_instance)
        return make_options_items("development", {"", "yes", "no", "it's complicated", "n/a"}, menu_instance)
      end
    },
    {
      text_func = function() return "Loveable characters: " .. get_display_val(review.loveable) end,
      sub_item_table_func = function(menu_instance)
        return make_options_items("loveable", {"", "yes", "no", "it's complicated", "n/a"}, menu_instance)
      end
    },
    {
      text_func = function() return "Diverse cast: " .. get_display_val(review.diverse) end,
      sub_item_table_func = function(menu_instance)
        return make_options_items("diverse", {"", "yes", "no", "it's complicated", "n/a"}, menu_instance)
      end
    },
    {
      text_func = function() return "Character flaws: " .. get_display_val(review.flaws) end,
      sub_item_table_func = function(menu_instance)
        return make_options_items("flaws", {"", "yes", "no", "it's complicated", "n/a"}, menu_instance)
      end
    },
    {
      text = "Themes",
      callback = function(menu_instance)
        local MultiInput = require("ui/widget/multiinputdialog")
        local themes_dialog = MultiInput:new {
          title = "Themes (comma separated)",
          fields = {
            {
              text = review.themes,
            }
          },
          buttons = {
            {
              text = _("Cancel"),
              id = "close",
            },
            {
              text = _("Set"),
              callback = function(dialog)
                review.themes = dialog:getFields()[1]
                menu_instance:updateItems()
                UIManager:close(dialog)
              end
            }
          }
        }
        UIManager:show(themes_dialog)
      end,
      keep_menu_open = true,
    },
    {
      text = "Thoughts",
      callback = function(inner_menu)
        local m = inner_menu or menu_instance
        local MultiInput = require("ui/widget/multiinputdialog")
        local thoughts_dialog = MultiInput:new {
          title = "Your thoughts",
          fields = {
            {
              text = review.thoughts,
              input_type = "text",
            }
          },
          buttons = {
            {
              text = _("Cancel"),
              id = "close",
            },
            {
              text = _("Set"),
              callback = function(dialog)
                review.thoughts = dialog:getFields()[1]
                if m then m:updateItems() end
                UIManager:close(dialog)
              end
            }
          }
        }
        UIManager:show(thoughts_dialog)
      end,
      keep_menu_open = true,
    },
    {
      text = "Save Review",
      callback = function(menu_instance)
        local success = Api:saveReview(book_id, review, self.state.book_status.review_url)
        if success then
          self.cache:cacheUserBook()
          UIManager:show(InfoMessage:new { text = "Review saved!" })
          self.state.review = nil -- Clear temp state
          menu_instance:onClose()
        else
          UIManager:show(InfoMessage:new { text = "Failed to save review" })
        end
      end
    }
  }
end

function HardcoverMenu:getTrackingSubMenuItems()
  return {
    {
      text = _("Auto sync by edition pages"),
      checked_func = function()
        return self.settings:syncByRemotePages()
      end,
      enabled_func = function()
        return self:isActive() and self.settings:bookLinked()
      end,
      callback = function()
        local setting = self.settings:syncByRemotePages()
        self.settings:updateSetting(SETTING.SYNC_BY_REMOTE_PAGES, not setting)
      end,
    },

    {
      text = "Always track progress by default",
      checked_func = function()
        return self.settings:readSetting(SETTING.ALWAYS_SYNC) ~= false
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.ALWAYS_SYNC) ~= false
        self.settings:updateSetting(SETTING.ALWAYS_SYNC, not setting)
      end,
      separator = true
    },
    {
      text = "Update periodically",
      radio = true,
      checked_func = function()
        return self.settings:trackByTime()
      end,
      callback = function()
        self.settings:setTrackMethod(SETTING.TRACK.FREQUENCY)
      end
    },
    {
      text_func = function()
        return "Every " .. self.settings:trackFrequency() .. " minutes"
      end,
      enabled_func = function()
        return self.settings:trackByTime()
      end,
      callback = function(menu_instance)
        local spinner = SpinWidget:new {
          value = self.settings:trackFrequency(),
          value_min = 1,
          value_max = 120,
          value_step = 1,
          value_hold_step = 6,
          ok_text = _("Save"),
          title_text = _("Set track frequency"),
          callback = function(spin)
            self.settings:updateSetting(SETTING.TRACK_FREQUENCY, spin.value)
            menu_instance:updateItems()
          end
        }

        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
    {
      text = "Update by progress",
      radio = true,
      checked_func = function()
        return self.settings:trackByProgress()
      end,
      callback = function()
        self.settings:setTrackMethod(SETTING.TRACK.PROGRESS)
      end
    },
    {
      text_func = function()
        return "Every " .. self.settings:trackPercentageInterval() .. " percent completed"
      end,
      enabled_func = function()
        return self.settings:trackByProgress()
      end,
      callback = function(menu_instance)
        local spinner = SpinWidget:new {
          value = self.settings:trackPercentageInterval(),
          value_min = 1,
          value_max = 50,
          value_step = 1,
          value_hold_step = 10,
          ok_text = _("Save"),
          title_text = _("Set track progress"),
          callback = function(spin)
            self.settings:changeTrackPercentageInterval(spin.value)
            menu_instance:updateItems()
          end
        }

        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
    {
      text = "Update by edition pages",
      radio = true,
      checked_func = function()
        return self.settings:trackByPages()
      end,
      callback = function()
        self.settings:setTrackMethod(SETTING.TRACK.PAGES)
      end
    },
    {
      text_func = function()
        return "Every " .. self.settings:trackPageStep() .. " pages completed"
      end,
      enabled_func = function()
        return self.settings:trackByPages()
      end,
      callback = function(menu_instance)
        local spinner = SpinWidget:new {
          value = self.settings:trackPageStep(),
          value_min = 1,
          value_max = 500,
          value_step = 1,
          value_hold_step = 10,
          ok_text = _("Save"),
          title_text = _("Set track pages"),
          callback = function(spin)
            self.settings:updateSetting(SETTING.TRACK_PAGE_STEP, spin.value)
            menu_instance:updateItems()
          end
        }

        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
  }
end

function HardcoverMenu:getUpdateSubMenuItems()
  return {
    {
      text = "Ignore version blocks",
      checked_func = function()
        return self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) == true
      end,
      callback = function(menu_instance)
        local setting = self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) == true
        local new_setting = not setting
        self.settings:updateSetting(SETTING.IGNORE_VERSION_BLOCK, new_setting)
        
        if new_setting then
          UIManager:show(Notification:new {
            text = _("StoryGraph: Version block ignored. Sync enabled."),
            timeout = 5
          })
          self.app:startReadCache()
        else
          UIManager:show(Notification:new {
            text = _("StoryGraph: Version block active. Sync disabled."),
            timeout = 5
          })
          self.app:cancelPendingUpdates()
        end
        menu_instance:updateItems()
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = [[Bypass mandatory update requirements. Use at your own risk as older versions may break sync or cause errors if the StoryGraph API changes.]],
        })
      end
    },
    {
      text = "Show version alert dialog",
      checked_func = function()
        return self.settings:readSetting(SETTING.SHOW_VERSION_DIALOG) ~= false
      end,
      callback = function(menu_instance)
        local setting = self.settings:readSetting(SETTING.SHOW_VERSION_DIALOG) ~= false
        self.settings:updateSetting(SETTING.SHOW_VERSION_DIALOG, not setting)
        menu_instance:updateItems()
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = [[Show a popup dialog when a mandatory update is required. If disabled, the plugin will silently stop working until updated.]],
        })
      end
    },
    {
      text = "Version check frequency",
      callback = function(menu_instance)
        local current = self.settings:readSetting(SETTING.VERSION_CHECK_INTERVAL) or 1
        if type(current) == "table" then current = 1 end
        local spinner
        spinner = SpinWidget:new {
          value = current,
          min = 1,
          max = 30,
          unit = " day(s)",
          title = "Check for updates every X days",
          callback = function(v1, v2)
            local value = type(v1) == "number" and v1 or v2
            self.settings:updateSetting(SETTING.VERSION_CHECK_INTERVAL, value)
            UIManager:close(spinner)
            menu_instance:updateItems()
          end,
        }
        UIManager:show(spinner)
      end,
      text_func = function()
        local current = self.settings:readSetting(SETTING.VERSION_CHECK_INTERVAL) or 1
        if type(current) == "table" then current = 1 end
        return "Check frequency: " .. current .. " day(s)"
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = [[How often to check for mandatory updates. Default is 1 day.]],
        })
      end
    },
  }
end

function HardcoverMenu:getAuthSubMenuItems()
  return {
    {
      text = _("StoryGraph Session Cookie"),
      callback = function()
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local dialog
        dialog = MultiInputDialog:new {
          title = _("StoryGraph Session Cookie"),
          fields = {
            {
              text = self.settings:readSetting(SETTING.SESSION_COOKIE) or "",
            },
          },
          buttons = {
            {
              text = _("Cancel"),
              callback = function()
                UIManager:close(dialog)
              end,
            },
            {
              text = _("Save"),
              callback = function()
                local value = dialog:getFields()[1]:getText()
                self.settings:updateSetting(SETTING.SESSION_COOKIE, value)
                UIManager:close(dialog)
              end,
            },
          },
        }
        UIManager:show(dialog)
      end,
    },
    {
      text = _("StoryGraph Remember Token"),
      callback = function()
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local dialog
        dialog = MultiInputDialog:new {
          title = _("StoryGraph Remember Token"),
          fields = {
            {
              text = self.settings:readSetting(SETTING.REMEMBER_TOKEN) or "",
            },
          },
          buttons = {
            {
              text = _("Cancel"),
              callback = function()
                UIManager:close(dialog)
              end,
            },
            {
              text = _("Save"),
              callback = function()
                local value = dialog:getFields()[1]:getText()
                self.settings:updateSetting(SETTING.REMEMBER_TOKEN, value)
                UIManager:close(dialog)
              end,
            },
          },
        }
        UIManager:show(dialog)
      end,
    }
  }
end

function HardcoverMenu:getSettingsSubMenuItems()
  return {
    {
      text = "Automatically link by ISBN",
      checked_func = function()
        return self.settings:readSetting(SETTING.LINK_BY_ISBN) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.LINK_BY_ISBN) == true
        self.settings:updateSetting(SETTING.LINK_BY_ISBN, not setting)
      end
    },
    {
      text = "Automatically link by title and author",
      checked_func = function()
        return self.settings:readSetting(SETTING.LINK_BY_TITLE) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.LINK_BY_TITLE) == true
        self.settings:updateSetting(SETTING.LINK_BY_TITLE, not setting)
      end,
      separator = true
    },
    {
      text = "Progress tracking settings",
      sub_item_table_func = function()
        return self:getTrackingSubMenuItems()
      end,
      separator = true
    },
    {
      text = "Enable wifi on demand",
      checked_func = function()
        return self.settings:readSetting(SETTING.ENABLE_WIFI) == true
      end,
      enabled_func = function()
        return Device:hasWifiRestore()
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.ENABLE_WIFI) == true
        self.settings:updateSetting(SETTING.ENABLE_WIFI, not setting)
      end
    },
    {
      text = "Confirm changes to book read status",
      checked_func = function()
        return self.settings:menuConfirm()
      end,
      callback = function()
        local setting = self.settings:menuConfirm() == true
        self.settings:setMenuConfirm(not setting)
      end
    },
    {
      text = "Compatibility mode",
      checked_func = function()
        return self.settings:compatibilityMode()
      end,
      callback = function()
        local setting = self.settings:compatibilityMode()
        self.settings:updateSetting(SETTING.COMPATIBILITY_MODE, not setting)
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = [[Disable fancy menu for book and edition search results.
          
May improve compatibility for some versions of KOReader]],
        })
      end
    },
    {
      text = "Include location info in regular notes",
      checked_func = function()
        return self.settings:readSetting(SETTING.INCLUDE_LOCATION_IN_NOTES) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.INCLUDE_LOCATION_IN_NOTES) == true
        self.settings:updateSetting(SETTING.INCLUDE_LOCATION_IN_NOTES, not setting)
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = [[Automatically append Chapter, Page, and % info to your regular notes. 
          
Quotes always include this info.]],
        })
      end,
      separator = true
    },
    {
      text = "Account (Cookies & Tokens)",
      sub_item_table_func = function()
        return self:getAuthSubMenuItems()
      end,
    },
    {
      text = "Plugin Updates",
      sub_item_table_func = function()
        return self:getUpdateSubMenuItems()
      end,
    },
  }
end

return HardcoverMenu
