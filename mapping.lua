local lfs = require "lfs"

local mapping_dir = serviceRoot .. "mapping"

local env = {os = os, tonumber = tonumber}
env._ENV = env
env._G = env

local function load_config(dir)
    local attr = lfs.attributes(dir)
    if attr and attr.mode == "directory" then
        for name in lfs.dir(dir) do
            if name:match("^[^.].*[.]dll$") then
                loadfile(string.format("%s/%s", dir, name), "t", env)()
            end
        end
    else
      print(string.format("config [%s] not found, ignored.", dir))
    end
end

load_config(mapping_dir)

return env
