local lpeg = require "lpeg"

local map = {}

function split(s, sep)
  sep = lpeg.P(sep)
  local elem = lpeg.C((1 - sep)^0)
  local p = lpeg.Ct(elem * (sep * elem)^0)
  return lpeg.match(p, s)
end

local f = io.open("mime.types", "r")
while true do
  local line = f:read("*line")
  if line then
    local result = line:match("([^;]+);")
    if result then
      local list = split(result, lpeg.S("\r\n\t "))
      local out = {}
      for i,v in ipairs(list) do
        if #(v) > 0 then
          table.insert(out, v)
        end
      end

      for i=#(out),2,-1 do
        map[out[i]] = out[1]
      end
    end
  else
    break
  end
end
f:close()

return map