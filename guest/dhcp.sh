#!/bin/sh
set -eu
case "$1" in
    deconfig)
        ip -4 address flush dev "$interface"
        ;;
    bound|renew)
        ip -4 address replace "$ip/${mask:-$subnet}" dev "$interface"
        if [ -n "${router:-}" ]; then
            ip route replace default via "${router%% *}" dev "$interface"
        fi
        python3 /usr/local/lib/macosdocker/resolver_config.py ${dns:-}
        ;;
esac
