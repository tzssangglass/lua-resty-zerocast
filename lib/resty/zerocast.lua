-- lua-resty-zerocast: build one WebSocket frame once, send it from every
-- request that owns a data-plane connection. Same frame object reaches N
-- connections without N copies; falls back to plain send() when the
-- send_ref patch is absent.

local char   = string.char
local band   = bit.band
local bor    = bit.bor
local rshift = bit.rshift

local _M = { _VERSION = "0.03" }

local OP_TEXT   = 0x1
local OP_BINARY = 0x2

_M.OP_TEXT   = OP_TEXT
_M.OP_BINARY = OP_BINARY


-- server->client: FIN=1, never masked, so one frame serves every connection
function _M.frame(payload, opcode)
  opcode = opcode or OP_BINARY

  if opcode < 0 or opcode > 0xF or opcode ~= math.floor(opcode) then
    return nil, "bad opcode"
  end
  if band(opcode, 0x8) ~= 0 and #payload > 125 then
    return nil, "too much payload for control frame"
  end

  local len = #payload
  local b0 = char(bor(0x80, opcode))

  if len < 126 then
    return b0 .. char(len) .. payload
  end

  if len <= 0xffff then
    return b0 .. char(126, band(rshift(len, 8), 0xff),
                      band(len, 0xff)) .. payload
  end

  return b0 .. char(127, 0, 0, 0, 0,
                    band(rshift(len, 24), 0xff),
                    band(rshift(len, 16), 0xff),
                    band(rshift(len, 8),  0xff),
                    band(len, 0xff)) .. payload
end


-- Send an already-built frame to one lua-resty-websocket *server* object
-- with the shared-buffer path when available. Mirrors the original
-- library: refuses a connection already marked fatal, and sets wb.fatal
-- on failure. Call it from inside the request that owns wb: cosockets
-- are request-scoped in ngx_lua.
function _M.send_shared(wb, frame)
  if wb.fatal then
    return nil, "fatal error already happened"
  end

  local sock = wb.sock
  if not sock then
    return nil, "no socket"
  end

  local send = sock.send_ref or sock.send
  local bytes, err = send(sock, frame)
  if not bytes then
    wb.fatal = true
  end
  return bytes, err
end


return _M
