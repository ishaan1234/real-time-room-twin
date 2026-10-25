#!/usr/bin/env bash
# VM side of start.sh. Starts or stops the object server and the generator.
#
#   bash remote.sh start TOKEN
#   bash remote.sh stop
#   bash remote.sh health TOKEN
#
# Each process runs in its own process group, listed in /content/ObjectServer/pids,
# so stop only ends these two (and micromamba's child Python).
set -eo pipefail
HERE=/content/ObjectServer
OBJECTS=/content/objects
PIDS=$HERE/pids

stop() {
    [ -f "$PIDS" ] || return 0
    while read -r name pid; do
        kill -TERM -- "-$pid" 2>/dev/null && echo "stopped $name ($pid)" || true
    done < "$PIDS"
    rm -f "$PIDS" "$OBJECTS/generator.json"
}

case $1 in
    start)
        stop
        mkdir -p "$OBJECTS"
        cd "$HERE"
        OBJECT_SERVER_TOKEN=$2 setsid nohup /content/envs/sam3/bin/python server.py > "$OBJECTS/server.log" 2>&1 &
        echo "server $!" > "$PIDS"
        MAMBA_ROOT_PREFIX=/content/mamba setsid nohup micromamba run -n sam3d-objects python generator.py \
            > "$OBJECTS/generator.log" 2>&1 &
        echo "generator $!" >> "$PIDS"
        cat "$PIDS"
        ;;
    stop)
        stop
        ;;
    health)
        curl -sf -H "X-Token: $2" http://127.0.0.1:8000/health
        ;;
    *)
        echo "usage: remote.sh start TOKEN | stop | health TOKEN"
        exit 2
        ;;
esac
