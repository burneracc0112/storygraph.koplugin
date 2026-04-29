-- wrapper around hardcover_api to add higher level methods
local _ = require("gettext")
local logger = require("logger")
local util = require("util")

local UIManager = require("ui/uimanager")

local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")

local Api = require("storygraph/lib/hardcover_api")
local Book = require("storygraph/lib/book")
local User = require("storygraph/lib/user")

local SETTING = require("storygraph/lib/constants/settings")
local HARDCOVER = require("storygraph/lib/constants/hardcover")

local cache = {}

local Hardcover = {}
Hardcover.__index = Hardcover

function Hardcover:new(o)
  return setmetatable(o, self)
end

function Hardcover:showLinkBookDialog(force_search, link_callback)
  local search_value, books, err = self:findBookOptions(force_search)

  if err then
    logger.err(err)
    return
  end

  self.dialog_manager:buildSearchDialog(
    "Select book",
    books,
    {
      book_id = self.settings:getLinkedBookId()
    },
    function(book)
      self:linkBook(book)
      if link_callback then
        link_callback()
      end
    end,
    function(search)
      self.dialog_manager:updateSearchResults(search)
      return true
    end,
    search_value
  )
end

function Hardcover:showChangeEditionDialog(callback)
  local editions = Api:findEditions(self.settings:getLinkedBookId(), User:getId())
  self.dialog_manager:buildSearchDialog(
    "Select edition",
    editions,
    {
      book_id = self.settings:getLinkedBookId()
    },
    function(book)
      if book.book_id ~= self.settings:getLinkedBookId() then
        local success = Api:switchEdition(self.settings:getLinkedBookId(), book.book_id)
        if not success then
          self.dialog_manager:showError("Failed to switch edition on StoryGraph. Please try again.")
          return
        end
      end
      self:linkBook(book)
      if callback then
        callback(book)
      end
    end
  )
end

function Hardcover:updateCurrentBookStatus(status)
  self.cache:updateBookStatus(self.ui.document.file, status)
  if not self.state.book_status.id then
    self.dialog_manager:showError("Book status could not be updated")
  end
end

function Hardcover:linkBook(book)
  local filename = self.ui.document.file

  -- 1. Fetch remote status (API handles redirection and audio filtering internally)
  local status = Api:findUserBook(book.book_id) or {}
  
  -- 2. If the final resolved edition is Audio, fail the linking process
  if status.is_audio then
    logger.warn("StoryGraph: Cannot link to an Audio edition.")
    UIManager:show(InfoMessage:new{
      text = _("StoryGraph: Cannot link to an Audio edition. Please select a text-based edition.")
    })
    return false
  end

  -- 3. If findUserBook resolved to a different (non-audio) edition, use that ID instead
  if status.id and status.id ~= book.book_id then
    logger.info("StoryGraph: Redirecting link to your active edition: " .. status.id)
    book.book_id = status.id
    book.pages = status.book_num_of_pages or book.pages
  end

  local delete = {}
  local clear_keys = { "book_id", "edition_id", "edition_format", "pages", "title" }
  for _, key in ipairs(clear_keys) do
    if book[key] == nil then
      table.insert(delete, key)
    end
  end

  local new_settings = {
    book_id = book.book_id,
    edition_format = status.edition_format or Book:editionFormatName(book.edition_format, book.reading_format_id),
    pages = book.pages,
    title = book.title,
    _delete = delete
  }

  -- 3. Save link information
  self.settings:updateBookSetting(filename, new_settings)
  self.state.book_status = status

  -- 4. Auto-Add to Library if no status was found on ANY edition
  if not self.state.book_status.status_id then
    logger.info("StoryGraph: Book has no status on any edition, adding to Currently Reading automatically")
    self.state.book_status = Api:updateUserBook(book.book_id, HARDCOVER.STATUS.READING) or {}
  end

  return true
end

-- could be moved to book search model
function Hardcover:findBookOptions(force_search)
  local props = self.ui.document:getProps()
  local identifiers = Book:parseIdentifiers(props.identifiers)
  local user_id = User:getId()

  if not force_search then
    local book_lookup = Api:findBookByIdentifiers(identifiers, user_id)
    if book_lookup then
      return nil, { book_lookup }
    end
  end

  local title = props.title
  if not title or title == "" then
    local _dir, path = util.splitFilePathName(self.ui.document.file)
    local filename, _suffix = util.splitFileNameSuffix(path)

    title = filename:gsub("_", " ")
  end
  local result, err = Api:findBooks(title, props.authors, user_id)
  return title, result, err
end

function Hardcover:autolinkBook(book)
  if not book then
    return
  end

  local linked = self:linkBook(book)
  if linked then
    UIManager:show(Notification:new {
      text = _("Linked to: " .. book.title),
    })
  end
end

function Hardcover:linkBookByIsbn(identifiers)
  if identifiers.isbn_10 or identifiers.isbn_13 then
    local user_id = User:getId()
    local book_lookup = Api:findBookByIdentifiers({
      isbn_10 = identifiers.isbn_10,
      isbn_13 = identifiers.isbn_13
    },
      user_id
    )
    if book_lookup then
      self:autolinkBook(book_lookup)
      return true
    end
  end
end

function Hardcover:linkBookByHardcover(identifiers)
  if identifiers.book_slug then
    local user_id = User:getId()
    local book_lookup = Api:findBookByIdentifiers(
      { book_slug = identifiers.book_slug }, user_id)
    if book_lookup then
      self:autolinkBook(book_lookup)
      return true
    end
  end
end

function Hardcover:linkBookByTitle()
  local props = self.ui.document:getProps()

  local results = Api:findBooks(props.title, props.authors, User:getId())
  if results and #results > 0 then
    self:autolinkBook(results[1])
    return true
  end
end

function Hardcover:tryAutolink()
  if self.settings:bookLinked() then
    return
  end

  local props = self.ui.document:getProps()

  local identifiers = Book:parseIdentifiers(props.identifiers)
  if ((identifiers.isbn_10 or identifiers.isbn_13) and self.settings:readSetting(SETTING.LINK_BY_ISBN))
    or ((identifiers.book_slug or identifiers.edition_id) and self.settings:readSetting(SETTING.LINK_BY_HARDCOVER))
    or (props.title and self.settings:readSetting(SETTING.LINK_BY_TITLE)) then
    self.wifi:withWifi(function()
      self:_runAutolink(identifiers)
    end)
  end
end

function Hardcover:_runAutolink(identifiers)
  local linked = false
  if self.settings:readSetting(SETTING.LINK_BY_ISBN) then
    linked = self:linkBookByIsbn(identifiers)
  end

  if not linked and self.settings:readSetting(SETTING.LINK_BY_HARDCOVER) then
    linked = self:linkBookByHardcover(identifiers)
  end

  if not linked and self.settings:readSetting(SETTING.LINK_BY_TITLE) then
    self:linkBookByTitle()
  end
end

return Hardcover
