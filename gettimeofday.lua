--[=[ using .so
local l_gettimeofday = assert(package.loadlib('lib/gettimeofday.so', 'l_gettimeofday'))
local function gettimeofday()
	local sec, usec = l_gettimeofday()
	return sec + usec / 1000000
end
--]=]

-- [=[ using luajit ffi
local gettimeofday_tv
local function gettimeofday()
	local ffi = require 'ffi'
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
--]=]

return gettimeofday

