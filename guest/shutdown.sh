#!/bin/sh
set -eu
macosdocker-service docker stop
macosdocker-service containerd stop
macosdocker-service networking stop
