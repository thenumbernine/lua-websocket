[![paypal](https://www.paypalobjects.com/en_US/i/btn/btn_donateCC_LG.gif)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=KYWUWS86GSFGL)

## WebSocket server for Lua

uses the following:

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
```
local MyServer = class(require 'websocket.server')
```

To send messages, override the SimpleConn class and assign the new class to the server's connClass member.
Ex:
```
MyConn = class(require 'websocket.simpleconn')
MyServer.connClass = MyConn
```
