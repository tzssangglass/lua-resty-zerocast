# vim:set ft=perl ts=4 sw=4 et:
use Test::Nginx::Socket::Lua;

repeat_each(2);

# 3 per repeat: status, response_body, no_error_log ([error])
# for each of the four blocks.
plan tests => repeat_each() * (blocks() * 3);

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

our $HttpConfig = <<'EOC';
    lua_package_path "$TEST_NGINX_HTML_DIR/lualib/?.lua;lib/?.lua;;";
EOC

no_long_string();

run_tests();

__DATA__

=== TEST 1: frame() builds RFC 6455 server frames (binary by default)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local zc = require "resty.zerocast"
            ngx.say(zc.frame("hi") == "\130\2hi")
            ngx.say(zc.frame("hi", zc.OP_TEXT) == "\129\2hi")
            ngx.say(zc.frame("hi", 2):byte(1) == 0x82)
            ngx.say(zc.frame("hi", 1):byte(1) == 0x81)
        }
    }
--- request
GET /t
--- response_body
true
true
true
true
--- no_error_log
[error]



=== TEST 2: extended lengths and the 125/126 boundary
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local zc = require "resty.zerocast"
            local f125 = zc.frame(string.rep("x", 125))
            ngx.say(#f125 == 127 and f125:byte(2) == 125)
            local f126 = zc.frame(string.rep("x", 126))
            ngx.say(#f126 == 130 and f126:byte(2) == 126
                    and f126:byte(3) == 0 and f126:byte(4) == 126)
            local f200 = zc.frame(string.rep("x", 200))
            ngx.say(#f200 == 204 and f200:byte(4) == 200)
            local fbig = zc.frame(string.rep("x", 70000))
            -- 70000 = 0x11170: 8-byte length is 00 00 00 00 00 01 11 70
            ngx.say(#fbig == 70010 and fbig:byte(2) == 127
                    and fbig:byte(8) == 1 and fbig:byte(9) == 0x11
                    and fbig:byte(10) == 0x70)
            ngx.say(zc.frame("") == "\130\0")
        }
    }
--- request
GET /t
--- response_body
true
true
true
true
true
--- no_error_log
[error]



=== TEST 3: send_shared refuses a dead connection and marks it fatal
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local zc = require "resty.zerocast"
            -- a websocket.server whose socket is gone (request finished)
            local wb = { sock = nil }
            local bytes, err = zc.send_shared(wb, "\130\0")
            ngx.say("bytes=", tostring(bytes), " err=", err)
            -- and one whose send fails: marked fatal, like the original lib
            local dead = { sock = { send = function() return nil, "boom" end } }
            local b2, e2 = zc.send_shared(dead, "\130\0")
            ngx.say("bytes=", tostring(b2), " err=", e2, " fatal=", dead.fatal)
        }
    }
--- request
GET /t
--- response_body
bytes=nil err=no socket
bytes=nil err=boom fatal=true
--- no_error_log
[error]



=== TEST 4: send_shared prefers send_ref, falls back to send, honours fatal
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local zc = require "resty.zerocast"

            -- both present: send_ref wins
            local hit
            local wb = { sock = {
                send_ref = function(_, d) hit = "ref"; return #d end,
                send = function() hit = "send"; return 0 end,
            } }
            local n = zc.send_shared(wb, "\130\5hello")
            ngx.say("pref=", hit, " bytes=", n, " fatal=", tostring(wb.fatal))

            -- only send: the unpatched-build path
            local sent
            local plain = { sock = {
                send = function(_, d) sent = d; return #d end,
            } }
            local n2 = zc.send_shared(plain, "\130\5hello")
            ngx.say("fallback_bytes=", n2, " same=", sent == "\130\5hello")

            -- failure marks fatal, and a fatal wb is refused afterwards
            local dead = { sock = {
                send_ref = function() return nil, "boom" end,
            } }
            local n3, e3 = zc.send_shared(dead, "\130\0")
            local n4, e4 = zc.send_shared(dead, "\130\0")
            ngx.say("dead=", tostring(n3), "/", e3, " then=", tostring(n4),
                    "/", e4, " fatal=", dead.fatal == true)
        }
    }
--- request
GET /t
--- response_body
pref=ref bytes=7 fatal=nil
fallback_bytes=7 same=true
dead=nil/boom then=nil/fatal error already happened fatal=true
--- no_error_log
[error]
