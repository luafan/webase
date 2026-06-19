local lfs = require "lfs"

local MODULE_EXT = MODULE_EXT or ".lua"
local MODULE_LOAD_MODE = MODULE_LOAD_MODE or "bt"

local mapping_dir = (WORKDIR or "") .. "mapping"

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
            if name:sub(1,1) ~= "." and name:sub(-#MODULE_EXT) == MODULE_EXT then
                local filepath = string.format("%s/%s", dir, name)
                local chunk, load_err = loadfile(filepath, MODULE_LOAD_MODE, env)
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

if not _DATABASE_REGISTRY then
    -- 仅非 bundle 模式扫目录; bundle 模式 mapping/ 为空无需扫
    load_config(mapping_dir)
end

return env
