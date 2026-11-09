#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
while [ ! -f /run/macosdocker/boot.ready ]; do sleep 1; done
exec /usr/bin/python3 /usr/local/lib/macosdocker/agent.py
