require 'ext'
local class = require 'ext.class'
local getTime = require 'websocket.gettimeofday'

local AjaxSocketConn = class()

AjaxSocketConn.timeout = 60	-- how long to timeout?

function AjaxSocketConn:init(args)
	-- no point in keeping track fo sockets -- they will change each ajax connect
	self.server = assert(args.server)
	self.sessionID = assert(args.sessionID)
	self.sendQueue = table()
	self.lastPollTime = getTime()
end

function AjaxSocketConn:isActive()
	return getTime() - self.lastPollTime < self.timeout 
end

function AjaxSocketConn:send(msg)
	--print('ajax sending size',#msg)
	self.sendQueue:insert(msg)
end

function AjaxSocketConn:poll(receiveQueue)
	-- update timestamp
	self.lastPollTime = getTime()
	
	-- first read the messages from the headers
	-- call self:received(msg) on each
	for _,msg in ipairs(receiveQueue) do
		self:received(msg)
	end

	-- next send the new stuff out
	local sendQueue = table()
	local sendQueueSize = 0
	local maxLen = 512 
	local partialPrefix = '(partial) '
	local partialEndPrefix = '(partialEnd) '
	while #self.sendQueue > 0 do
		local msg = self.sendQueue:remove(1)
		local remainingSize = maxLen - sendQueueSize
		if #msg < maxLen - sendQueueSize then
			-- granted this neglects json encoding data
			-- so lots of little values will throw it off
			sendQueueSize = sendQueueSize + #msg
			sendQueue:insert(msg)
		else
			-- might get multiple partialEnd's for multiply split msgs...
			if msg:sub(1,#partialEndPrefix) == partialEndPrefix then
				msg = msg:sub(#partialEndPrefix+1)
			end
			-- now send what we can and save the rest for later
			local partA = msg:sub(1,remainingSize)
			local partB = msg:sub(remainingSize+1)
			sendQueue:insert(partialPrefix..partA)
			self.sendQueue:insert(1, partialEndPrefix..partB)
			break
		end
	end

	return sendQueue 
end

-- called by the server?  when the conn is to go down?
-- does nothing ?
function AjaxSocketConn:close()
end

return AjaxSocketConn
