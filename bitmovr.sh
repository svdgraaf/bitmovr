#!/usr/bin/env bash
lua=/usr/bin/lua5.1
ports=/etc/bitmovr/ports.conf

if [ $1 = 'start' ]
then
	for port in `cat $ports | awk '{print $2}'`
	do
		if [ "$port" != "backend" ] && [ "$port" != "" ]
		then
			$lua bitmovr.lua $port &
		fi
	done 
fi
if [ $1 = 'stop' ]
then
	killall lua5.1
fi
if [ $1 = 'restart' ]
then
	./bitmovr.sh stop;
	./bitmovr.sh start;
fi
