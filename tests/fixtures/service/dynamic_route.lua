status = "n/a"

function onStart()
  local route = require "route"
  route.add({
    route = "/dynamic_test",
    onGet = function(req, resp)
      return {dynamic = true, msg = "hello from dynamic route"}
    end,
  })

  route.add({
    pattern = "^/dynamic_pattern/",
    onGet = function(req, resp)
      return {dynamic = true, path = req.path}
    end,
  })

  status = "running"
end

function onStop()
  local route = require "route"
  route.remove("/dynamic_test")
  route.remove("^/dynamic_pattern/")
  status = "stopped"
end

function getStatus()
  return status
end
