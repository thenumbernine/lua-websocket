--[[
provides the basics of a conn class's interaction with both the server and the conn implementation
--]]

require 'ext'
local class = require 'ext.class'
local SimpleConn = class()

function SimpleConn:init(args)
	self.socketImpl = args.implClass(args)
	self.socketImpl.received = function(impl, ...)
		return self:received(...)
	end

	self.server = args.server
	self.uid = self.server:getNextConnUID()
	self.server.conns[self.uid] = self
end

function SimpleConn:isActive(...) return self.socketImpl:isActive(...) end
function SimpleConn:close(...) return self.socketImpl:close(...) end
function SimpleConn:send(msg) self.socketImpl:send(msg) end
function SimpleConn:received(data)
	print('received',data)
end



return SimpleConn

