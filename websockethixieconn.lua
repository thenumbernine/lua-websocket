local table = require 'ext.table'
local class = require 'ext.class'
local bit = require 'bit'

local WebSocketHixieConn = class()

--[[
args:
	server
	socket
--]]
function WebSocketHixieConn:init(args)
	local sock = assert(args.socket)
	self.server = assert(args.server)
	self.socket = sock
	
	self.listenThread = self.server.threads:add(self.listenCoroutine, self)
	self.readFrameThread = coroutine.create(self.readFrameCoroutine)	-- not part of the thread pool -- yielded manually with the next read byte
	coroutine.resume(self.readFrameThread, self)						-- position us to wait for the first byte
end

-- public
function WebSocketHixieConn:isActive() 
	return coroutine.status(self.listenThread) ~= 'dead'
end

-- private
function WebSocketHixieConn:readFrameCoroutine()
	local data
	while not self.done and self.server and self.server.socket:getsockname() do
		local ch = coroutine.yield()
		if ch:byte() == 0 then	-- begin
			data = table()
		elseif ch:byte() == 0xff then -- end
			data = data:concat()
			print(getTime(),self.socket,'>>',data)
			self.server.threads:add(function()
				self:received(data)
			end)
			data = nil
		else
			assert(data, "recieved data outside of a frame")
			data:insert(ch)
		end
	end
end

-- private
function WebSocketHixieConn:listenCoroutine()
	coroutine.yield()
	
	while not self.done
	and self.server
	and self.server.socket:getsockname()
	do
		local b, reason = self.socket:receive(1)
		if b then
			--print(getTime(),self.socket,'>>',('%02x'):format(b:byte()))
			local res, err = coroutine.resume(self.readFrameThread, b)
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
function WebSocketHixieConn:send(msg)
	print(getTime(),self.socket,'<<',msg)
	self.socket:send(string.char(0x00) .. msg .. string.char(0xff))
end

-- public, abstract
function WebSocketHixieConn:received(cmd)
	print("todo implement me: ",cmd)
end

-- public
function WebSocketHixieConn:close(reason)
	if reason == nil then reason = '' end
	reason = tostring(reason)
	self:send(string.rep(string.char(0), 9))
	self.socket:close()
	self.done = true
end

return WebSocketHixieConn
