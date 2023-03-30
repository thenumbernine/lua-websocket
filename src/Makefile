CFLAGS=-O2 -fpic -I/usr/local/include/lua-5.3

.PHONY: all
all: gettimeofday.so

gettimeofday.so: gettimeofday.o
	gcc -O -shared -fpic -o gettimeofday.so gettimeofday.o

gettimeofday.o:
	gcc ${CFLAGS} -c -o gettimeofday.o gettimeofday.c

.PHONY: clean
clean:
	-rm gettimeofday.so
	-rm gettimeofday.o
