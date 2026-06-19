local stream = require "fan.stream"
local print = print
local pcall = pcall
local require = require
local cjson = require "json"
local string = string

local lfs = require "lfs"

local MODULE_EXT = MODULE_EXT or ".lua"
local MODULE_LOAD_MODE = MODULE_LOAD_MODE or "bt"

local route_map = {
}

local pattern_map = {
}

local dynamic_route_map = {
}

local dynamic_pattern_map = {
}

local function load_path(path, parent_path)
  local attr = lfs.attributes(path)
  if not attr or attr.mode ~= "directory" then return end
  for name in lfs.dir(path) do
    if name:sub(1,1) ~= "." then
      local filepath = path .. "/" .. name
      local attr = lfs.attributes(filepath)

      if attr and attr.mode == "directory" then
        load_path(filepath, parent_path .. name .. "/")
      else
        local mname = name:match("([^/]+)" .. MODULE_EXT:gsub("%.","%%.") .. "$")
        if mname then
          local m = setmetatable({}, { __index = _G })
          local chunk, load_err = loadfile(filepath, MODULE_LOAD_MODE, m)
          if not chunk then
            print("[route] load error: " .. filepath .. ": " .. tostring(load_err))
          else
            local ok, ret = pcall(chunk)
            if not ok then
              print("[route] exec error: " .. filepath .. ": " .. tostring(ret))
            else
              if ret then
                for k,v in pairs(ret) do
                  m[k] = v
                end
              end

              local route = m.route or parent_path .. mname
              local pattern = m.pattern
              if route or pattern then
                local t = {}
                if route then
                  route_map[route] = t
                end
                if pattern then
                  pattern_map[pattern] = t
                end

                for k,v in pairs(m) do
                  t[k] = v
                  if string.find(k:lower(), "on", 1, true) == 1 then
                    t[k:sub(3):upper()] = v
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

local function register_handle(m)
  local route = m.route
  local pattern = m.pattern
  if route or pattern then
    local t = {}
    if route then
      route_map[route] = t
    end
    if pattern then
      pattern_map[pattern] = t
    end
    for k,v in pairs(m) do
      t[k] = v
      if string.find(k:lower(), "on", 1, true) == 1 then
        t[k:sub(3):upper()] = v
      end
    end
  end
end

if _HANDLE_REGISTRY then
  -- 从 amalgamated bundle 加载 handle 模块 (字节码 + 独立 env)
  for modname, bytecode in pairs(_HANDLE_REGISTRY) do
    local m = setmetatable({}, { __index = _G })
    local chunk, load_err = load(bytecode, "@" .. modname, "b", m)
    if not chunk then
      print("[route] bundle load error: " .. modname .. ": " .. tostring(load_err))
    else
      local ok, ret = pcall(chunk)
      if not ok then
        print("[route] bundle exec error: " .. modname .. ": " .. tostring(ret))
      else
        if ret then
          for k,v in pairs(ret) do m[k] = v end
        end
        register_handle(m)
      end
    end
  end
else
  load_path((WORKDIR or "") .. "handle", "/")
end

local function find(path)
  local map = route_map[path]
  if map then return map end

  for k,v in pairs(pattern_map) do
    if path:find(k) then return v end
  end

  map = dynamic_route_map[path]
  if map then return map end

  for k,v in pairs(dynamic_pattern_map) do
    if path:find(k) then return v end
  end

  return nil
end

local function add(opts)
  local route_path = opts.route
  local pat = opts.pattern

  local t = {}
  for k,v in pairs(opts) do
    t[k] = v
    if string.find(k:lower(), "on", 1, true) == 1 then
      t[k:sub(3):upper()] = v
    end
  end

  if route_path then
    dynamic_route_map[route_path] = t
  end
  if pat then
    dynamic_pattern_map[pat] = t
  end
end

local function remove(path_or_pattern)
  dynamic_route_map[path_or_pattern] = nil
  dynamic_pattern_map[path_or_pattern] = nil
end

local function is_valid_jsonp_callback(name)
  return name and name:match("^[%a_$][%w_$.]*$") ~= nil and #name <= 128
end

local respMap = {
  ["table"] = function(req, resp, data)
    local body = cjson.encode(data)

    if req.params.jsonp then
      if not is_valid_jsonp_callback(req.params.jsonp) then
        resp:addheader("Content-Type", "application/json; charset=UTF-8")
        resp:reply(400, "Bad Request", cjson.encode({error = "invalid callback name"}))
        return
      end
      resp:addheader("Content-Type", "text/javascript; charset=UTF-8")
      resp:reply(200, "OK", string.format("%s(%s)", req.params.jsonp, body))
    else
      resp:addheader("Content-Type", "application/json; charset=UTF-8")
      resp:reply(200, "OK", body)
    end
  end,
  ["string"] = function(req, resp, data)
    if string.sub(data, 1, 1) == "<" then
      resp:addheader("Content-Type", "text/html; charset=UTF-8")
    else
      resp:addheader("Content-Type", "text/plain; charset=UTF-8")
    end
    resp:reply(200, "OK", data)
  end,
}

return {
  find = find,
  add = add,
  remove = remove,
  web = function(req, resp)
    local map = find(req.path)

    if map then
      if map["WEBSOCKET"] and req:is_websocket_upgrade() then
        local m = map["WEBSOCKET"]
        local st, msg = pcall(m, req, resp)
        if not st then
          print("[route][ws]", msg)
        end
        return true
      end

      local method = req.method
      local m = map[method]
      if m then
        local st,msg = pcall(m, req, resp)

        if st == false then
          print("[route]", msg)
          local exception = cjson.encode{exception=msg}
          resp:reply(500, "OK", exception)
        elseif msg then
          local m = respMap[type(msg)]
          if m then
            local st,msg2 = pcall(m, req, resp, msg)
            if not st then
              print("[route]", msg2)
              local exception = cjson.encode{exception=msg2}
              resp:reply(500, "OK", exception)
            end
          end
        end

        return true
      end
    end
  end,
}
