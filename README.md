Name
====

lua-resty-zerocast - Build one WebSocket frame once, send it to every connected data plane without per-connection copies

Table of Contents
=================

* [Name](#name)
* [Status](#status)
* [Synopsis](#synopsis)
* [Description](#description)
* [Methods](#methods)
    * [frame](#frame)
    * [send_shared](#send_shared)
* [The send_ref Patch](#the-send_ref-patch)
* [Prerequisites](#prerequisites)
* [Installation](#installation)
* [Build and Test from Source](#build-and-test-from-source)
* [Bugs and Patches](#bugs-and-patches)
* [Author](#author)
* [Copyright and License](#copyright-and-license)
* [See Also](#see-also)

Status
======

This library is under early development.

Synopsis
========

```nginx
# nginx.conf

http {
    lua_package_path "/path/to/lua-resty-zerocast/lib/?.lua;;";

    # the config every data plane should have, versioned; the payload
    # itself lives in Lua (shared, zero-copy), only the version number
    # goes through shm so each request can notice a change
    lua_shared_dict cfg_ver 1m;

    server {
        # each data plane connects here and stays connected
        location = /dp {
            content_by_lua_block {
                local server = require "resty.websocket.server"
                local zerocast = require "resty.zerocast"

                local wb = assert(server:new{ timeout = 0 })
                local shm = ngx.shared.cfg_ver
                -- module-level: frames live here, shared by every dp request
                -- in this worker. Whoever publishes a new config does
                -- `cfg_frames[v] = zerocast.frame(blob)` then
                -- `shm:set("version", v)`. Start with version 1 in place
                -- so the first loop iteration has something to send.
                package.loaded.cfg_frames = package.loaded.cfg_frames
                                            or { zerocast.frame(initial_cfg) }
                local cfg_frames = package.loaded.cfg_frames
                local seen = 0

                while true do
                    local ver = shm:get("version") or 0
                    if ver ~= seen then
                        seen = ver
                        -- built once by whoever published the version;
                        -- every dp sends the same string
                        local bytes, err = zerocast.send_shared(
                            wb, cfg_frames[ver])
                        if not bytes then
                            ngx.log(ngx.WARN, "dp dropped: ", err)
                            return      -- wb.fatal is set; let it reconnect
                        end
                    end
                    ngx.sleep(0.05)          -- poll; or block on recv_frame
                end
            }
        }
    }
}
```

Description
===========

A control plane that pushes the same configuration to many data planes
over WebSockets has a specific shape: every data plane is its own
request, every request owns one `websocket.server` object, and all of
them must send the same bytes. The naive path builds the frame and
copies it into a per-connection nginx buffer once per data plane.

This library does two things. `frame` builds the RFC 6455 frame once;
every request then passes that single Lua string to `send_shared`,
which hands nginx a reference to it instead of a copy when the
`send_ref` patch is present. At 16 MB × 100 data planes that is 1.6 GB
versus 34 MB of peak worker RSS in our benchmark, and the wall time
halves because 1.6 GB of memcpy stops contending for memory bandwidth.

Cosockets are request-scoped in ngx_lua, so there is deliberately no
"caster" object that owns many connections: it could not drive any of
them from outside their own requests. Each request sends for itself,
and sharing happens through the frame string, not through a connection
registry.

[Back to TOC](#table-of-contents)

Methods
=======

[Back to TOC](#table-of-contents)

frame
-----

**syntax:** `frame = zerocast.frame(payload, opcode?)`

Builds one RFC 6455 server-to-client frame (FIN set, never masked).
`opcode` defaults to binary (`zerocast.OP_BINARY`, `0x2`); pass
`zerocast.OP_TEXT` (`0x1`) for a text frame. Payloads up to 2^31-1
bytes are supported. Hold the returned string in a module-level table
for as long as it is current; every request that sends it is reading
the same object.

[Back to TOC](#table-of-contents)

send_shared
-----------

**syntax:** `bytes, err = zerocast.send_shared(wb, frame)`

Sends an already-built frame to one connection. `wb` is a
[lua-resty-websocket](https://github.com/openresty/lua-resty-websocket)
*server* object. Uses `wb.sock:send_ref` when the patch is present and
plain `send` otherwise, so the same code runs on an unpatched
OpenResty. On failure sets `wb.fatal = true`, matching the original
library's own convention, and returns `nil, err`.

Call it from inside the request that created `wb`.

[Back to TOC](#table-of-contents)

The send_ref Patch
==================

Plain `tcpsock:send` copies the string into a per-connection nginx
buffer. The patch under `patches/` adds `tcpsock:send_ref(str)` to
lua-nginx-module: the buffer references the Lua string directly and the
string is anchored with `luaL_ref` until the send completes, errors, or
the socket is finalized. The library uses `send_ref` automatically when
it is present and falls back to `send` otherwise.

Patches are keyed by OpenResty version under
`patches/openresty-<version>/` and cut against the official tarball.

[Back to TOC](#table-of-contents)

Prerequisites
=============

OpenResty 1.31.1.1 or a compatible lua-nginx-module (0.10.31rc5+) with
LuaJIT, and [lua-resty-websocket](https://github.com/openresty/lua-resty-websocket).
The `send_ref` optimization needs an OpenResty built with the bundled
patch; everything else works without it.

[Back to TOC](#table-of-contents)

Installation
============

```bash
make install OPENRESTY_PREFIX=/usr/local/openresty
```

installs `lib/resty/zerocast.lua` into `<prefix>/lualib/resty/`. To use
the `send_ref` optimization, build OpenResty with the patch:

```bash
make build         # fetches, verifies, patches and builds OpenResty under build/
make install       # installs the library into that build
```

[Back to TOC](#table-of-contents)

Build and Test from Source
==========================

```bash
git clone --recursive https://github.com/tzssangglass/lua-resty-zerocast
cd lua-resty-zerocast
make test
```

`make build` downloads the pinned OpenResty tarball, verifies its
sha256, applies `patches/openresty-1.31.1.1/` with `--fuzz=0`, and
builds under `build/`. `make deps` installs Test::Nginx's Perl
dependencies into `deps/perl5` so the system Perl is never used.
`make fmt` runs `reindex` over the `.t` files. Nothing is written
outside the repository.

[Back to TOC](#table-of-contents)

Bugs and Patches
================

Please submit bug reports, wishlists, or patches by creating a ticket on the
[GitHub Issue Tracker](https://github.com/tzssangglass/lua-resty-zerocast/issues).

[Back to TOC](#table-of-contents)

Author
======

tzssangglass <tzssangglass@gmail.com>

[Back to TOC](#table-of-contents)

Copyright and License
=====================

This module is licensed under the Apache License 2.0.

Copyright (c) 2026, tzssangglass

All rights reserved.

[Back to TOC](#table-of-contents)

See Also
========

* [lua-resty-websocket](https://github.com/openresty/lua-resty-websocket)
* [lua-nginx-module](https://github.com/openresty/lua-nginx-module)
* OpenResty: https://openresty.org/
