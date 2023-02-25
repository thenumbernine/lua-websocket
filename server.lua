local table = require 'ext.table'
local class = require 'ext.class'
local file = require 'ext.file'
local socket = require 'socket'
local mime = require 'mime'
local json = require 'dkjson'
local ThreadManager = require 'threadmanager'
local WebSocketConn = require 'websocket.websocketconn'
local WebSocketHixieConn = require 'websocket.websockethixieconn'
local AjaxSocketConn = require 'websocket.ajaxsocketconn'
local digest = require 'websocket.digest'

local result
local bit = bit32
if not bit then
	result, bit = pcall(require, 'bit32')
end
if not bit then
	result, bit = pcall(require, 'bit')
end


-- coroutine function that blocks til it gets something
local function receiveBlocking(conn, waitduration, secondsTimerFunc)
	coroutine.yield()

	local endtime
	if waitduration then
		endtime = secondsTimerFunc() + waitduration
	end
	local data
	repeat
		coroutine.yield()
		local reason
		data, reason = conn:receive('*l')
		if not data then
			if reason == 'wantread' then
				socket.select({conn}, nil)
			else
				if reason ~= 'timeout' then
					return nil, reason		-- error() ?
				end
				-- else continue
				if waitduration and secondsTimerFunc() > endtime then
					return nil, 'timeout'
				end
			end
		end
	until data ~= nil

	return data
end

local function mustReceiveBlocking(conn, waitduration, secondsTimerFunc)
	local recv, reason = receiveBlocking(conn, waitduration, secondsTimerFunc)
	if not recv then error("Server waiting for handshake receive failed with error "..tostring(reason)) end
	return recv
end


local Server = class()

-- used for indexing conns, and mapping the Server.conns table keys
Server.nextConnUID = 1

-- class for instanciation of connections
Server.connClass = require 'websocket.simpleconn'

-- default port goes here
Server.port = 27000

-- TODO log levels
Server.logging = true

-- default always assume TLS
-- TODO detect?
Server.usetls = true

--[[
args:
	hostname - to be sent back via socket header
	threads = (optional) ThreadManager.  if you provide one then you have to update it manually.
	address (default is *)
	port (default is 27000)
	getTime (optional) = fraction-of-seconds-accurate timer function.  default requires either FFI or an external C binding or os.clock ... or you can provide your own.
--]]
function Server:init(args)
	args = args or {}
	self.port = args.port

	self.getTime = args.getTime or require 'websocket.gettimeofday'

	self.conns = table()
	self.ajaxConns = table()	-- mapped from sessionID

	self.threads = args.threads
	if not self.threads then
		self.threads = ThreadManager()
		self.ownThreads = true
	end

	local address = args.address or '*'
	self.hostname = assert(args.hostname, "expected hostname")
	if self.logging then
		print("hostname "..tostring(self.hostname))
		print("binding to "..tostring(address)..":"..tostring(self.port))
	end
	self.socket = assert(socket.bind(address, self.port))
	self.socketaddr, self.socketport = self.socket:getsockname()
	if self.logging then
		print('listening '..self.socketaddr..':'..self.socketport)
	end
	self.socket:settimeout(0, 'b')
end

function Server:getNextConnUID()
	local uid = self.nextConnUID
	self.nextConnUID = self.nextConnUID + 1
	return uid
end


function Server:update()
	socket.sleep(.001)

	-- listen for new connections
	local client = self.socket:accept()
	if client then
		if self.logging then
			print('got connection!',client)
			print('connection from', client:getpeername())
		end
		if self.logging then
			print(self.getTime(),'spawning new thread...')
		end
		self.threads:add(self.connectRemoteCoroutine, self, client)
	end

	-- now handle connections
	for i,conn in pairs(self.conns) do
		if not conn:isActive() then
			-- only remove conns here ... using the following ...
			if conn.onRemove then
				conn:onRemove()
			end
			if AjaxSocketConn:isa(conn.socketImpl) then
				assert(self.ajaxConns[conn.socketImpl.sessionID] == conn)
				self.ajaxConns[conn.socketImpl.sessionID] = nil
				if self.logging then
					print(self.getTime(),'removing ajax conn',conn.socketImpl.sessionID)
				end
			else
				if self.logging then
					print(self.getTime(),'removing websocket conn')
				end
			end
			self.conns[i] = nil
		else
			if conn.update then
				conn:update()
			end
		end
	end

	if self.ownThreads then
		self.threads:update()
	end
end

-- run loop
function Server:run()
	xpcall(function()
		while not self.done do
			self:update()
		end

		for _,conn in pairs(self.conns) do
			if conn.onRemove then
				conn:onRemove()
			end
			conn:close()	-- TODO should this be before onRemove() ?
		end
	end, function(err)
		self:traceback(err)
	end)
end

function Server:traceback(err)
	if err then io.stderr:write(err..'\n') end
	io.stderr:write(debug.traceback()..'\n')

	-- and all other threads?
	for _,thread in ipairs(self.threads.threads) do
		io.stderr:write('\n')
		io.stderr:write(tostring(thread)..'\n')
		io.stderr:write(debug.traceback(thread)..'\n')
	end

	io.stderr:flush()
end

function Server:delay(duration, callback, ...)
	local args = table.pack(...)
	local callingTrace = debug.traceback()
	self.threads:add(function()
		coroutine.yield()
		local thisTime = self.getTime()
		local startTime = thisTime
		local endTime = thisTime + duration
		repeat
			coroutine.yield()
			thisTime = self.getTime()
		until thisTime > endTime
		xpcall(function()
			callback(args:unpack())
		end, function(err)
			io.stderr:write(tostring(err)..'\n')
			io.stderr:write(debug.traceback())
			io.stderr:write(callingTrace)
		end)
	end)
end

local function be32ToStr(n)
	local s = ''
	for i=1,4 do
		s = string.char(bit.band(n, 0xff)) .. s
		n = bit.rshift(n, 8)
	end
	return s
end

-- create a remote connection
function Server:connectRemoteCoroutine(client)
	
	-- TODO all of this should be in the client handle coroutine
	-- [[ can I do this?
	-- from https://stackoverflow.com/questions/2833947/stuck-with-luasec-lua-secure-socket
	-- TODO need to specify cert files
	-- TODO but if you want to handle both https and non-https on different ports, that means two connections, that means better make non-blocking the default
	if self.usetls then
		if self.logging then
			print(self.getTime(),'upgrading to ssl...')
		end
		local ssl = require 'ssl'	-- package luasec
		-- TODO instead, just ask whoever is launching the server
		assert(self.hostname, "need the hostname to find the certs")
		local keyfile = '/etc/letsencrypt/live/'..self.hostname..'/privkey.pem'
		local certfile = '/etc/letsencrypt/live/'..self.hostname..'/cert.pem'
		if self.logging then
			print(self.getTime(), 'keyfile', keyfile, 'exists', file(keyfile):exists())
			print(self.getTime(), 'certfile', certfile, 'exists', file(certfile):exists())
		end
		assert(file(keyfile):exists())
		assert(file(certfile):exists())
		-- TODO hmmm 10 second block ...
		assert(client:settimeout(10))
		local err
		client, err = assert(ssl.wrap(client, {
			mode = 'server',
			options = {'all'},
			protocol = 'any',
			-- luasec 0.6:
			-- following: https://github.com/brunoos/luasec/blob/master/src/https.lua
			--protocol = 'all',
			--options = {'all', 'no_sslv2', 'no_sslv3', 'no_tlsv1'},
			key = keyfile,
			certificate = certfile,
			password = '12345',
			ciphers = 'ALL:!ADH:@STRENGTH',
		}))
		if self.logging then
			print(self.getTime(),'ssl.wrap response:', err)
			print(self.getTime(),'doing handshake...')
		end
		-- from https://github-wiki-see.page/m/brunoos/luasec/wiki/LuaSec-1.0.x
		-- also goes in receiveBlocking for conn:receive
		local result,reason
		while not result do
			coroutine.yield()
			result, reason = client:dohandshake()
			if self.logging then
				print(self.getTime(), 'dohandshake', result, reason)
			end
			if reason == 'wantread' then
				socket.select({client}, nil)
			end
			if reason == 'unknown state' then error('handshake conn in unknown state') end
		end
		if self.logging then
			print(self.getTime(), "dohandshake finished")
		end
	else
		-- hmm i guess this doesn't work for ssl.wrap connections (these is no setoption method) 
		client:setoption('keepalive', true)
		client:settimeout(0, 'b')	-- for the benefit of coroutines ...
	end
	--]]

	-- chrome has a bug where it connects and asks for a favicon even if there is none, or something, idk ...
	local firstLine, reason = receiveBlocking(client, 5, self.getTime)
	if self.logging then
		print(self.getTime(),client,'>>',firstLine,reason)
	end
	if not (firstLine == 'GET / HTTP/1.1' or firstLine == 'POST / HTTP/1.1') then
		if self.logging then
			print(self.getTime(),'got a non-http conn: ',firstLine)
		end
		return
	end

	local header = table()
	while true do
		local recv = mustReceiveBlocking(client, 1, self.getTime)
		if self.logging then
			print(self.getTime(),client,'>>',recv)
		end
		if recv == '' then break end
		local k,v = recv:match('^(.-): (.*)$')
		k = k:lower()
		header[k] = v
	end
	-- TODO make sure you got the right keys

	local cookies = table()
	if header.cookie then
		for kv in header.cookie:gmatch('(.-);%s?') do
			local k,v = kv:match('(.-)=(.*)')
			cookies[k] = v
		end
	end

	-- handle websockets
	-- IE doesn't give back an 'upgrade'
	if header.upgrade and header.upgrade:lower() == 'websocket' then

		local key1 = header['sec-websocket-key1']
		local key2 = header['sec-websocket-key2']
		if key1 and key2 then
			-- Hixie websockets
			-- http://www.whatwg.org/specs/web-socket-protocol/
			local spaces1 = select(2, key1:gsub(' ', ''))
			local spaces2 = select(2, key2:gsub(' ', ''))
			local digits1 = assert(tonumber((key1:gsub('%D', '')))) / spaces1
			local digits2 = assert(tonumber((key2:gsub('%D', '')))) / spaces2

			local body, err, partial = client:receive(tonumber(header['content-length']) or '*a')
			body = body or partial
			if self.logging then
				print(self.getTime(),client,'>>',body)
			end
			assert(#body == 8)

			local response = digest('md5', be32ToStr(digits1) .. be32ToStr(digits2) .. body, true)

			for _,line in ipairs{
				'HTTP/1.1 101 WebSocket Protocol Handshake\r\n',
				'Upgrade: WebSocket\r\n',
				'Connection: Upgrade\r\n',
				'Sec-WebSocket-Origin: http://'..self.hostname..'\r\n',
				'Sec-WebSocket-Location: ws://'..self.hostname..':'..self.socketport..'/\r\n',
				'Sec-WebSocket-Protocol: sample\r\n',
				'\r\n',
				response,
			} do
				if self.logging then
					print(self.getTime(),client,'<<',line:match('^(.*)\r\n$'))
				end
				client:send(line)
			end

			local serverConn = self.connClass{
				server = self,
				socket = client,
				implClass = WebSocketHixieConn,
			}
			self.lastActiveConnTime = self.getTime()
			return
		else
			-- RFC websockets

			local key = header['sec-websocket-key']
			local magic = key .. '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
			local sha1response = digest('sha1', magic, true)
			local response = mime.b64(sha1response)

			for _,line in ipairs{
				'HTTP/1.1 101 Switching Protocols\r\n',
				'Upgrade: websocket\r\n',
				'Connection: Upgrade\r\n',
				'Sec-WebSocket-Accept: '..response..'\r\n',
				'\r\n',
			} do
				if self.loggign then
					print(self.getTime(),client,'<<'..line:match('^(.*)\r\n$'))
				end
				client:send(line)
			end

			-- only add to Server.conns through *HERE*
			if self.logging then
				print(self.getTime(),'creating websocket conn')
			end
			local serverConn = self.connClass{
				server = self,
				socket = client,
				implClass = WebSocketConn,
			}
			serverConn.socketImpl.logging = self.logging
			if self.logging then
				print('constructing ServerConn',serverConn,'...')
			end
			self.lastActiveConnTime = self.getTime()
			return
		end
	end


	-- handle ajax connections

	local serverConn

	local body, err, partial = client:receive(tonumber(header['content-length']) or '*a')
	body = body or partial
	if self.logging then
		print(self.getTime(),client,'>>',body)
	end
	local receiveQueue = json.decode(body)
	local sessionID
	if not receiveQueue then
		if self.logging then
			print('failed to decode ajax body',body)
		end
		receiveQueue = {}
	else
		if #receiveQueue > 0 then
			local msg = receiveQueue[1]
			if msg:sub(1,10) == 'sessionID ' then
				table.remove(receiveQueue, 1)
				sessionID = msg:sub(11)
			end
		end
	end
	if self.logging then
		print('got session id', sessionID)
	end

	local newSessionID
	if sessionID then	-- if the client has a sessionID then ...
		-- see if the server has an ajax connection wrapper waiting ...
		serverConn = self.ajaxConns[sessionID]
		-- these are fake conn objects -- they merge multiple conns into one polling fake conn
		-- so headers and data need to be re-sent every time a new poll conn is made
	else
		newSessionID = true
		sessionID = mime.b64(digest('sha1', header:values():concat()..os.date(), true))
		if self.logging then
			print('generating session id', sessionID)
		end
	end
	-- no pre-existing connection? make a new one
	if serverConn then
		if self.logging then
			print(self.getTime(),'updating ajax conn')
		end
	else
		if self.logging then
			print(self.getTime(),'creating ajax conn',sessionID,newSessionID)
		end
		serverConn = self.connClass{
			server = self,
			implClass = AjaxSocketConn,
			sessionID = sessionID,
		}
		self.ajaxConns[sessionID] = serverConn
		self.lastActiveConnTime = self.getTime()
	end

	-- now hand it off to the serverConn to process sends & receives ...
	local responseQueue = serverConn.socketImpl:poll(receiveQueue)
	if newSessionID then
		table.insert(responseQueue, 1, 'sessionID '..sessionID)
	end
	local response = json.encode(responseQueue)

	if self.logging then
		print('sending ajax response size',#response,'body',response)
	end

	-- send response header
	local lines = table()
	lines:insert('HTTP/1.1 200 OK\r\n')
	lines:insert('Date '..os.date('!%a, %d %b %Y %T')..' GMT\r\n')
	lines:insert('Content-Type: text/plain\r\n') --droid4 default browser is mystery crashing... i suspect it cant handle json responses...
	lines:insert('Content-Length: '..#response..'\r\n')
	lines:insert('Access-Control-Allow-Origin: *\r\n')
	lines:insert('Connection: close\r\n')		-- IE needs this
	lines:insert('\r\n')
	lines:insert(response..'\r\n')

	for _,line in ipairs(lines) do
		if self.logging then
			print(client,'<<'..line:match('^(.*)\r\n$'))
		end
		client:send(line)
	end

	client:close()
end

return Server
