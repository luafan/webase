local lfs = require "lfs"

local mapping_dir = "mapping"

local safe_os = {
    getenv = os.getenv,
    time = os.time,
    date = os.date,
    clock = os.clock,
    difftime = os.difftime,
}
local env = {os = safe_os, tonumber = tonumber, tostring = tostring}
env._ENV = env
env._G = env

local function load_config(dir)
    local attr = lfs.attributes(dir)
    if attr and attr.mode == "directory" then
        for name in lfs.dir(dir) do
            if name:match("^[^.].*[.]dll$") then
                local filepath = string.format("%s/%s", dir, name)
                local chunk, load_err = loadfile(filepath, "t", env)
                if not chunk then
                    print("[mapping] load error: " .. filepath .. ": " .. tostring(load_err))
                else
                    local ok, exec_err = pcall(chunk)
                    if not ok then
                        print("[mapping] exec error: " .. filepath .. ": " .. tostring(exec_err))
                    end
                end
            end
        end
    else
      print(string.format("config [%s] not found, ignored.", dir))
    end
end

load_config(mapping_dir)

return env
