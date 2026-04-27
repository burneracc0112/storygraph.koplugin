local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputDialog = require("ui/widget/inputdialog")
local InputText = require("ui/widget/inputtext")
local Size = require("ui/size")
local SpinWidget = require("ui/widget/spinwidget")
local DateTimeWidget = require("ui/widget/datetimewidget")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template
local logger = require("logger")

local JournalDialog = InputDialog:extend {
  allow_newline = true,
  results = {},
  title = "Update StoryGraph progress",
  padding = 10,

  page = nil, -- local progress percent
  remote_page = nil, -- remote progress percent
  book_id = nil,
  date = nil, -- table with day, month, year
}

function JournalDialog:init()
  self:setModified()
  self.date = self.date or os.date("*t")

  local text_widget = TextBoxWidget:new {
    text = "",
    face = Font:getFace("smallinfofont"),
    for_measurement_only = true,
  }
  self.text_height = text_widget:getTextHeight()

  self.save_callback = function()
    return self.save_dialog_callback({
      book_id = self.book_id,
      text = self.note_input:getText(),
      progress = self.page,
      date = self.date
    })
  end

  InputDialog.init(self)
  self.note_input = self._input_widget

  -- Progress Button
  self.page_button = Button:new {
    text_func = function()
      return _("Progress: " .. self.page .. "%")
    end,
    width = (self.width - 20) / 2,
    text_font_size = 18,
    bordersize = Size.border.thin,
    callback = function()
      local progress_picker = DateTimeWidget:new{
        day = self.page,
        day_min = 0,
        day_max = 100,
        ok_text = _("Set progress"),
        title_text = _("Set progress"),
        info_text = T(_("KOReader %1%, StoryGraph %2%"), self.page, self.remote_page or "?"),
        callback = function(picker)
          self.page = picker.day
          self.page_button:setText(self.page_button.text_func(self), self.page_button.width)
        end
      }
      self:onCloseKeyboard()
      UIManager:show(progress_picker)
    end
  }

  -- Date Button (triggers DateTimeWidget)
  self.date_button = Button:new {
    text_func = function()
      return string.format("%04d-%02d-%02d", self.date.year, self.date.month, self.date.day)
    end,
    width = (self.width - 20) / 2,
    text_font_size = 18,
    bordersize = Size.border.thin,
    callback = function()
      local date_picker = DateTimeWidget:new{
        year = self.date.year,
        month = self.date.month,
        day = self.date.day,
        ok_text = _("Set date"),
        title_text = _("Set date"),
        info_text = _("The date format is year, month, day."),
        callback = function(picker)
          self.date = {
            year = picker.year,
            month = picker.month,
            day = picker.day
          }
          self.date_button:setText(self.date_button.text_func(self), self.date_button.width)
        end
      }
      self:onCloseKeyboard()
      UIManager:show(date_picker)
    end
  }

  local control_row = FrameContainer:new {
    padding_top = 10,
    padding_bottom = 8,
    bordersize = 0,
    HorizontalGroup:new {
      self.page_button,
      HorizontalSpan:new { width = 10 },
      self.date_button
    }
  }

  self:addWidget(control_row)
end

function JournalDialog:setModified()
  if self.input then
    self._text_modified = true
    if self.button_table then
      self.button_table:getButtonById("save"):enable()
      self:refreshButtons()
    end
  end
end

function JournalDialog:onSwitchFocus(inputbox)
  self._input_widget:unfocus()
  self:onCloseKeyboard()
  UIManager:setDirty(nil, function()
    return "ui", self.dialog_frame.dimen
  end)
  self._input_widget = inputbox
  self._input_widget:focus()
  self.focused_field_idx = inputbox.idx
  if (Device:hasKeyboard() or Device:hasScreenKB()) and G_reader_settings:isFalse("virtual_keyboard_enabled") then
    return
  end
  self:onShowKeyboard()
end

return JournalDialog
