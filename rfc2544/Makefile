DIR=utils
lib:
	gcc -o $(DIR)/snmpc.so $(DIR)/snmpc.c -lsnmp -llua -Wall -fPIC -shared -I/usr/include/lua5.1
clean: 
	rm -f $(DIR)/snmpc.so

