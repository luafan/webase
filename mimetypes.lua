
local map = {}

local function split(str, pat)
  local t = {}
  if str then
    local fpat = "(.-)" .. pat
    local last_end = 1
    local s, e, cap = str:find(fpat, 1)
    while s do
      if s ~= 1 or cap ~= "" then
        table.insert(t,cap)
      end
      last_end = e+1
      s, e, cap = str:find(fpat, last_end)
    end
    if last_end <= #str then
        cap = str:sub(last_end)
        table.insert(t, cap)
    end
  end
  return t
end

local f = io.open("mime.types", "r")
while true do
  local line = f:read("*line")
  if line then
    local result = line:match("([^;]+);")
    if result then
      local list = split(result, "[\r\n\t ]+")
      local out = {}
      for i,v in ipairs(list) do
        if #(v) > 0 then
          table.insert(out, v)
        end
      end
      
      --     video/mpeg                            mpeg mpg;
      for i=#(out),2,-1 do
        if out[i] == "txt" then
          map[out[i]] = string.format("%s; charset=utf-8", out[1])
        else
          map[out[i]] = out[1]
        end
      end
    end
  else
    break
  end
end
f:close()

return map
