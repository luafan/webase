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

local function load_path(path, parent_path)
  for name in lfs.dir(path) do
    if name:sub(1,1) ~= "." then
      local filepath = path .. "/" .. name
      local attr = lfs.attributes(filepath)

      if attr and attr.mode == "directory" then
        load_path(filepath, parent_path .. name .. "/")
      else
        local mname = name:match("([^/]*)[.]lua$")
        if mname then
          local m = setmetatable({}, { __index = _G })
          local ret = loadfile(filepath, "t", m)()
          if ret then
            for k,v in pairs(ret) do
              m[k] = v
            end
          end

          local route = m.route or parent_path .. mname
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
              t[k] = v
              if string.find(k:lower(), "on", 1, true) == 1 then
                t[k:sub(3):upper()] = v
              end
            end
          end
        end
      end
    end
  end
end

load_path("handle", "/")

local function find(path)
  local map = route_map[path]
  if not map then
    for k,v in pairs(pattern_map) do
      if req.path:find(k) then
        map = v
        break
      end
    end
  end
  return map
end

return {
  find = find,
  web = function(req, resp)
    local map = find(req.path)

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
