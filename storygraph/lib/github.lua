local http = require("socket.http")
local json = require("json")
local ltn12 = require("ltn12")

local VERSION = require("storygraph_version")

local VERSION_URL = "https://raw.githubusercontent.com/burneracc0112/storygraph.koplugin/main/version.json"

local Github = {}

function Github:fetchVersionInfo()
  local responseBody = {}
  local res, code, responseHeaders = http.request {
    url = VERSION_URL,
    sink = ltn12.sink.table(responseBody),
  }

  if code == 200 then
    return json.decode(table.concat(responseBody), json.decode.simple)
  end
end

function Github:isNewer(version_str)
  local index = 1
  for str in string.gmatch(version_str, "([^.]+)") do
    local part = tonumber(str)
    if not part or not VERSION[index] then break end

    if part < VERSION[index] then
      return false
    elseif part > VERSION[index] then
      return true
    end
    index = index + 1
  end
  return false
end

return Github
