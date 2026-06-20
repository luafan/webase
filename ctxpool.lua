local pool = require "mariadb.pool"
local orm = require "mariadb.orm"

local MODULE_EXT = MODULE_EXT or ".lua"
local MODULE_LOAD_MODE = MODULE_LOAD_MODE or "bt"

local list = {}

local function load_path(path)
    local attr = lfs.attributes(path)
    if attr then
        if attr.mode == "directory" then
            for name in lfs.dir(path) do
                if name:sub(1,1) ~= "." and name:sub(-#MODULE_EXT) == MODULE_EXT then
                    load_path(string.format("%s/%s", path, name))
                end
            end
        else
            local chunk, load_err = loadfile(path, MODULE_LOAD_MODE, setmetatable({}, { __index = _G }))
            if not chunk then
                print("[ctxpool] load error: " .. path .. ": " .. tostring(load_err))
            else
                local ok, ret = pcall(chunk)
                if not ok then
                    print("[ctxpool] exec error: " .. path .. ": " .. tostring(ret))
                elseif ret then
                    for k,v in pairs(ret) do
                      list[k] = v
                    end
                end
            end
        end
    end
end

load_path((WORKDIR or "") .. "database")

return pool.new(list)
