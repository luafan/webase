local pool = require "mariadb.pool"
local orm = require "mariadb.orm"

local list = {}

local function load_path(path)
    local attr = lfs.attributes(path)
    if attr then
        if attr.mode == "directory" then
            for name in lfs.dir(path) do
                if name:match("^[^.].*[.]lua$") then
                    load_path(string.format("%s/%s", path, name))
                end
            end
        else
            local chunk, load_err = loadfile(path, "t", setmetatable({}, { __index = _G }))
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

load_path("database")

return pool.new(list)
