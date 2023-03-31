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



local Server = class()

-- used for indexing conns, and mapping the Server.conns table keys
Server.nextConnUID = 1

-- class for instanciation of connections
Server.connClass = require 'websocket.simpleconn'

-- default port goes here
Server.port = 27000

-- TODO log levels
Server.logging = false

-- whether to use TLS
Server.usetls = false

-- websocket size limit before fragmentation.  default = nil = use websocketconn class limit = infinite
Server.sizeLimitBeforeFragmenting = nil

-- how big the fragments should be.  default = nil = use class default.
Server.fragmentSize = nil

--[[
args:
	hostname - to be sent back via socket header
	threads = (optional) ThreadManager.  if you provide one then you have to update it manually.
	address (default is *)
	port (default is 27000)
	getTime (optional) = fraction-of-seconds-accurate timer function.  default requires either FFI or an external C binding or os.clock ... or you can provide your own.
	keyfile = ssl key file
	certfile = ssl cert file
		- if keyfile and certfile are set then usetls will be used
--]]
function Server:init(args)
	args = args or {}
	self.port = args.port
	if args.keyfile and args.certfile then
		self.usetls = true
		self.keyfile = args.keyfile
		self.certfile = args.certfile
	end
	if args.logging ~= nil then self.logging = args.logging end

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
self:log("hostname "..tostring(self.hostname))
self:log("binding to "..tostring(address)..":"..tostring(self.port))
	self.socket = assert(socket.bind(address, self.port))
	self.socketaddr, self.socketport = self.socket:getsockname()
self:log('listening '..self.socketaddr..':'..self.socketport)
	self.socket:settimeout(0, 'b')
end

function Server:getNextConnUID()
	local uid = self.nextConnUID
	self.nextConnUID = self.nextConnUID + 1
	return uid
end

function Server:fmtTime()
	local f = self.getTime()
	local i = math.floor(f)
	return os.date('%Y/%m/%d %H:%M:%S', os.time())..(('%.3f'):format(f-i):match('%.%d+') or '')
end

function Server:log(...)
	if not self.logging then return end
	print(self:fmtTime(), ...)
end


-- coroutine function that blocks til it gets something
function Server:receiveBlocking(conn, waitduration)
	coroutine.yield()

	local endtime
	if waitduration then
		endtime = self.getTime() + waitduration
	end
	local data
	repeat
		coroutine.yield()
		local reason
		data, reason = conn:receive('*l')
		if not data then
			if reason == 'wantread' then
--self:log('got wantread, calling select...')
				socket.select(nil, {conn})
--self:log('...done calling select')
			else
				if reason ~= 'timeout' then
					return nil, reason		-- error() ?
				end
				-- else continue
				if waitduration and self.getTime() > endtime then
					return nil, 'timeout'
				end
			end
		end
	until data ~= nil

	return data
end

function Server:mustReceiveBlocking(conn, waitduration)
	local recv, reason = self:receiveBlocking(conn, waitduration)
	if not recv then error("Server waiting for handshake receive failed with error "..tostring(reason)) end
	return recv
end

-- send and make sure you send everything, and error upon fail
function Server:send(conn, data)
self:log(conn, '<<', data)
	local i = 1
	while true do
		-- conn:send() successful response will be numberBytesSent, nil, nil, time
		-- conn:send() failed response will be nil, 'wantwrite', numBytesSent, time
self:log(conn, ' sending from '..i)
		local successlen, reason, faillen, time = conn:send(data:sub(i))	-- socket.send lets you use i,j as substring args, but does luasec's ssl.wrap ?
self:log(conn, '...', successlen, reason, faillen, time)
self:log(conn, '...getstats()', conn:getstats())
		if successlen ~= nil then
			assert(reason ~= 'wantwrite')	-- will wantwrite get set only if res[1] is nil?
self:log(conn, '...done sending')
			return successlen, reason, faillen, time
		end
		if reason ~= 'wantwrite' then
			error('socket.send failed: '..tostring(reason))
		end
		--socket.select({conn}, nil)	-- not good?
		-- try again
		i = i + faillen
	end
end

function Server:update()
	socket.sleep(.001)

	-- listen for new connections
	local client = self.socket:accept()
	if client then
self:log('got connection!',client)
self:log('connection from', client:getpeername())
self:log('spawning new thread...')
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
				if self.ajaxConns[conn.socketImpl.sessionID] ~= conn then
					-- or todo, dump all conns here?
self:log('session', conn.socketImpl.sessionID, 'overwriting old conn', conn, 'with', self.ajaxConns[conn.socketImpl.sessionID])
				else
					self.ajaxConns[conn.socketImpl.sessionID] = nil
self:log('removing ajax conn',conn.socketImpl.sessionID)
				end
			else
self:log('removing websocket conn')
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

	-- do I have to do this for the tls before wrapping the tls?
	-- or can I only do this in the non-tls branch?
	client:setoption('keepalive', true)
	client:settimeout(0, 'b')	-- for the benefit of coroutines ...

	-- TODO all of this should be in the client handle coroutine
	-- [[ can I do this?
	-- from https://stackoverflow.com/questions/2833947/stuck-with-luasec-lua-secure-socket
	-- TODO need to specify cert files
	-- TODO but if you want to handle both https and non-https on different ports, that means two connections, that means better make non-blocking the default
	if self.usetls then
self:log('upgrading to ssl...')
		local ssl = require 'ssl'	-- package luasec
		-- TODO instead, just ask whoever is launching the server
self:log('keyfile', self.keyfile, 'exists', file(self.keyfile):exists())
self:log('certfile', self.certfile, 'exists', file(self.certfile):exists())
		assert(file(self.keyfile):exists())
		assert(file(self.certfile):exists())
		local err
		client, err = assert(ssl.wrap(client, {
			mode = 'server',
			options = {'all'},
			protocol = 'any',
			-- luasec 0.6:
			-- following: https://github.com/brunoos/luasec/blob/master/src/https.lua
			--protocol = 'all',
			--options = {'all', 'no_sslv2', 'no_sslv3', 'no_tlsv1'},
			key = self.keyfile,
			certificate = self.certfile,
			password = '12345',
			ciphers = 'ALL:!ADH:@STRENGTH',
		}))
		assert(client:settimeout(0, 'b'))
		--client:setkeepalive()				-- nope
		--client:setoption('keepalive', true)	-- nope
self:log('ssl.wrap error:', err)
self:log('doing handshake...')
		-- from https://github-wiki-see.page/m/brunoos/luasec/wiki/LuaSec-1.0.x
		-- also goes in receiveBlocking for conn:receive
		local result,reason
		while not result do
			coroutine.yield()
			result, reason = client:dohandshake()
-- there can be a lot of these ...
--self:log('dohandshake', result, reason)
			if reason == 'wantread' then
--self:log('got wantread, calling select...')
				socket.select(nil, {client})
--self:log('...done calling select')
			end
			if reason == 'unknown state' then error('handshake conn in unknown state') end
		end
self:log("dohandshake finished")
	end
	--]]

	-- chrome has a bug where it connects and asks for a favicon even if there is none, or something, idk ...
	local firstLine, reason = self:receiveBlocking(client, 5)
self:log(client,'>>',firstLine,reason)
	if not (firstLine == 'GET / HTTP/1.1' or firstLine == 'POST / HTTP/1.1') then
self:log('got a non-http conn: ',firstLine)
		return
	end

	local header = table()
	while true do
		local recv = self:mustReceiveBlocking(client, 1)
self:log(client,'>>',recv)
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
self:log(client,'>>',body)
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
				self:send(client, line)
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
				self:send(client, line)
			end

			-- only add to Server.conns through *HERE*
self:log('creating websocket conn')
			local serverConn = self.connClass{
				server = self,
				socket = client,
				implClass = WebSocketConn,
				sizeLimitBeforeFragmenting = self.sizeLimitBeforeFragmenting,
				fragmentSize = self.fragmentSize,
			}
			serverConn.socketImpl.logging = self.logging
self:log('constructing ServerConn',serverConn,'...')
			self.lastActiveConnTime = self.getTime()
			return
		end
	end


	-- handle ajax connections

	local serverConn

	local body, err, partial = client:receive(tonumber(header['content-length']) or '*a')
	body = body or partial
self:log(client,'>>',body)
	local receiveQueue = json.decode(body)
	local sessionID
	if not receiveQueue then
self:log('failed to decode ajax body',body)
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
self:log('got session id', sessionID)

	local newSessionID
	if sessionID then	-- if the client has a sessionID then ...
		-- see if the server has an ajax connection wrapper waiting ...
		serverConn = self.ajaxConns[sessionID]
		-- these are fake conn objects -- they merge multiple conns into one polling fake conn
		-- so headers and data need to be re-sent every time a new poll conn is made
		if not serverConn then
self:log('NO CONN FOR ', sessionID)
		end
	else
		newSessionID = true
		sessionID = mime.b64(digest('sha1', header:values():concat()..os.date(), true))
self:log('no sessionID -- generating session id', sessionID)
	end
	-- no pre-existing connection? make a new one
	if serverConn then
self:log('updating ajax conn')
	else
self:log('creating ajax conn',sessionID,newSessionID)
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

self:log('sending ajax response size',#response,'body',response)

	-- send response header
	local lines = table()
	lines:insert('HTTP/1.1 200 OK')
	--lines:insert('Date: '..os.date('!%a, %d %b %Y %T')..' GMT')
	lines:insert('content-type: text/plain') --droid4 default browser is mystery crashing... i suspect it cant handle json responses...

	-- when I use this I get an error in Chrome: net::ERR_CONTENT_LENGTH_MISMATCH 200 (OK) ... so just don't use this?
	-- when I don't use this I get a truncated json message
	lines:insert('content-length: '..#response..'')

	lines:insert('pragma: no-cache')
	lines:insert('cache-control: no-cache, no-store, must-revalidate')
	lines:insert('expires: 0')

	lines:insert('access-control-allow-origin: *')	-- same url different port is considered cross-domain because reasons
	--lines:insert('Connection: close')		-- IE needs this
	lines:insert('')
	lines:insert(response)

	-- [[ send all at once
	local msg = lines:concat'\r\n'
	self:send(client, msg)
	--]]
	--[[ send line by line
	for i,line in ipairs(lines) do
		self:send(client, line..(i < #lines and '\r\n' or ''))
	end
	--]]
	--[[ send chunk by chunk.  does luasec or luasocket have a maximum send size?
	local msg = lines:concat'\r\n'
	local n = #msg
	local chunkSize = 4096
	for i=0,n-1,chunkSize do
		local len = math.min(chunkSize, n-i)
		local submsg = msg:sub(i+1, i+len)
		self:send(client, submsg)
	end
	--]]

	client:close()
end

return Server
