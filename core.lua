require "compat53"

print("core.lua")

_S = {conn_count = 0}
connmap = {}

local _S = _S
local connmap = connmap

local fan = require "fan"
local config = require "config"

local httpd = require "fan.httpd"

local route = require "route"
local utils = require "fan.utils"
local mapping = require "mapping"

local webfile = require "webfile"

local service = require "service"
print(service.start())

math.randomseed(utils.gettime())

function onService(req,resp)
  req.path = mapping[req.path] or req.path

  if not route.web(req, resp) then
    return webfile.web(req, resp)
  end
end

serv2 = httpd.bind{
  host = config.service_host,
  port = config.service_port,
  onService = onService
}

print(serv2.host, serv2.port)

fan.loop()
