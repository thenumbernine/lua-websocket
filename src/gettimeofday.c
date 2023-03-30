#include <sys/time.h>
#include <stdlib.h>
#include <time.h>
#include <lua.h>

int l_gettimeofday(lua_State *L) {
	struct timeval tv;
	gettimeofday(&tv, NULL);
	lua_pushnumber(L, tv.tv_sec);
	lua_pushnumber(L, tv.tv_usec);
	return 2;
}

int luaopen_websocket_lib_gettimeofday(lua_State *L) {
	lua_pushcfunction(L, l_gettimeofday);
	return 1;
}
