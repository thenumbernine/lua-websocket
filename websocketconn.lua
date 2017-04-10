local table = require 'ext.table'
local class = require 'ext.class'
local bit = bit32 or require 'bit'

local WebSocketConn = class()

--[[
args:
	server
	socket
	received = function(socketimpl, msg)
--]]
function WebSocketConn:init(args)
	local sock = assert(args.socket)
	self.server = assert(args.server)
	self.socket = sock
	self.received = assert(args.received)
	
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
--print('readFrameCoroutine got',decoded)
			-- now process 'decoded'
			self.server.threads:add(function()
				self:received(decoded)
			end)
		elseif opcode == FRAME_CLOSE then	-- connection close
--print('readFrameCoroutine got connection close')
			local decoded = self:readFrameCoroutine_DecodeData()
--print('connection closed. reason ('..#decoded..'):',decoded)
			self.done = true
			break
		elseif opcode == FRAME_PING then -- ping
--print('readFrameCoroutine got ping')
		elseif opcode == FRAME_PONG then -- pong
--print('readFrameCoroutine got pong')
		else
			error("got a reserved opcode: "..opcode)
		end
	end			
--print('readFrameCoroutine stopped')
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
--print('listenCoroutine stopped')
end

-- public 
function WebSocketConn:send(msg, opcode)
	if not opcode then opcode = FRAME_TEXT end
	local codebyte = string.char(bit.bor(0x80, opcode))

	-- upon sending this to the browser, the browser is sending back 6 chars and then crapping out
	--	no warnings given.  browser keeps acting like all is cool but it stops actually sending data afterwards. 
--print('send',#msg,msg)
	if #msg < 126 then
		local data = codebyte .. string.char(#msg) .. msg
		assert(#data == 2 + #msg)
		
		self.socket:send(data)
	elseif #msg < 65536 then
		local data = codebyte .. string.char(126)
			.. string.char(bit.band(bit.rshift(#msg, 8), 0xff))
			.. string.char(bit.band(#msg, 0xff))
			.. msg
		assert(#data == 4 + #msg)
		
		self.socket:send(data)
	else
		-- [[ large frame
		local data = codebyte .. string.char(127)
		local size = #msg
		local sizedata = ''
		for i=0,7 do
			sizedata = string.char(bit.band(size, 0xff)) .. sizedata
			size = bit.rshift(size, 8)
		end
		data = data .. sizedata
		data = data .. msg
		assert(#data == 10 + #msg)
		
		self.socket:send(data)
		--]]
		--[[ multiple frames ... browser doesnt register a frame and complains "must use largest size" ... 
--print('msg size',#msg)
		for start=1,#msg,65535 do
			local len = start + 65535
			if start + len > #msg then len = #msg - start end
			local data
			if start + len == #msg then 
				data = codebyte
			else 
				data = string.char(0x80)
			end
			if len < 126 then
				data = string.char(len) .. msg:sub(start, start+len-1)
				assert(#data == 2 + len)
			else
				data = data .. string.char(126)
					.. string.char(bit.band(bit.rshift(len, 8), 0xff))
					.. string.char(bit.band(len, 0xff))
					.. msg:sub(start, start+len-1)
				assert(#data == 4 + len)
			end
			self:send(data)
		end
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
