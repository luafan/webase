route = "/ws/echo"

function onWebSocket(req, resp)
  req:websocket_accept()
  while req:websocket_state() == "open" do
    local data, opcode = req:websocket_receive()
    if data then
      req:websocket_send(data, opcode)
    else
      break
    end
  end
end

