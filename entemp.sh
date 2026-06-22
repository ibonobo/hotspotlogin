#!/bin/sh
# entemp.sh — CPU temperature helper for uqlogent.sh
# Sourced at runtime by uqlogent.sh.
# use only if your router displays temperature sensor in the status page and you want it shown in the log.
# Place at /opt/etc/entemp.sh and chmod 600.

ROUTER_IP="192.168.2.1"
ROUTER_USER="login"
ROUTER_PASS="pass"

get_cpu_temp() {
    _t=$(curl -s --max-time 3 \
        -u "${ROUTER_USER}:${ROUTER_PASS}" \
        "http://${ROUTER_IP}/Status_Router.asp" 2>/dev/null \
        | grep -o 'cpu_temp0">[^<]*' \
        | sed 's/cpu_temp0">//' \
        | sed 's/[[:space:]]*&#[0-9]*;//' \
        | tr -d ' ')
    echo "${_t:-?}C"
}
