local webfile = require "webfile"

route = "/purge_cache"

function onGet(req, resp)
    webfile.reset_cache()
    return resp:reply(200, "OK", "purged.")
end
