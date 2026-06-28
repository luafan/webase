local lru = require "lru"
local lfs = require "lfs"
local md5 = require "md5"
local mimetypes = require "mimetypes"
local config = require "config"
local http = require "fan.http"
local zlib = require "zlib"

local file_cache
local body_cache
local gzip_cache

local function html_escape(str)
    return str:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&#39;")
end

local function reset_cache()
    file_cache = lru.new(1024, 1024 * 100)
    body_cache = lru.new(1024, 1024 * 100 * 1024)
    gzip_cache = lru.new(1024, 1024 * 100 * 1024)
end

reset_cache()

local function split(str, pat)
    local t = {}
    if str then
        local fpat = "(.-)" .. pat
        local last_end = 1
        local s, e, cap = str:find(fpat, 1)
        while s do
            if s ~= 1 or cap ~= "" then
                table.insert(t, cap)
            end
            last_end = e + 1
            s, e, cap = str:find(fpat, last_end)
        end
        if last_end <= #str then
            cap = str:sub(last_end)
            table.insert(t, cap)
        end
    end
    return t
end

local function get_file_info(path)
    local file_info = file_cache:get(path)

    if not file_info then
        file_info = {path = path}
        file_info.attr = lfs.attributes(path)
        file_cache:set(path, file_info, 100)
    end

    return file_info
end

local function get_file_body(file_info)
    local path = file_info.path
    local body = body_cache:get(path)
    if not body and file_info.attr and file_info.attr.mode ~= "directory" then
        local f = io.open(path, "rb")
        if f then
            body = f:read("*all")
            f:close()

            body_cache:set(path, body, #(body))
            print("load body", file_info.path)
        end
    end

    return body
end

local function get_file_gzip_body(file_info)
    local path = file_info.path
    local gbody = gzip_cache:get(path)
    if not gbody then
        local body = get_file_body(file_info)
        gbody = zlib.compress(body, nil, nil, 31)
        gzip_cache:set(path, gbody, #(gbody))

        print("calc gzip body", path)
    end

    return gbody
end

local function get_file_etag(file_info)
    if not file_info.etag then
        local body = get_file_body(file_info)
        
        local d = md5.new()
        d:update(body)
        file_info.etag = d:digest()
        print("calc etag", file_info.path, file_info.etag)
    end

    return file_info.etag
end

local function is_within_webroot(path, webroot)
    if path:sub(1, #webroot) ~= webroot then
        return false
    end
    local next_char = path:sub(#webroot + 1, #webroot + 1)
    return next_char == "" or next_char == "/"
end

local function url_decode(str)
    return str:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

local function web(req, resp)
    local parts = split(req.path, "/")
    local list = {config.webroot}
    for i, v in ipairs(parts) do
        local decoded = url_decode(v)
        if decoded:find("\0") then
            return resp:reply(400, "Invalid Request", "")
        end
        if decoded:find("/") then
            return resp:reply(400, "Invalid Request", "")
        end
        if decoded == ".." then
            if #(list) > 1 then
                table.remove(list)
            else
                return resp:reply(400, "Invalid Request", "")
            end
        elseif decoded == "." then
            -- skip
        elseif #(decoded) > 0 then
            table.insert(list, decoded)
        end
    end

    local path = table.concat(list, "/")

    if not is_within_webroot(path, config.webroot) then
        return resp:reply(403, "Forbidden", "")
    end

    local file_info = get_file_info(path)
    local if_none_match = req.headers["If-None-Match"]
    if file_info and file_info.attr and file_info.attr.mode ~= "directory" and if_none_match then
        local etag = get_file_etag(file_info)
        if etag == if_none_match then
            local ext = path:match("([^.]+)$")
            if mimetypes[ext] then
                resp:addheader("Content-Type", mimetypes[ext])
            end
        
            return resp:reply(304, "Not Modified", "")
        end
    end

    if file_info.attr then
        if file_info.attr.mode == "directory" then
            -- 先尝试 index page
            local index_name = config.directory_index or "index.html"
            local index_path = path .. "/" .. index_name
            local index_info = get_file_info(index_path)
            if index_info and index_info.attr and index_info.attr.mode == "file" then
                path = index_path
                file_info = index_info
                -- fall through 到下面的文件 serve 逻辑
            else
                -- list directory
                resp:addheader("Content-Type", "text/html; charset=utf-8")
                resp:reply_start(200, "OK")

                list[1] = ""
                local parentpath = table.concat(list, "/")

                for file in lfs.dir(path) do
                    if string.sub(file, 1, 1) ~= "." then
                        local f = path .. "/" .. file
                        local item_info = get_file_info(f)
                        local safe_name = html_escape(file)
                        local safe_href = html_escape(parentpath .. "/" .. file)

                        if item_info.attr.mode == "directory" then
                            resp:reply_chunk(
                                string.format([[<a href="%s">[%s]</a><br/>]], safe_href, safe_name)
                            )
                        else
                            resp:reply_chunk(
                                string.format([[<a href="%s">%s</a><br/>]], safe_href, safe_name)
                            )
                        end
                    end
                end

                return resp:reply_end()
            end
        end

        -- serve file (regular file or resolved index.html)
        if file_info.attr.mode ~= "directory" then
            local body = get_file_body(file_info)
            if body then
                local ext = path:match("([^.]+)$")
                if mimetypes[ext] then
                    resp:addheader("Content-Type", mimetypes[ext])
                end

                local accept = req.headers["Accept-Encoding"]
                if accept and type(accept) == "string" and string.find(accept, "gzip") then
                    body = get_file_gzip_body(file_info)
                    resp:addheader("Content-Encoding", "gzip")
                end

                resp:addheader("Cache-Control", "max-age=86400")
                resp:addheader("ETag", get_file_etag(file_info))
                resp:addheader("Content-Length", #(body))
                if req.method == "HEAD" then
                    return resp:reply(200, "OK", "")
                else
                    return resp:reply(200, "OK", body)
                end
            end
        end
    end

    return resp:reply(404, "Not Found", "Not Found")
end

local function stats()
    return {
        file_cache = file_cache:stats(),
        body_cache = body_cache:stats(),
        gzip_cache = gzip_cache:stats(),
    }
end

return {
    web = web,
    reset_cache = reset_cache,
    stats = stats,
}
