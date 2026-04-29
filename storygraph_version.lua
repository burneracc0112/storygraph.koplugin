local data = require('_meta')
local version = {}
for str in string.gmatch(data.version, "[^.]+") do
  table.insert(version, tonumber(str))
end
return version
