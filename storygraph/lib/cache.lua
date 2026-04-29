local Api = require("storygraph/lib/hardcover_api")
local User = require("storygraph/lib/user")

local Cache = {}
Cache.__index = Cache

function Cache:new(o)
  return setmetatable(o, self)
end

function Cache:updateBookStatus(filename, status)
  local settings = self.settings:readBookSettings(filename)
  local book_id = settings.book_id
  self.state.book_status = Api:updateUserBook(book_id, status) or {}
end

function Cache:cacheUserBook()
  local filename = self.ui.document.file
  local status, errors = Api:findUserBook(self.settings:getLinkedBookId(), User:getId())
  self.state.book_status = status or {}

  if status and status.page_count and status.page_count > 0 then
    local current_pages = self.settings:readBookSetting(filename, "pages")
    if not current_pages or current_pages == 0 then
      self.settings:updateBookSetting(filename, { pages = status.page_count })
    end
  end

  return errors
end

return Cache
