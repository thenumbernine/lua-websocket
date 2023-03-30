-- [=[ using luajit ffi
local success, getTime = pcall(function()
	local ffi = require 'ffi'
	local gettimeofday_tv
	return function()
		if not gettimeofday_tv then
			ffi.cdef[[
typedef long time_t;
struct timeval {
	time_t tv_sec;
	time_t tv_usec;
};

int gettimeofday(struct timeval*, void*);
]]
			gettimeofday_tv = ffi.new('struct timeval')
		end
		local results = ffi.C.gettimeofday(gettimeofday_tv, nil)
		return tonumber(gettimeofday_tv.tv_sec) + tonumber(gettimeofday_tv.tv_usec) / 1000000
	end
end)
--print(success, getTime)
if success then 
	--print('using ffi gettimeofday')
	return getTime
end
--]=]

-- [=[ using .so
local success, getTime = pcall(function()
	-- lua cpath needs to match path
	local l_gettimeofday = require 'websocket.lib.gettimeofday'
	return function()
		local sec, usec = l_gettimeofday()
		return sec + usec / 1000000
	end
end)
--print(success, getTime)
if success then
	--print('using l_gettimeofday')
	return getTime
end
--]=]

--print'using default os.clock'
return os.clock
