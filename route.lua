local stream = require "fan.stream"
local print = print
local pcall = pcall
local require = require
local json = require "cjson"
local string = string

local lfs = require "lfs"

local route_map = {
}

local pattern_map = {
}

local function load_path(path)
  local attr = lfs.attributes(path)
  if attr and attr.mode == "directory" then
    for name in lfs.dir(path) do
      if name:match("^[^.].*[.]lua$") then
        load_path(string.format("%s/%s", path, name))
      end
    end
  else
    local m = setmetatable({}, { __index = _G })
    local ret = loadfile(path, "t", m)()
    if ret then
      for k,v in pairs(ret) do
        m[k] = v
      end
    end

    local route = m.route or "/" .. path:match("([^/]*)[.]lua$")
    local pattern = m.pattern
    if route or pattern then
      local t = {}
      if route then
        route_map[route] = t
      end
      if pattern then
        pattern_map[pattern] = t
      end

      for k,v in pairs(m) do
        if string.find(k:lower(), "on", 1, true) == 1 then
          t[k:sub(3):upper()] = v
        end
      end
    end
  end
end

load_path("handle")

return {
  web = function(req, resp)
    local map = route_map[req.path]
    if not map then
      for k,v in pairs(pattern_map) do
        if req.path:find(k) then
          map = v
          break
        end
      end
    end

    if map then
      local method = req.method
      local m = map[method]
      if m then
        local st,msg = pcall(m, req, resp)

        if st == false then
          print("[route]", msg)
          local exception = json.encode{exception=msg}
          resp:reply(500, "OK", exception)
        end

        return true
      end
    end
  end,
}
