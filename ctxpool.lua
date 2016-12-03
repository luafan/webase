local pool = require "mariadb.pool"
local orm = require "mariadb.orm"

local list = {}

local function load_path(path)
    local attr = lfs.attributes(path)
    if attr and attr.mode == "directory" then
        for name in lfs.dir(path) do
            if name:match("^[^.].*[.]lua$") then
                load_path(string.format("%s/%s", path, name))
            end
        end
    else
        local m = loadfile(path, "t", setmetatable({}, { __index = _G }))()
        for k,v in pairs(m) do
          list[k] = v
        end
    end
end

load_path("database")

return pool.new(list)
