# webase

A lightweight Lua web framework built on [luafan](https://github.com/luafan/luafan), packaged as a Docker image.

## Quick Start

```bash
docker run -d -p 8080:2201 \
  -v ./handle:/root/handle:ro \
  -v ./service:/root/service:ro \
  luafan/webase
```

## Features

- File-based route handlers (`handle/` directory)
- Dynamic route registration via Lua API
- Static file serving with LRU cache, ETag, and gzip compression
- Background service management with start/stop lifecycle
- URL mapping/rewriting
- MariaDB/MySQL connection pool support
- JSONP support with XSS protection

## Configuration

All configuration is done via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVICE_HOST` | `0.0.0.0` | HTTP server bind address |
| `SERVICE_PORT` | `2201` | HTTP server port |
| `WEBROOT` | `/root/web` | Static file root directory |
| `MARIA_HOST` | `127.0.0.1` | MariaDB host |
| `MARIA_PORT` | _(auto)_ | MariaDB port |
| `MARIA_DATABASE_NAME` | `test` | Database name |
| `MARIA_USERNAME` | `root` | Database user |
| `MARIA_PASSWORD` | _(none)_ | Database password |
| `MARIA_CHARSET` | `utf8` | Connection charset |
| `MARIA_POOL_COUNT` | `10` | Connection pool size |

## Route Handlers

Create `.lua` files in a `handle/` directory and mount it into the container at `/root/handle`.

### Example: `handle/hello.lua`

```lua
-- Registers as GET /hello
function onGet(req, resp)
  return {message = "hello", params = req.params}
end

function onPost(req, resp)
  return {message = "created"}
end
```

- Handlers returning a **table** are auto-serialized as JSON
- Handlers returning a **string** starting with `<` are served as HTML, otherwise as plain text
- Handlers can manage responses directly via `resp:reply(code, status, body)`
- JSONP is supported via `?jsonp=callbackName` query parameter

### Custom Route Path

```lua
route = "/api/status"

function onGet(req, resp)
  return {status = "ok"}
end
```

### Pattern Matching

```lua
pattern = "^/api/users/"

function onGet(req, resp)
  return {path = req.path}
end
```

## Dynamic Routes

Register routes at runtime from service scripts or other Lua code:

```lua
local route = require "route"

-- Add an exact route
route.add({
  route = "/api/hello",
  onGet = function(req, resp)
    return {msg = "hello"}
  end,
})

-- Add a pattern route
route.add({
  pattern = "^/api/v2/",
  onGet = function(req, resp)
    return {version = 2, path = req.path}
  end,
})

-- Remove a route
route.remove("/api/hello")
```

**Priority order:** static exact > static pattern > dynamic exact > dynamic pattern

## Services

Create `.lua` files in a `service/` directory and mount it at `/root/service`. Services support lifecycle hooks:

### Example: `service/worker.lua`

```lua
local fan = require "fan"

status = "n/a"

function onStart()
  status = "running"
  -- start background work
end

function onStop()
  status = "stopped"
end

function getStatus()
  return status
end
```

## Static Files

Mount your static assets to the `WEBROOT` path (default `/root/web`):

```bash
docker run -d -p 8080:2201 \
  -v ./public:/root/web:ro \
  luafan/webase
```

Features:
- Automatic MIME type detection
- gzip compression (when client supports it)
- ETag-based caching with `304 Not Modified`
- `Cache-Control: max-age=86400` headers
- Directory listing
- Path traversal protection

## URL Mapping

Place `.dll` files in a `mapping/` directory to define URL rewrites:

```bash
docker run -d -p 8080:2201 \
  -v ./mapping:/root/mapping:ro \
  luafan/webase
```

## Volumes

| Path | Purpose |
|------|---------|
| `/root/handle` | Route handler scripts |
| `/root/service` | Background service scripts |
| `/root/web` | Static files |
| `/root/mapping` | URL rewrite rules |
| `/root/config.d` | Additional config overrides |

## Running Tests

```bash
bash tests/run.sh
```

This builds a test image, starts a container with test fixtures mounted, runs functional and security tests, then cleans up.
