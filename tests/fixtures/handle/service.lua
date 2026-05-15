local service = require "service"

-- route = "/.service"

function onGet(req, resp)
  local list = service.list()

  resp:addheader("Content-Type", "text/plain; charset=UTF-8")
  resp:reply_start(200, "OK")
  for i,v in ipairs(list) do
    resp:reply_chunk(string.format("%s\t%s\n", v.name, v.getStatus()))
  end
  return resp:reply_end()
end
