local webfile = require "webfile"

route = "/purge_cache"

local purge_token = os.getenv("PURGE_TOKEN")

local function is_authorized(req)
    local remote = req.remote_addr or req.headers["X-Real-IP"] or ""
    if remote == "127.0.0.1" or remote == "::1" or remote == "localhost" then
        return true
    end
    if purge_token and purge_token ~= "" then
        local token = req.params and req.params.token or req.headers["X-Purge-Token"]
        return token == purge_token
    end
    return false
end

function onGet(req, resp)
    if not is_authorized(req) then
        return resp:reply(403, "Forbidden", "access denied")
    end
    webfile.reset_cache()
    return resp:reply(200, "OK", "purged.")
end
