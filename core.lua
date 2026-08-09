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

-- Initialize worker threads from SERVICE_WORKERS env (default 8)
local worker_count = tonumber(os.getenv("SERVICE_WORKERS")) or 8
if worker_count > 0 and fan.workers_init then
  fan.workers_init(worker_count)
  print("workers: " .. fan.worker_count())
end

fan.loop()

-- After event loop exits (triggered by event_mgr_break), run shutdown hooks
-- to release resources (SQLite handles, etc.) before lua_close.
if _SHUTDOWN_HOOKS then
  for _, fn in ipairs(_SHUTDOWN_HOOKS) do
    pcall(fn)
  end
end
