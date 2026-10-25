#!/usr/bin/env bash
# Starts the object server on the Colab VM and makes it reachable from the
# RoomTwin app's Object mode, through an SSH tunnel to this Mac's Wi-Fi address.
#
#   bash ObjectServer/start.sh
#
# Keep it running while you use Object mode; Ctrl-C stops the server and frees
# the GPU. Needs the colab CLI signed in, a Colab session (default name:
# roomtwin) prepared with Furniture/colab_setup.sh, and the phone on the same
# Wi-Fi as this Mac. If the phone is connected, the app is given the address
# and token; otherwise type them into the app (Object mode › server button).
set -eo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEVICE=${DEVICE:-893484B9-033A-5427-9561-A3DF76E94ACC}
APP=${APP:-dev.bugatti.RoomTwinLol}
SESSION=${SESSION:-roomtwin}
PORT=${PORT:-8765}
SSH=(ssh -o "ProxyCommand=$HOME/.local/bin/colab --auth=adc ssh --proxy-mode -s $SESSION"
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
HOST=root@$SESSION
TOKEN=${OBJECT_SERVER_TOKEN:-$(openssl rand -hex 16)}
ADDRESS=$(ipconfig getifaddr en0 || ipconfig getifaddr en1 || true)
[ -n "$ADDRESS" ] || { echo "this Mac has no Wi-Fi address"; exit 1; }
URL="http://$ADDRESS:$PORT"

echo "== uploading ObjectServer/ and Furniture/"
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf - -C "$ROOT" --exclude __pycache__ ObjectServer Furniture \
    | "${SSH[@]}" "$HOST" "cd /content && tar xzf -"

echo "== starting the server and generator"
"${SSH[@]}" "$HOST" "bash /content/ObjectServer/remote.sh start $TOKEN" > /dev/null
trap 'echo; echo "== stopping"; "${SSH[@]}" "$HOST" "bash /content/ObjectServer/remote.sh stop"' EXIT
for _ in $(seq 60); do
    "${SSH[@]}" "$HOST" "bash /content/ObjectServer/remote.sh health $TOKEN" > /dev/null 2>&1 && break
    sleep 3
done
"${SSH[@]}" "$HOST" "bash /content/ObjectServer/remote.sh health $TOKEN" > /dev/null \
    || { "${SSH[@]}" "$HOST" "tail -20 /content/objects/server.log"; exit 1; }
echo "   SAM 3 is ready; SAM 3D Objects takes about a minute more to load"

CONFIG=$(mktemp -d)/object-server.json
printf '{"url": "%s", "token": "%s"}\n' "$URL" "$TOKEN" > "$CONFIG"
if xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP" \
    --source "$CONFIG" --destination Library/object-server.json > /dev/null 2>&1; then
    echo "== sent the address and token to the phone"
else
    echo "== couldn't reach the phone; enter these in the app:"
    echo "   address $URL"
    echo "   token   $TOKEN"
fi
rm -f "$CONFIG"

echo "== serving on $URL (Ctrl-C to stop); logs: /content/objects/{server,generator}.log"
# caffeinate keeps the Mac awake so the tunnel stays up.
caffeinate -i "${SSH[@]}" -N -L "0.0.0.0:$PORT:127.0.0.1:8000" "$HOST"
