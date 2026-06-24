route = "/echo"

local json = require "json"

function onGet(req, resp)
    return {params = req.params or json.object(), method = req.method, path = req.path}
end
