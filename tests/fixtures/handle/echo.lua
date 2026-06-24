route = "/echo"

local json = require "json"

function onGet(req, resp)
    return {params = json.object(req.params), method = req.method, path = req.path}
end
