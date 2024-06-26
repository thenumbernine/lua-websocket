local table = require 'ext.table'
local class = require 'ext.class'
local coroutine = require 'ext.coroutine'
local socket = require 'socket'

local result
local bit = bit32
if not bit then
	result, bit = pcall(require, 'bit32')
end
if not bit then
	result, bit = pcall(require, 'bit')
end


local WebSocketConn = class()

WebSocketConn.sizeLimitBeforeFragmenting = math.huge
WebSocketConn.fragmentSize = 100
--WebSocketConn.fragmentSize = 1024
--WebSocketConn.fragmentSize = 65535	-- NOTICE I don't have suport for >64k fragments yet

--[[
args:
	server
	socket = luasocket
	received = function(socketimpl, msg) (optional)
	sizeLimitBeforeFragmenting (optional)
	fragmentSize (optional)
--]]
function WebSocketConn:init(args)
	self.server = assert(args.server)
	self.socket = assert(args.socket)
	self.received = args.received
	self.sizeLimitBeforeFragmenting = args.sizeLimitBeforeFragmenting
	self.fragmentSize = args.fragmentSize

	self.listenThread = self.server.threads:add(self.listenCoroutine, self)
	self.readFrameThread = coroutine.create(self.readFrameCoroutine)	-- not part of the thread pool -- yielded manually with the next read byte
	coroutine.assertresume(self.readFrameThread, self)						-- position us to wait for the first byte
end

-- public
function WebSocketConn:isActive()
	return coroutine.status(self.listenThread) ~= 'dead'
end

-- private
function WebSocketConn:readFrameCoroutine_DecodeData()
	local sizeByte = coroutine.yield()
	local useMask = bit.band(sizeByte, 0x80) ~= 0
	local size = bit.band(sizeByte, 0x7f)
	if size == 127 then
		size = 0
		for i=1,8 do
			size = bit.lshift(size, 8)
			size = bit.bor(size, coroutine.yield())	-- are lua bit ops 64 bit?  well, bit32 is not for sure.
		end
	elseif size == 126 then
		size = 0
		for i=1,2 do
			size = bit.lshift(size, 8)
			size = bit.bor(size, coroutine.yield())
		end
	end

	assert(useMask, "expected all received frames to use mask")
	if useMask then
		local mask = table()
		for i=1,4 do
			mask[i] = coroutine.yield()
		end

		local decoded = table()
		for i=1,size do
			decoded[i] = string.char(bit.bxor(mask[(i-1)%4+1], coroutine.yield()))
		end
		return decoded:concat()
	end
end

local FRAME_CONTINUE = 0
local FRAME_TEXT = 1
local FRAME_DATA = 2
local FRAME_CLOSE = 8
local FRAME_PING = 9
local FRAME_PONG = 10

-- private
function WebSocketConn:readFrameCoroutine()
	while not self.done
	and self.server
	and self.server.socket:getsockname()
	do
		-- this is blocking ...
		local op = coroutine.yield()
		local fin = bit.band(op, 0x80) ~= 0
		local reserved1 = bit.band(op, 0x40) ~= 0
		local reserved2 = bit.band(op, 0x20) ~= 0
		local reserved3 = bit.band(op, 0x10) ~= 0
		local opcode = bit.band(op, 0xf)
		assert(not reserved1)
		assert(not reserved2)
		assert(not reserved3)
		assert(fin)	-- TODO handle continuations
		if opcode == FRAME_CONTINUE then	-- continuation frame
			error('readFrameCoroutine got continuation frame')	-- TODO handle continuations
		elseif opcode == FRAME_TEXT or opcode == FRAME_DATA then	-- new text/binary frame
			local decoded = self:readFrameCoroutine_DecodeData()
--DEBUG:print('readFrameCoroutine got',decoded)
			-- now process 'decoded'
			self.server.threads:add(function()
				self:received(decoded)
			end)
		elseif opcode == FRAME_CLOSE then	-- connection close
--DEBUG:print('readFrameCoroutine got connection close')
			local decoded = self:readFrameCoroutine_DecodeData()
--DEBUG:print('connection closed. reason ('..#decoded..'):',decoded)
			self.done = true
			break
		elseif opcode == FRAME_PING then -- ping
--DEBUG:print('readFrameCoroutine got ping')
			-- TODO send FRAME_PONG response?
		elseif opcode == FRAME_PONG then -- pong
--DEBUG:print('readFrameCoroutine got pong')
		else
			error("got a reserved opcode: "..opcode)
		end
	end
--DEBUG:print('readFrameCoroutine stopped')
end

-- private
function WebSocketConn:listenCoroutine()
	coroutine.yield()

	while not self.done
	and self.server
	and self.server.socket:getsockname()
	do
		local b, reason = self.socket:receive(1)
		if b then
			coroutine.assertresume(self.readFrameThread, b:byte())
		else
			if reason == 'wantread' then
				-- luasec case
--DEBUG:print('got wantread, calling select...')
				socket.select(nil, {self.socket})
--DEBUG:print('...done calling select')
			elseif reason == 'timeout' then
			elseif reason == 'closed' then
				self.done = true
				break
			else
				error(reason)
			end
		end
		-- TODO sleep

		coroutine.yield()
	end

	-- one thread needs responsibility to close ...
	self:close()
--DEBUG:print('listenCoroutine stopped')
end

-- public
function WebSocketConn:send(msg, opcode)
	if not opcode then
		opcode = FRAME_TEXT
		--opcode = FRAME_DATA
	end

	-- upon sending this to the browser, the browser is sending back 6 chars and then crapping out
	--	no warnings given.  browser keeps acting like all is cool but it stops actually sending data afterwards.
	local nmsg = #msg
--DEBUG:print('send',nmsg,msg)
	if nmsg < 126 then
		local data = string.char(
			bit.bor(0x80, opcode),
			nmsg)
			.. msg
		assert(#data == 2 + nmsg)

		self.server:send(self.socket, data)
	elseif nmsg >= self.sizeLimitBeforeFragmenting then
		-- multiple fragmented frames
		-- ... it looks like the browser is sending the fragment headers to websocket onmessage? along with the frame data?
--DEBUG:print('sending large websocket frame fragmented -- msg size',nmsg)
		local fragopcode = opcode
		for start=0,nmsg-1,self.fragmentSize do
			local len = self.fragmentSize
			if start + len >= nmsg then len = nmsg - start end
			local headerbyte = fragopcode
			if start + len == nmsg then
				headerbyte = bit.bor(headerbyte, 0x80)
			end
--DEBUG:print('sending header '..headerbyte..' len '..len)
			local data
			if len < 126 then
				data = string.char(
					headerbyte,
					len)
					.. msg:sub(start+1, start+len)
				assert(#data == 2 + len)
				self.server:send(self.socket, data)
			else
				assert(len < 65536)
				data = string.char(
					headerbyte,
					126,
					bit.band(bit.rshift(len, 8), 0xff),
					bit.band(len, 0xff))
					.. msg:sub(start+1, start+len)
				assert(#data == 4 + len)
				self.server:send(self.socket, data)
			end
			fragopcode = 0
		end

	elseif nmsg < 65536 then
		local data = string.char(
			bit.bor(0x80, opcode),
			126,
			bit.band(bit.rshift(nmsg, 8), 0xff),
			bit.band(nmsg, 0xff))
			.. msg
		assert(#data == 4 + nmsg)

		self.server:send(self.socket, data)

	else
		-- large frame ... not working?
		-- these work fine localhost / non-tls
		-- but when I use tls / Chrome doesn't seem to receive
--DEBUG:print('sending large websocket frame of size', nmsg)
		local data = string.char(
			bit.bor(0x80, opcode),
			127,
--[[ luaresty's websockets limit size at 2gb ...
			bit.band(0xff, bit.rshift(nmsg, 56)),
			bit.band(0xff, bit.rshift(nmsg, 48)),
			bit.band(0xff, bit.rshift(nmsg, 40)),
			bit.band(0xff, bit.rshift(nmsg, 32)),
--]]
-- [[
			0,0,0,0,
--]]
			bit.band(0xff, bit.rshift(nmsg, 24)),
			bit.band(0xff, bit.rshift(nmsg, 16)),
			bit.band(0xff, bit.rshift(nmsg, 8)),
			bit.band(0xff, nmsg))
			.. msg
		assert(#data == 10 + nmsg)
		self.server:send(self.socket, data)
		--]]
	end
end

-- public, abstract
function WebSocketConn:received(cmd)
	print("todo implement me: ",cmd)
end

-- public
function WebSocketConn:close(reason)
	if reason == nil then reason = '' end
	reason = tostring(reason)
	self:send('goodbye', FRAME_CLOSE)
	self.socket:close()
	self.done = true
end

return WebSocketConn
