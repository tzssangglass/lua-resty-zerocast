# vim:set ft=perl ts=4 sw=4 et:
use Test::Nginx::Socket::Lua;

repeat_each(2);

# 4 per repeat: status, response_body, no_error_log x2 ([error], [warn])
plan tests => repeat_each() * (blocks() * 4);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

our $HttpConfig = <<'EOC';
    lua_package_path "$TEST_NGINX_HTML_DIR/lualib/?.lua;lib/?.lua;;";

    # The control plane's listener. Every data plane that connects is its
    # own request here, with its own websocket.server. They all push the
    # SAME frame object: built once per version, never copied per dp.
    lua_shared_dict cfg 1m;
    init_by_lua_block {
        local zerocast = require "resty.zerocast"
        package.loaded.zerocast = zerocast
        package.loaded.cfg_frame = zerocast.frame(string.rep("c", 70000))
    }

    server {
        listen 127.0.0.1:$TEST_NGINX_RAND_PORT_1;

        location = /s {
            content_by_lua_block {
                local server = require "resty.websocket.server"
                local zerocast = package.loaded.zerocast
                local wb = assert(server:new{
                    timeout = 10000,
                    max_payload_len = 1024 * 1024,
                })
                local shm = ngx.shared.cfg

                -- a dp is "connected" once its handshake completed; the
                -- driver waits for all of them before releasing a version
                shm:incr("connected", 1, 0)
                while shm:get("release") ~= "1" do ngx.sleep(0.01) end

                -- the whole point: a resty.websocket.server socket must
                -- carry send_ref, or every dp silently copies the frame
                if wb.sock.send_ref == nil then
                    ngx.log(ngx.ERR, "send_ref missing on req socket")
                    return ngx.exit(444)
                end

                local frame = package.loaded.cfg_frame
                local bytes, err = zerocast.send_shared(wb, frame)
                if not bytes then
                    ngx.log(ngx.ERR, "send_shared failed: ", err)
                    return ngx.exit(444)
                end
                -- hold the request until the dp acknowledges, so the
                -- frame is fully drained before the test tears down
                wb:recv_frame()
            }
        }

        location = /c {
            content_by_lua_block {
                local client = require "resty.websocket.client"
                local shm = ngx.shared.cfg
                local n = tonumber(ngx.var.arg_n) or 3
                local uri = "ws://127.0.0.1:" .. ngx.var.server_port .. "/s"

                -- a failed previous run must not pre-release the servers
                shm:set("release", "0")
                shm:set("connected", 0)

                local threads, wbs = {}, {}
                for i = 1, n do
                    local wb = assert(client:new{
                        max_payload_len = 1024 * 1024,
                    })
                    wbs[i] = wb
                    local ok, err = wb:connect(uri)
                    if not ok then
                        ngx.say("connect ", i, " failed: ", err)
                        return
                    end
                end
                while (shm:get("connected") or 0) < n do ngx.sleep(0.01) end
                shm:set("release", "1")

                for i = 1, n do
                    threads[i] = ngx.thread.spawn(function(k)
                        local data, typ, err = wbs[k]:recv_frame()
                        local intact = data == string.rep("c", 70000)
                        return data ~= nil, typ, err, intact
                    end, i)
                end

                local ok_all = true
                for i = 1, n do
                    -- wait() prepends its own ok; our values follow
                    local _, ok, typ, err, intact = ngx.thread.wait(threads[i])
                    if not ok or typ ~= "binary" or not intact then
                        ok_all = false
                        ngx.say("dp ", i, ": ok=", ok, " typ=", typ,
                                " intact=", tostring(intact),
                                " err=", tostring(err))
                    end
                    wbs[i]:close()
                end
                ngx.say("all=", ok_all)
            }
        }
    }
EOC

no_long_string();

run_tests();

__DATA__

=== TEST 1: N data planes each receive the one shared frame
--- http_config eval: $::HttpConfig
--- config
    set $port $TEST_NGINX_RAND_PORT_1;
    location = /t {
        content_by_lua_block {
            local sock = assert(ngx.socket.tcp())
            sock:settimeout(10000)
            assert(sock:connect("127.0.0.1", ngx.var.port))
            local req = "GET /c?n=3 HTTP/1.0\r\n"
                        .. "Host: localhost\r\n\r\n"
            assert(sock:send(req))
            local buf = {}
            while true do
                local chunk = sock:receiveany(65536)
                if not chunk then
                    break
                end
                buf[#buf + 1] = chunk
            end
            local resp = table.concat(buf)
            ngx.print(resp:match("\r\n\r\n(.*)$") or resp)
        }
    }
--- request
GET /t
--- response_body
all=true
--- no_error_log
[error]
[warn]
--- timeout: 15
