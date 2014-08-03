/*
gcc -O2 -fpic -c -o gettimeofday.o gettimeofday.c -I/home1/chrisup3/include
gcc -O -shared -fpic -o gettimeofday.so gettimeofday.o
c
*/
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
