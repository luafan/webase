local table = table
local string = string

route = "/"

function onGet(req, resp)
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
end
