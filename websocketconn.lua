local table = require 'ext.table'
local class = require 'ext.class'

local result
local bit = bit32
if not bit then
	result, bit = pcall(require, 'bit32')
end
if not bit then
	result, bit = pcall(require, 'bit')
end


local WebSocketConn = class()

--[[
args:
	server
	socket = luasocket
	received = function(socketimpl, msg) (optional)
--]]
function WebSocketConn:init(args)
	local sock = assert(args.socket)
	self.server = assert(args.server)
	self.socket = sock
	self.received = args.received
	
	self.listenThread = self.server.threads:add(self.listenCoroutine, self)
	self.readFrameThread = coroutine.create(self.readFrameCoroutine)	-- not part of the thread pool -- yielded manually with the next read byte
	coroutine.resume(self.readFrameThread, self)						-- position us to wait for the first byte
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
			if self.logging then
				print('readFrameCoroutine got',decoded)
			end
			-- now process 'decoded'
			self.server.threads:add(function()
				self:received(decoded)
			end)
		elseif opcode == FRAME_CLOSE then	-- connection close
			if self.logging then
				print('readFrameCoroutine got connection close')
			end
			local decoded = self:readFrameCoroutine_DecodeData()
			if self.logging then
				print('connection closed. reason ('..#decoded..'):',decoded)
			end
			self.done = true
			break
		elseif opcode == FRAME_PING then -- ping
			if self.logging then
				print('readFrameCoroutine got ping')
			end
		elseif opcode == FRAME_PONG then -- pong
			if self.logging then
				print('readFrameCoroutine got pong')
			end
		else
			error("got a reserved opcode: "..opcode)
		end
	end			
	if self.logging then
		print('readFrameCoroutine stopped')
	end
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
			local res, err = coroutine.resume(self.readFrameThread, b:byte())
			if not res then
				error(err..'\n'..debug.traceback(self.readFrameThread))
			end
		else
			if reason == 'timeout' then
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
	if self.logging then
		print('listenCoroutine stopped')
	end
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
	if self.logging then
		print('send',nmsg,msg)
	end
	if nmsg < 126 then
		local data = string.char(bit.bor(0x80, opcode))
			.. string.char(nmsg) 
			.. msg
		assert(#data == 2 + nmsg)
		
		self.socket:send(data)
	elseif nmsg < 65536 then
		local data = string.char(bit.bor(0x80, opcode))
			.. string.char(126)
			.. string.char(bit.band(bit.rshift(nmsg, 8), 0xff))
			.. string.char(bit.band(nmsg, 0xff))
			.. msg
		assert(#data == 4 + nmsg)
		
		self.socket:send(data)
	else
		-- [[ large frame ... not working?
		-- this seems to be identical to here: https://stackoverflow.com/questions/8125507/how-can-i-send-and-receive-websocket-messages-on-the-server-side
		-- but Chrome doesn't seem to receive the frame for size 118434
		if self.logging then
			print('sending large websocket frame')
		end
		local data = 
			string.char(bit.bor(0x80, opcode))
			.. string.char(127)
			.. string.char(bit.band(0xff, bit.rshift(nmsg, 56)))
			.. string.char(bit.band(0xff, bit.rshift(nmsg, 48)))
			.. string.char(bit.band(0xff, bit.rshift(nmsg, 40)))
			.. string.char(bit.band(0xff, bit.rshift(nmsg, 32)))
			.. string.char(bit.band(0xff, bit.rshift(nmsg, 24)))
			.. string.char(bit.band(0xff, bit.rshift(nmsg, 16)))
			.. string.char(bit.band(0xff, bit.rshift(nmsg, 8)))
			.. string.char(bit.band(0xff, nmsg))
			.. msg
		assert(#data == 10 + nmsg)
		self.socket:send(data)
		--]]
		--[[ multiple fragmented frames 
		-- ... it looks like the browser is sending the fragment headers to websocket onmessage? along with the frame data?
print('sending large websocket frame fragmented -- msg size',nmsg)
		local fragmentsize = 100
		--local fragmentsize = 1024
		--local fragmentsize = 65535
		local fragopcode = opcode
		for start=0,nmsg,fragmentsize do
			local len = fragmentsize
			if start + len > nmsg then len = nmsg - start end
			local headerbyte = fragopcode
			if start + len == nmsg then 
				headerbyte = bit.bor(headerbyte, 0x80)
			end
print('sending header '..headerbyte..' len '..len)
			local data
			if len < 126 then
				data = string.char(headerbyte)
					.. string.char(len) 
					.. msg:sub(start+1, start+len)
				assert(#data == 2 + len)
			else
				assert(len < 65536)
				data = string.char(headerbyte)
					.. string.char(126)
					.. string.char(bit.band(bit.rshift(len, 8), 0xff))
					.. string.char(bit.band(len, 0xff))
					.. msg:sub(start+1, start+len)
				assert(#data == 4 + len)
			end
			self:send(data)
			fragopcode = 0
		end
		--]]
		--[[ how come when I send fragmented messages, websocket .onmessage receives all the raw data of each of them, header and all?
		-- will that work if I just send the raw message as is? or does it only act that way when I don't want it to?
		self:send(msg)
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
