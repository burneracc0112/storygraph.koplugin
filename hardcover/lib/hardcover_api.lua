local config = require("hardcover_config")
local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local _t = require("hardcover/lib/table_util")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")
local socketutil = require("socketutil")
local htmlparser = require("htmlparser")

local Book = require("hardcover/lib/book")
local SETTING = require("hardcover/lib/constants/settings")
local VERSION = require("hardcover_version")

local base_url = "https://app.thestorygraph.com"

local HardcoverApi = {
  enabled = true,
  settings = nil, -- Injected by main.lua
}

-- Private helper to build headers with cookies
local function get_headers(self, custom_headers)
  local session = ""
  local remember = ""
  
  if self.settings then
    session = self.settings:readSetting(SETTING.SESSION_COOKIE)
    remember = self.settings:readSetting(SETTING.REMEMBER_TOKEN)
  end
  
  if not session or session == "" then session = config.session_cookie or "" end
  if not remember or remember == "" then remember = config.remember_user_token or "" end

  if session == "" then
    logger.warn("StoryGraph: No session cookie found!")
  else
    logger.info("StoryGraph: Using session cookie (length: " .. #session .. ")")
  end

  local headers = {
    ["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36",
    ["Cookie"] = "remember_user_token=" .. remember .. "; cookies_popup_seen=yes; plus_popup_seen=yes; _storygraph_session=" .. session,
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    ["Accept-Language"] = "en",
    ["Sec-Ch-Ua"] = '"Google Chrome";v="147", "Not.A/Brand";v="8", "Chromium";v="147"',
    ["Sec-Ch-Ua-Mobile"] = "?0",
    ["Sec-Ch-Ua-Platform"] = '"macOS"',
    ["Origin"] = "https://app.thestorygraph.com",
    ["DNT"] = "1",
    ["Sec-Fetch-Dest"] = "empty",
    ["Sec-Fetch-Mode"] = "cors",
    ["Sec-Fetch-Site"] = "same-origin",
  }
  if custom_headers then
    for k, v in pairs(custom_headers) do
      headers[k] = v
    end
  end
  return headers
end

-- Helper to decode HTML entities
local function decode_entities(str)
  local entities = {
    ["&amp;"] = "&",
    ["&lt;"] = "<",
    ["&gt;"] = ">",
    ["&quot;"] = "\"",
    ["&apos;"] = "'",
    ["&#39;"] = "'",
    ["&rsquo;"] = "'",
    ["&lsquo;"] = "'",
    ["&ldquo;"] = "\"",
    ["&rdquo;"] = "\"",
    ["&ndash;"] = "-",
    ["&mdash;"] = "--",
  }
  return str:gsub("(&%w+;)", entities):gsub("(&#%d+;)", function(n)
    local code = n:match("%d+")
    return string.char(tonumber(code))
  end)
end

-- Helper to extract text from a node manually
local function get_node_text(node)
  if not node then return "" end
  if type(node) == "string" then return node end
  
  if type(node) == "table" then
    -- Try the built-in methods of KOReader's htmlparser ElementNode
    if type(node.textonly) == "function" then
      local t = node:textonly()
      if type(t) == "string" then return t end
    elseif type(node.getcontent) == "function" then
      local t = node:getcontent()
      if type(t) == "string" then return t:gsub("<[^>]+>", "") end
    elseif type(node.gettext) == "function" then
      local t = node:gettext()
      if type(t) == "string" then return t:gsub("<[^>]+>", "") end
    end
    
    local text = ""
    -- Try array part
    if #node > 0 then
      for i = 1, #node do
        local child_text = get_node_text(node[i])
        if type(child_text) == "string" then
          text = text .. child_text
        end
      end
    elseif node.nodes then
      -- Try .nodes property
      for _, child in ipairs(node.nodes) do
        local child_text = get_node_text(child)
        if type(child_text) == "string" then
          text = text .. child_text
        end
      end
    end

    if text ~= "" then return text end

    -- Fallbacks if still empty
    if type(node.text) == "string" then
      return node.text
    else
      local s = tostring(node)
      -- Only use tostring if it doesn't return a raw table pointer
      if type(s) == "string" and not s:match("^table:") then
        return s:gsub("<[^>]+>", "")
      end
    end
  end
  
  return ""
end

-- URL encoding helper
local function urlencode(str)
  if str then
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w %-%_%.%~])", function(c)
      return ("%%%02X"):format(string.byte(c))
    end)
    str = str:gsub(" ", "+")
  end
  return str
end

-- Helper to extract authenticity token from HTML
function HardcoverApi:extract_csrf(html)
  if not html then return nil end
  -- Match meta tags with varying attribute order and quotes
  local csrf = html:match('meta%s+name=["\']csrf%-token["\']%s+content=["\']([^"\']+)["\']')
  if not csrf then
    csrf = html:match('meta%s+content=["\']([^"\']+)["\']%s+name=["\']csrf%-token["\']')
  end
  -- Fallback to authenticity_token input
  if not csrf then
    csrf = html:match('name=["\']authenticity_token["\']%s+value=["\']([^"\']+)["\']')
  end
  if not csrf then
    csrf = html:match('value=["\']([^"\']+)["\']%s+name=["\']authenticity_token["\']')
  end
  return csrf
end

function HardcoverApi:request(url, method, data, custom_headers)
  if not NetworkManager:isConnected() or not self.enabled then
    return nil, "Network not connected"
  end

  local completed, content = Trapper:dismissableRunInSubprocess(function()
    local maxtime = 15
    local timeout = 10
    local sink = {}
    socketutil:set_timeout(timeout, maxtime)
    
    local body = nil
    if data then
      if type(data) == "table" then
        local parts = {}
        for k, v in pairs(data) do
          if type(v) == "table" then
            for _, val in ipairs(v) do
              table.insert(parts, urlencode(k) .. "=" .. urlencode(tostring(val)))
            end
          else
            table.insert(parts, urlencode(k) .. "=" .. urlencode(tostring(v)))
          end
        end
        body = table.concat(parts, "&")
      else
        body = data
      end
    end

    local headers = get_headers(self, custom_headers)
    if headers["Cookie"] then
      logger.info("StoryGraph: Final Cookie length: " .. #headers["Cookie"])
    end

    if method == "POST" and body then
      if not headers["Content-Type"] then
        headers["Content-Type"] = "application/x-www-form-urlencoded"
      end
      headers["Content-Length"] = tostring(#body)
    end

    local request = {
      url = url,
      method = method or "GET",
      headers = headers,
      source = body and ltn12.source.string(body) or nil,
      sink = socketutil.table_sink(sink),
    }

    if method == "POST" then
      logger.info("StoryGraph: POST URL: " .. url)
      logger.info("StoryGraph: POST Body: " .. (body or "nil"))
    end

    local _, code, _headers, _status = http.request(request)
    socketutil:reset_timeout()
    
    local response_body = table.concat(sink)
    -- Encode headers as a string to pass back through the Trapper
    local header_str = ""
    if _headers then
      for k, v in pairs(_headers) do
        header_str = header_str .. k .. "=" .. tostring(v) .. "\n"
      end
    end
    return (code or "error") .. "|" .. header_str .. "|" .. response_body
  end, true, true)

  if completed and content then
    local code, header_str, response = string.match(content, "^([^|]*)|([^|]*)|(.*)")
    local headers = {}
    if header_str then
      for line in header_str:gmatch("[^\r\n]+") do
        local k, v = line:match("([^=]*)=(.*)")
        if k then headers[k:lower()] = v end
      end
    end
    local code_num = tonumber(code)
    if code_num and headers["set-cookie"] then
      local session_val = headers["set-cookie"]:match("_storygraph_session=([^;]+)")
      if session_val and self.settings then
        logger.info("StoryGraph: Automatically saving refreshed session from response")
        self.settings:updateSetting(SETTING.SESSION_COOKIE, session_val)
      end
    end
    return code_num, response, headers
  end
  return nil, "Request failed"
end

function HardcoverApi:me()
  -- If we can't find a user ID, we'll return a generic one to satisfy the plugin
  return { id = "storygraph_user" }
end

function HardcoverApi:findBooks(title, author, userId)
  local search_url = base_url .. "/browse?search_term=" .. urlencode(title .. " " .. (author or ""))
  local code, html = self:request(search_url, "GET")
  
  if code ~= 200 then
    logger.warn("StoryGraph search failed. Code:", code, "Response start:", html:sub(1, 200))
    return {}, "Search failed with code " .. (code or "unknown")
  end

  local root = htmlparser.parse(html, 10000)
  local book_elements = root:select(".book-title-author-and-series")
  local results = {}
  local seen_books = {}

  for _, el in ipairs(book_elements) do
    local title_el = el:select("a[href^='/books/']")[1]
    local author_el = el:select("a[href^='/authors/']")[1]
    
    if title_el then
      local book_id = title_el.attributes.href:match("/books/([^/%?]+)")
      
      if not seen_books[book_id] then
        seen_books[book_id] = true
        
        local raw_title = get_node_text(title_el)
        local title_text = decode_entities(raw_title):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        
        local author_text = "Unknown Author"
        if author_el then
          local raw_author = get_node_text(author_el)
          author_text = decode_entities(raw_author):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        end
        
        logger.warn("StoryGraph found book:", book_id, "| Title:", title_text, "| Author:", author_text)
      
      -- Cover image
      local cover_el = el.parent and el.parent.parent and el.parent.parent:select("img")[1]
      local cover_url = cover_el and cover_el.attributes.src
      
      -- Page count
      local page_count = 0
      local info_el = el.parent and el.parent:select("p[class*='text-xs']")[1]
      if info_el then
        local info_text = get_node_text(info_el)
        local pages = info_text:match("(%d+) pages")
        if pages then
          page_count = tonumber(pages)
        end
      end
      
      table.insert(results, {
        book_id = book_id,
        title = title_text,
        -- Mocking StoryGraph structure
        contributions = { { author = { name = author_text } } },
        cached_image = { url = cover_url },
        book_series = {},
        description = "",
        page_count = page_count,
        pages = page_count, -- Sometimes used interchangeably
        release_date = ""
      })
      end
    end
  end

  return results
end

function HardcoverApi:findUserBook(book_id, user_id)
  if not book_id then return {} end
  local book_url = base_url .. "/books/" .. book_id
  local code, html = self:request(book_url, "GET")
  
  if code ~= 200 then
    return {}, "Failed to fetch book"
  end

  local root = htmlparser.parse(html, 10000)
  
  -- Check for current status
  local status_btn = root:select(".read-status-label")[1]
  local status_text = ""
  if status_btn then
    status_text = decode_entities(get_node_text(status_btn)):lower()
  end
  
  local status_id = nil
  if status_text:find("currently reading") or status_text:find("rereading") then status_id = 2
  elseif status_text:find("to%-read") or status_text:find("to read") then status_id = 1
  elseif status_text:find("paused") then status_id = 4
  elseif status_text:find("did not finish") then status_id = 5
  elseif status_text == "read" or status_text:find("^read$") or status_text:find(" read$") then status_id = 3
  end

  -- Progress
  local progress_pane = root:select(".progress-tracker-pane")[1]
  local last_reached_percent = 0
  local book_num_of_pages = 0
  local progress_type = "percentage"
  
  if progress_pane then
    local total_pages_input = progress_pane:select(".read-status-book-num-of-pages")[1]
    local type_select = progress_pane:select(".read-status-progress-type")[1]


    if total_pages_input then book_num_of_pages = tonumber(total_pages_input.attributes.value) or 0 end
    if type_select then
      local selected = type_select:select("option[selected='selected']")[1]
      if selected then progress_type = selected.attributes.value end
    end

    local bar_pct = html:match("edit%-progress[^>]*>%s*<div[^>]*style=\"width:%s*(%d+)%%\"")
    if bar_pct then
      last_reached_percent = tonumber(bar_pct)
      logger.info("StoryGraph: progress from bar = " .. last_reached_percent .. "%")
    else
      local percent_input = progress_pane:select(".read-status-last-reached-percent")[1]
      if percent_input then
        last_reached_percent = tonumber(percent_input.attributes.value) or 0
        logger.info("StoryGraph: progress from hidden input = " .. last_reached_percent .. "%")
      end
    end

    if last_reached_percent == 0 then
      local progress_text = get_node_text(progress_pane)
      local pages = progress_text:match("(%d+)%%")
      if pages then
        last_reached_percent = tonumber(pages)
        logger.info("StoryGraph: progress from text scan = " .. last_reached_percent .. "%")
      end
    end
  end

  local res = {
    id = book_id,
    book_id = book_id,
    status_id = status_id,
    book_num_of_pages = book_num_of_pages,
    page_count = book_num_of_pages,
    last_reached_percent = last_reached_percent,
    progress_type = progress_type,
    user_book_reads = {
      {
        id = book_id .. "_read",
        progress_pages = progress_pages,
        started_at = os.date("%Y-%m-%d"),
      }
    },
    is_owned = root:select(".remove-from-owned-link")[1] ~= nil,
    is_favorite = root:select(".remove-from-favorites-link")[1] ~= nil,
    can_review = false,
    review_url = nil
  }

  local links = root:select("a")
  for _, link in ipairs(links) do
    local text = get_node_text(link):lower()
    local href = link.attributes.href or ""
    if text:match("see review") or text:match("add a review") or text:match("add review") then
      res.can_review = true
      res.review_url = href
      break
    end
  end

  return res
end

function HardcoverApi:getReview(review_url)
  if not review_url then return nil end
  if not review_url:match("^http") then
    review_url = base_url .. review_url
  end

  local _, html = self:request(review_url, "GET")
  if not html then return nil end

  local root = htmlparser.parse(html, 10000)
  local review = {
    stars = 0,
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

  -- Rating
  local rating_node = root:select(".font-semibold.text-darkerGrey")[1]
  if rating_node then
    review.stars = tonumber(get_node_text(rating_node)) or 0
  end

  -- Moods and Pace
  local moods_div = root:select(".moods-list-reviews")[1]
  if moods_div then
    local moods_list = {
      "adventurous", "challenging", "dark", "emotional", "funny", "hopeful",
      "informative", "inspiring", "lighthearted", "mysterious", "reflective",
      "relaxing", "sad", "tense"
    }
    local spans = moods_div:select("span")
    for _, span in ipairs(spans) do
      local val = get_node_text(span):lower():gsub("%s+", ""):gsub("-", "")
      -- Check moods
      for i, m in ipairs(moods_list) do
        if m == val then
          table.insert(review.mood_ids, i)
        end
      end
      -- Check pace
      if val:match("paced$") then
        review.pace = val:gsub("paced$", "")
      end
    end
  end

  -- Qualitative questions
  local questions = root:select(".review-character-questions-list div")
  local q_map = {
    ["pace:"] = "pace",
    ["storyfocus:"] = "driven",
    ["story-focus:"] = "driven",
    ["plotorcharacterdriven:"] = "driven",
    ["strongcharacterdevelopment:"] = "development",
    ["loveablecharacters:"] = "loveable",
    ["diversecharacters:"] = "diverse",
    ["flawsofcharactersamainfocus:"] = "flaws",
  }
  for _, q_div in ipairs(questions) do
    local spans = q_div:select("span")
    if #spans >= 2 then
      local q_text = get_node_text(spans[1]):lower():gsub("%s+", "")
      local a_text = get_node_text(spans[2]):lower():gsub("^%s+", ""):gsub("%s+$", "")
      local key = q_map[q_text]
      if key then
        if a_text == "n/a" then
          review[key] = "n/a"
        elseif a_text == "complicated" then
          review[key] = "it's complicated"
        elseif key == "driven" then
          review[key] = a_text:gsub("[%- ]?driven", "")
        else
          review[key] = a_text
        end
      end
    end
  end

  -- Thoughts
  local thoughts_div = root:select(".review-explanation")[1]
  if thoughts_div then
    review.thoughts = get_node_text(thoughts_div):gsub("^%s+", ""):gsub("%s+$", "")
  end

  return review
end

function HardcoverApi:updateUserBook(book_id, status_id, edition_id)
  local status_map = {
    [1] = "to-read",
    [2] = "currently-reading",
    [3] = "read",
    [4] = "paused",
    [5] = "did-not-finish"
  }
  local status_str = status_map[status_id] or "currently-reading"
  
  local book_url = base_url .. "/books/" .. book_id
  local _, html, get_resp_headers = self:request(book_url, "GET")
  
  -- Handle session refresh from GET
  local current_session = self.settings:readSetting(SETTING.SESSION_COOKIE)
  local new_cookie = get_resp_headers and get_resp_headers["set-cookie"]
  if new_cookie then
    local session_val = new_cookie:match("_storygraph_session=([^;]+)")
    if session_val then
      logger.info("StoryGraph: Refreshed session from GET")
      current_session = session_val
    end
  end

  local csrf = self:extract_csrf(html)
  
  if not csrf then
    logger.warn("StoryGraph: Could not extract CSRF token for status update")
  else
    logger.info("StoryGraph: Extracted CSRF token (length: " .. #csrf .. ")")
  end

  local custom_headers = {
    ["X-CSRF-Token"] = csrf,
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Accept"] = "text/javascript, application/javascript, application/ecmascript, application/x-ecmascript, */*; q=0.01",
    ["Referer"] = book_url
  }
  if current_session then
    local remember = self.settings:readSetting(SETTING.REMEMBER_TOKEN)
    custom_headers["Cookie"] = "remember_user_token=" .. (remember or "") .. "; cookies_popup_seen=yes; plus_popup_seen=yes; _storygraph_session=" .. current_session
  end

  local update_url = base_url .. "/update-status.js?book_id=" .. book_id .. "&status=" .. status_str
  logger.info("StoryGraph: Updating status to " .. status_str .. " for book " .. book_id)
  
  local code, resp, resp_headers = self:request(update_url, "POST", {
    authenticity_token = csrf
  }, custom_headers)
  
  -- If currently-reading fails, try rereading
  if status_str == "currently-reading" and (code == 302 or code == 422) then
    local loc = resp_headers and resp_headers["location"] or ""
    if loc:match("/users/sign_in") or code == 422 then
      logger.info("StoryGraph: currently-reading failed, trying rereading...")
      update_url = base_url .. "/update-status.js?book_id=" .. book_id .. "&status=rereading"
      code, resp, resp_headers = self:request(update_url, "POST", {
        authenticity_token = csrf
      }, custom_headers)
    end
  end
  
  logger.info("StoryGraph: Status update response code: " .. (code or "nil"))
  if code == 302 and resp_headers and resp_headers["location"] then
    logger.info("StoryGraph: Redirected to: " .. resp_headers["location"])
  end
  
  -- Consider 2xx or 302 (redirect back to book) as potential success
  if code and (code >= 200 and code < 300 or code == 302) then
    return self:findUserBook(book_id)
  end
  return nil
end

function HardcoverApi:updatePage(user_read_id, edition_id, value, started_at, update_type)
  local book_id = user_read_id:gsub("_read", "")
  
  local book_url = base_url .. "/books/" .. book_id
  local _, html, get_resp_headers = self:request(book_url, "GET")
  
  -- Handle session refresh from GET
  local current_session = self.settings:readSetting(SETTING.SESSION_COOKIE)
  local new_cookie = get_resp_headers and get_resp_headers["set-cookie"]
  if new_cookie then
    local session_val = new_cookie:match("_storygraph_session=([^;]+)")
    if session_val then
      logger.info("StoryGraph: Refreshed session from GET")
      current_session = session_val
    end
  end

  local csrf = self:extract_csrf(html)
  
  if not csrf then
    logger.warn("StoryGraph: Could not extract CSRF token for progress update")
  end

  local book_num_of_pages = html:match('class="read%-status%-book%-num%-of%-pages"%s+[^>]*value="([^"]+)"') or "0"

  local update_url = base_url .. "/update-progress"
  update_type = update_type or "percentage"
  logger.info("StoryGraph: Updating progress (" .. update_type .. ") to " .. value .. " for book " .. book_id)

  local custom_headers = {
    ["X-CSRF-Token"] = csrf,
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Accept"] = "text/javascript, application/javascript, application/ecmascript, application/x-ecmascript, */*; q=0.01",
    ["Referer"] = book_url
  }
  if current_session then
    local remember = self.settings:readSetting(SETTING.REMEMBER_TOKEN)
    custom_headers["Cookie"] = "remember_user_token=" .. (remember or "") .. "; cookies_popup_seen=yes; plus_popup_seen=yes; _storygraph_session=" .. current_session
  end

  local code, resp, resp_headers = self:request(update_url, "POST", {
    ["read_status[progress_number]"] = value,
    ["read_status[progress_type]"] = update_type,
    ["read_status[book_num_of_pages]"] = book_num_of_pages,
    ["book_id"] = book_id,
    ["on_book_page"] = "true",
    ["authenticity_token"] = csrf
  }, custom_headers)
  
  logger.info("StoryGraph: Progress update response code: " .. (code or "nil"))
  if code == 302 and resp_headers and resp_headers["location"] then
    logger.info("StoryGraph: Redirected to: " .. resp_headers["location"])
  end

  if code and (code >= 200 and code < 300 or code == 302) then
    return self:findUserBook(book_id)
  end
  return nil
end

function HardcoverApi:createRead(book_id, edition_id, value, started_at, update_type)
  -- For StoryGraph, creating a read record is often just updating progress for the first time
  return self:updatePage(book_id .. "_read", edition_id, value, started_at, update_type)
end

function HardcoverApi:createJournalEntry(data)
  local book_id = data.book_id
  local book_url = base_url .. "/books/" .. book_id
  local _, html = self:request(book_url, "GET")
  local csrf = self:extract_csrf(html)
  
  if not csrf then
    logger.warn("StoryGraph: Could not extract CSRF token for journal entry")
    return nil
  end

  -- Extract current progress values to send back (required by StoryGraph)
  local last_reached_pages = html:match('class="read%-status%-last%-reached%-pages"%s+[^>]*value="([^"]+)"') or "0"
  local book_num_of_pages = html:match('class="read%-status%-book%-num%-of%-pages"%s+[^>]*value="([^"]+)"') or "0"
  local last_reached_percent = html:match('class="read%-status%-last%-reached%-percent"%s+[^>]*value="([^"]+)"') or "0"

  local update_url = base_url .. "/update-progress-with-note"
  logger.info("StoryGraph: Creating journal entry for book " .. book_id)

  local date = data.date or os.date("*t")
  local post_data = {
    ["authenticity_token"] = csrf,
    ["progress_update_date[day]"] = date.day,
    ["progress_update_date[month]"] = date.month,
    ["progress_update_date[year]"] = date.year,
    ["progress_minutes"] = "",
    ["progress_number"] = data.progress or "0",
    ["progress_type"] = data.progress_type or "percentage",
    ["last_reached_pages"] = last_reached_pages,
    ["book_num_of_pages"] = book_num_of_pages,
    ["last_reached_percent"] = last_reached_percent,
    ["note"] = data.entry or "",
    ["book_id"] = book_id,
    ["return_to"] = "",
    ["button"] = ""
  }

  local code, resp = self:request(update_url, "POST", post_data, {
    ["X-CSRF-Token"] = csrf,
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Accept"] = "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"
  })

  logger.info("StoryGraph: Journal entry response code: " .. (code or "nil"))
  
  if code and (code >= 200 and code < 300 or code == 302) then
    return self:findUserBook(book_id)
  end
  return nil
end

-- Stubs
function HardcoverApi:removeRead(user_book_id)
  local book_id = user_book_id:gsub("_read", "")
  local book_url = base_url .. "/books/" .. book_id
  
  -- Need CSRF for removal
  local _, html = self:request(book_url, "GET")
  local csrf = self:extract_csrf(html)
  
  local remove_url = base_url .. "/remove-book/" .. book_id .. "?remove_tags=true"
  logger.info("StoryGraph: Removing book " .. book_id)
  
  local custom_headers = {
    ["X-CSRF-Token"] = csrf,
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Accept"] = "text/javascript",
    ["Referer"] = book_url,
    -- Important: the curl showed content-length 0 for this POST
    ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
  }
  
  local code, resp = self:request(remove_url, "POST", "", custom_headers)
  if code == 200 or code == 302 then
    return { id = book_id }
  end
  return nil
end
function HardcoverApi:setOwned(book_id, owned)
  local book_url = base_url .. "/books/" .. book_id
  
  -- Need CSRF for owned status update
  local _, html = self:request(book_url, "GET")
  local csrf = self:extract_csrf(html)
  
  local action = owned and "mark-as-owned" or "remove-owned-book"
  local url = base_url .. "/" .. action .. "?book_id=" .. book_id
  
  logger.info("StoryGraph: Setting owned to " .. tostring(owned) .. " for book " .. book_id)
  
  local custom_headers = {
    ["X-CSRF-Token"] = csrf,
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Accept"] = "text/javascript",
    ["Referer"] = book_url
  }
  
  local method = owned and "POST" or "DELETE"
  local code, resp = self:request(url, method, "", custom_headers)
  return code == 200 or code == 302
end
function HardcoverApi:setFavorite(book_id, favorite)
  local book_url = base_url .. "/books/" .. book_id
  
  -- Need CSRF for favorite status update
  local _, html = self:request(book_url, "GET")
  local csrf = self:extract_csrf(html)
  
  local action = favorite and "add" or "remove"
  local url = base_url .. "/favorites/" .. action .. "/" .. book_id .. "?from_book_page=true"
  
  logger.info("StoryGraph: Setting favorite to " .. tostring(favorite) .. " for book " .. book_id)
  
  local custom_headers = {
    ["X-CSRF-Token"] = csrf,
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Accept"] = "text/javascript",
    ["Referer"] = book_url
  }
  
  local method = favorite and "POST" or "DELETE"
  local code, resp = self:request(url, method, "", custom_headers)
  return code == 200 or code == 302
end
function HardcoverApi:updateRating(user_book_id, rating) return nil end
function HardcoverApi:findBookByIdentifiers(identifiers, user_id)
  local isbn = identifiers and (identifiers.isbn_13 or identifiers.isbn_10)
  if not isbn then return nil end
  
  local results, err = self:findBooks(isbn, nil, user_id)
  if results and #results > 0 then
    return results[1]
  end
  return nil
end
function HardcoverApi:findDefaultEdition(book_id, user_id) return { id = book_id, edition_format = "StoryGraph", pages = 100 } end
function HardcoverApi:findEditions(book_id, user_id)
  local url = base_url .. "/books/" .. book_id .. "/editions"
  local code, html = self:request(url, "GET")
  if code ~= 200 or not html then
    return {}
  end

  local htmlparser = require("htmlparser")
  local get_node_text = function(node)
    if not node then return "" end
    if type(node) == "string" then return node end
    
    if type(node) == "table" then
      if type(node.textonly) == "function" then
        local t = node:textonly()
        if type(t) == "string" then return t end
      end
      
      local text = ""
      if node.nodes then
        for _, child in ipairs(node.nodes) do
          local child_text = get_node_text(child)
          if type(child_text) == "string" then
            text = text .. child_text
          end
        end
      end

      if text ~= "" then return text end
      if type(node.text) == "string" then return node.text end
    end
    return ""
  end

  -- htmlparser has an issue parsing DOCTYPE sometimes, so we clip it
  local html_start = html:find("<!DOCTYPE html>")
  if html_start then html = html:sub(html_start) end

  local root = htmlparser.parse(html, 100000)
  local panes = root:select(".book-pane")
  local editions = {}

  for _, pane in ipairs(panes) do
    local id = pane.attributes["data-book-id"]
    if id then
      local title_node = pane:select(".book-title-author-and-series h3 a")
      local title = title_node and title_node[1] and get_node_text(title_node[1]) or ""
      if decode_entities then
        title = decode_entities(title)
      end
      
      local edition_info = pane:select(".edition-info p")
      local isbn, format, pages = "", "", nil
      local language, pub_year, pub_date, publisher = "", "", "", ""
      
      for _, p in ipairs(edition_info) do
        local t = get_node_text(p)
        if t:match("ISBN/UID:") then isbn = t:gsub(".*ISBN/UID:%s*", ""):gsub("^%s*(.-)%s*$", "%1") end
        if t:match("Format:") then format = t:gsub(".*Format:%s*", ""):gsub("^%s*(.-)%s*$", "%1") end
        if t:match("Language:") then language = t:gsub(".*Language:%s*", ""):gsub("^%s*(.-)%s*$", "%1") end
        if t:match("Original Pub Year:") then pub_year = t:gsub(".*Original Pub Year:%s*", ""):gsub("^%s*(.-)%s*$", "%1") end
        if t:match("Edition Pub Date:") then pub_date = t:gsub(".*Edition Pub Date:%s*", ""):gsub("^%s*(.-)%s*$", "%1") end
        if t:match("Publisher:") then publisher = t:gsub(".*Publisher:%s*", ""):gsub("^%s*(.-)%s*$", "%1") end
      end
      
      local cover_url = ""
      local img_node = pane:select(".book-cover img")
      if #img_node > 0 then
        cover_url = img_node[1].attributes["src"] or ""
      end

      local p_nodes = pane:select("p.text-xs.font-light")
      local edition_duration = nil
      if #p_nodes > 0 then
        local t = get_node_text(p_nodes[1])
        local pgs = t:match("(%d+)%s*pages")
        if pgs then pages = tonumber(pgs) end
        local dur_h = t:match("(%d+h)")
        local dur_m = t:match("(%d+m)")
        if dur_h or dur_m then
          edition_duration = (dur_h or "") .. (dur_h and dur_m and " " or "") .. (dur_m or "")
        end
      end

      table.insert(editions, {
        book_id = id,
        edition_id = id,
        title = title:gsub("^%s*(.-)%s*$", "%1"),
        edition_format = format,
        pages = pages,
        duration = edition_duration,
        isbn = isbn,
        edition_language = language,
        pub_year = pub_year,
        pub_date = pub_date,
        publisher = publisher,
        cached_image = { url = cover_url },
        contributions = {}, -- keep it empty, the UI can still display title
      })
    end
  end

  return editions
end

function HardcoverApi:switchEdition(from_book_id, to_book_id)
  local url = base_url .. "/books/" .. from_book_id .. "/editions"
  local code, html, get_headers = self:request(url, "GET")
  if code ~= 200 or not html then
    return false
  end
  logger.warn("StoryGraph HTML start: ", html:sub(1, 100))

  -- Update session cookie if server sent a new one
  local new_cookie = get_headers and get_headers["set-cookie"]
  local current_session = self.settings:readSetting(SETTING.SESSION_COOKIE)
  if new_cookie then
    local session_val = new_cookie:match("_storygraph_session=([^;]+)")
    if session_val then
      current_session = session_val
    end
  end

  local htmlparser = require("htmlparser")
  local html_start = html:find("<!DOCTYPE html>")
  if html_start then html = html:sub(html_start) end
  local root = htmlparser.parse(html, 200000)
  
  local csrf = self:extract_csrf(html)
  if not csrf then
    logger.warn("StoryGraph: Failed to extract CSRF token!")
    return false
  end

  local true_from_id = from_book_id
  local form_auth_token = csrf

  local forms = root:select("form[action='/switch-editions']")
  for _, f in ipairs(forms) do
    local to_id_input = f:select("input[name='to_book_id']")
    if to_id_input and #to_id_input > 0 and to_id_input[1].attributes.value == to_book_id then
      local from_id_input = f:select("input[name='from_book_id']")
      if from_id_input and #from_id_input > 0 then
        true_from_id = from_id_input[1].attributes.value or from_book_id
      end
      local auth_inputs = f:select("input[name='authenticity_token']")
      if auth_inputs and #auth_inputs > 0 then
        form_auth_token = auth_inputs[1].attributes.value or csrf
      end
      break
    end
  end

  logger.warn("StoryGraph switchEdition IDs: from=", true_from_id, " to=", to_book_id, " csrf=", csrf)

  local switch_url = base_url .. "/switch-editions"
  local data = {
    ["authenticity_token"] = form_auth_token,
    ["from_book_id"] = true_from_id,
    ["to_book_id"] = to_book_id,
    ["button"] = ""
  }

  -- Use updated session if found
  local custom_headers = {
    ["X-CSRF-Token"] = csrf,
    ["Accept"] = "text/vnd.turbo-stream.html, text/html, application/xhtml+xml",
    ["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8",
    ["Origin"] = "https://app.thestorygraph.com",
    ["Referer"] = url
  }
  if current_session then
    local remember = self.settings:readSetting(SETTING.REMEMBER_TOKEN)
    custom_headers["Cookie"] = T("_storygraph_session=%1; remember_user_token=%2; cookies_popup_seen=yes; plus_popup_seen=yes", current_session, remember)
  end

  local post_code, response, post_headers = self:request(switch_url, "POST", data, custom_headers)

  logger.warn("StoryGraph switchEdition result: ", post_code, " Location: ", post_headers and post_headers["location"])

  if post_code == 302 or post_code == 303 then
    local loc = post_headers and post_headers["location"] or ""
    if loc:match("/users/sign_in") then
      logger.warn("StoryGraph: Redirected to sign_in! Session likely invalid.")
      return false
    end
    return true
  end

  return post_code == 200
end

function HardcoverApi:saveReview(book_id, review_data, review_url)
  local url = review_url
  if not url then
    url = base_url .. "/reviews/new?book_id=" .. book_id
  else
    if not url:match("/edit$") then
      url = url .. "/edit"
    end
    if not url:match("^http") then
      url = base_url .. url
    end
  end
  local _, html, headers = self:request(url, "GET")
  local csrf = self:extract_csrf(html)
  
  -- Handle session refresh
  local current_session = self.settings:readSetting(SETTING.SESSION_COOKIE)
  local new_cookie = headers and headers["set-cookie"]
  if new_cookie then
    local session_val = new_cookie:match("_storygraph_session=([^;]+)")
    if session_val then current_session = session_val end
  end

  local stars = tonumber(review_data.stars) or 0
  local stars_total = math.floor(stars * 100 + 0.5)
  local stars_integer = math.floor(stars_total / 100)
  local stars_decimal = stars_total % 100

  local function empty_if_na(val)
    if not val or val == "n/a" then return "" end
    return val
  end

  local function capitalize_if_not_empty(val)
    if not val or val == "" then return "" end
    return val:gsub("^%l", string.upper)
  end

  local data = {
    ["authenticity_token"] = csrf,
    ["stars_integer"] = tostring(stars_integer),
    ["stars_decimal"] = stars_decimal == 0 and "" or tostring(stars_decimal),
    ["review[explanation]"] = review_data.thoughts and ("<div>" .. review_data.thoughts .. "</div>") or "",
    ["review[pace]"] = empty_if_na(review_data.pace),
    ["review[character_or_plot_driven]"] = capitalize_if_not_empty(empty_if_na(review_data.driven)),
    ["review[strong_character_development]"] = capitalize_if_not_empty(empty_if_na(review_data.development)),
    ["review[loveable_characters]"] = capitalize_if_not_empty(empty_if_na(review_data.loveable)),
    ["review[diverse_characters]"] = capitalize_if_not_empty(empty_if_na(review_data.diverse)),
    ["review[flawed_characters]"] = capitalize_if_not_empty(empty_if_na(review_data.flaws)),
    ["review[themes]"] = review_data.themes or "",
    ["review[book_id]"] = book_id,
    ["return_to"] = "/books/" .. book_id,
    ["button"] = ""
  }

  -- Moods
  if review_data.mood_ids and #review_data.mood_ids > 0 then
    data["review[mood_ids][]"] = review_data.mood_ids
  else
    data["review[mood_ids][]"] = {""}
  end

  local post_url = base_url .. "/reviews"
  local is_update = review_url and not review_url:match("/new")
  
  if is_update then
    post_url = review_url
    if not post_url:match("^http") then
      post_url = base_url .. post_url
    end
    data["_method"] = "patch"
  end
  local custom_headers = {
    ["X-CSRF-Token"] = csrf,
    ["Accept"] = "text/vnd.turbo-stream.html, text/html, application/xhtml+xml",
    ["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8",
    ["Origin"] = "https://app.thestorygraph.com",
    ["Referer"] = url
  }
  
  if current_session then
    local remember = self.settings:readSetting(SETTING.REMEMBER_TOKEN)
    custom_headers["Cookie"] = T("_storygraph_session=%1; remember_user_token=%2; cookies_popup_seen=yes; plus_popup_seen=yes", current_session, remember)
  end

  local code, resp = self:request(post_url, "POST", data, custom_headers)
  logger.info("StoryGraph: Save review response code: " .. (code or "nil"))
  return code == 200 or code == 302 or code == 303
end

return HardcoverApi
