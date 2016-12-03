local stream = require "fan.stream"
local print = print
local pcall = pcall
local require = require
local json = require "cjson"
local string = string

local lfs = require "lfs"

local service_map = {
}

local function load_path(path)
  local attr = lfs.attributes(path)
  if attr then
    if attr.mode == "directory" then
      for name in lfs.dir(path) do
        if name:match("^[^.].*[.]lua$") then
          load_path(string.format("%s/%s", path, name))
        end
      end
    else
      local m = setmetatable({}, { __index = _G })
      loadfile(path, "t", m)()

      m.name = m.name or path:match("([^/]*)[.]lua$")
      if m.name then
        service_map[m.name] = m

        for k,v in pairs(m) do
          if string.find(k:lower(), "on", 1, true) == 1 then
            m[k:sub(3):lower()] = v
          end
        end
      end
    end
  end
end

load_path("service")

local function eval(method, name, ...)
  if name then
    if service_map[name] and service_map[name][method] then
      return pcall(service_map[name][method], ...)
    else
      return false, "not found"
    end
  else
    for k,v in pairs(service_map) do
      if v[method] then
        local st, msg = pcall(v[method])
        if not st then
          return st, msg
        end
      else
        return false, "not found"
      end
    end

    return true
  end
end

local mt = {}

function mt:__index(key)
  return function(name, ...)
    return eval(key, name, ...)
  end
end

local function list()
  local t = {}
  for k,v in pairs(service_map) do
    table.insert(t, v)
  end

  return t
end

local function get(name)
  return service_map[name]
end

return setmetatable({
    list = list,
    get = get,
  }, mt)
