local m = {}
local setmetatable = setmetatable

local weak_mt = {}
weak_mt.__index = function(self, key)
    local target = self[weak_mt].target
    if target then
        return target[key]
    end
end

weak_mt.__newindex = function(self, key, value)
    local target = self[weak_mt].target
    if target then
        target[key] = value
    end
end

local function weakify(target)
    local obj = {[weak_mt] = setmetatable({target = target}, {__mode = "v"})}
    setmetatable(obj, weak_mt)
    return obj
end

setmetatable(m, {
    __call = function(self, ...)
        local t = {...}
        if #t > 1 then
            local out = {}
            for i,v in ipairs(t) do
                table.insert(out, weakify(v))
            end

            return table.unpack(out)
        else
            return weakify(t[1])
        end
    end
})

return m
