route = "/echo"

function onGet(req, resp)
    return {params = req.params or {}, method = req.method, path = req.path}
end
