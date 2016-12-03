require "compat53"

print("core.lua")

_S = {conn_count = 0}
connmap = {}

local _S = _S
local connmap = connmap

local require = require
local string = string
local math = math
local table = table

local lpeg = require "lpeg"
local json = require "cjson"
local lfs = require "lfs"
local md5 = require "md5"

local fan = require "fan"
local httpd = require "fan.httpd"
local config = require "config"
local stream = require "fan.stream"

local route = require "route"
local utils = require "fan.utils"
local mime = require "mime"

local mapping = require "mapping"

local lru = require "lru"

local service = require "service"
print(service.start())

math.randomseed(utils.gettime())

local file_cache
local md5_cache

local function reset_cache()
  file_cache = lru.new(1024, 1024 * 1024 * 100)
  md5_cache = lru.new(1024, 1024 * 100)
end

reset_cache()

function split(s, sep)
  sep = lpeg.P(sep)
  local elem = lpeg.C((1 - sep)^0)
  local p = lpeg.Ct(elem * (sep * elem)^0)
  return lpeg.match(p, s)
end

function onService(req,resp)
  req.path = mapping[req.path] or req.path

  if req.path == "/" then
    resp:addheader("Content-Type", "text/plain; charset=UTF-8")
    local list = {}
    table.insert(list, "403 Forbidden\n")

    table.insert(list, string.format("ip: %s:%d\n", req.remoteip, req.remoteport))

    for k,v in pairs(req.headers) do
      table.insert(list, string.format("%s: %s", k, v))
    end
    local body = table.concat(list, "\n")
    resp:addheader("Content-Length", string.len(body))
    return resp:reply(403, "Forbidden", body)
  elseif req.path == "/purge_cache" then
    reset_cache()
    return resp:reply(200, "OK", "purged.")
  end

  if not route.web(req, resp) then
    local parts = split(req.path, "/")
    local list = {config.webroot}
    for i,v in ipairs(parts) do
      if v == ".." then
        if #(list) > 1 then
          table.remove(list)
        else
          return resp:reply(400, "Invaild Request", "")
        end
      else
        table.insert(list, v)
      end
    end

    local path = table.concat(list, "/")

    resp:addheader("Cache-Control", "max-age=86400")

    local etag = md5_cache:get(path)
    if etag and req.headers["If-None-Match"] == etag then
      return resp:reply(304, "Not Modified", "")
    else
      local data = file_cache:get(path)
      if not data then
        local f = io.open(path, "rb")
        if f then
          data = f:read("*all")
          file_cache:set(path, data, #(path) + #(data))
          f:close()
        end
      end

      if data then
        local ext = path:match("([^.]+)$")
        if mime[ext] then
          resp:addheader("Content-Type", mime[ext])
        end
        if not etag then
          local d = md5.new()
          d:update(data)
          etag = d:digest()
          md5_cache:set(path, etag, #(path) + #(etag))
        end
        resp:addheader("ETag", etag)
        resp:addheader("Content-Length", #(data))
        return resp:reply(200, "OK", data)
      end
    end

    return resp:reply(404, "Not Found", "Not Found")
  end
end

serv2,port = httpd.bind{
  host = config.service_host,
  port = config.service_port,
  onService = onService
}

print(serv2, port)

fan.loop()
