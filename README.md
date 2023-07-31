## WebSocket Server for Lua

[![Donate via Stripe](https://img.shields.io/badge/Donate-Stripe-green.svg)](https://buy.stripe.com/00gbJZ0OdcNs9zi288)<br>
[![Donate via Bitcoin](https://img.shields.io/badge/Donate-Bitcoin-green.svg)](bitcoin:37fsp7qQKU8XoHZGRQvVzQVP8FrEJ73cSJ)<br>

Uses the following:

- LuaSocket
- LuaCrypto or LuaOSSL
- LuaBitOp
- dkjson
- my Lua ext library
- my ThreadManager library

Timer is currently based on gettimeofday, which is loaded via LuaJIT's FFI, 
but if you wish to use non-FFI Lua you can use the `l_gettimeofday` lua binding function
(or even `os.clock` or `os.time` if you don't mind the resolution).

Also provides an AJAX fallback, but some specific client code must be used with this.

To recieve messages, override the Server class 
Ex:
``` Lua
local MyServer = class(require 'websocket.server')
```

To send messages, override the SimpleConn class and assign the new class to the server's connClass member.
Ex:
``` Lua
local MyConn = class(require 'websocket.simpleconn')
MyServer.connClass = MyConn
```

requires the `LUA_CPATH` to include the folder where websocket is installed.  I'm sure I will need to change the rockspec.
