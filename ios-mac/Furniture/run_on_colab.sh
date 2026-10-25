#!/usr/bin/env bash
# Mac side of the furniture pipeline: phone -> Colab GPU -> back to scans/.
#
#   bash Furniture/run_on_colab.sh [SCAN_NAME] [steps...]
#
# SCAN_NAME is a RoomTwin-<date> folder in the app's Documents (default: the
# newest one). Steps default to all four (see run_pipeline.sh). Needs the
# phone connected, the colab CLI signed in, and a Colab session (default
# name: roomtwin) prepared with colab_setup.sh.
#
# Results land in scans/SCAN_NAME/twin/: room_twin.ply and .usdz (open the
# USDZ with Quick Look), the fitted objects, placement.json, and debug/ with
# the view each model was generated from.
set -eo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEVICE=${DEVICE:-893484B9-033A-5427-9561-A3DF76E94ACC}
APP=${APP:-dev.bugatti.RoomTwinLol}
SESSION=${SESSION:-roomtwin}
export PATH="$HOME/.local/bin:$PATH"
colab() { command colab --auth=adc "$@"; }
remote() { printf 'import subprocess\nprint(subprocess.run(%s, shell=True, capture_output=True, text=True).stdout)\n' \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" | colab exec -s "$SESSION"; }
device_files() {
    xcrun devicectl device info files --device "$DEVICE" --domain-type appDataContainer \
        --domain-identifier "$APP" --subdirectory "$1" 2>/dev/null
}

NAME=${1:-$(device_files Documents | grep -oE 'RoomTwin-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' | sort -u \
    | while read -r n; do device_files "Documents/$n" | grep -q keyframes.json && echo "$n"; done | tail -1)}
[ -n "$NAME" ] || { echo "no scan folder with keyframes on the phone"; exit 1; }
shift || true
LOCAL="$ROOT/scans/$NAME"
echo "== copying $NAME off the phone"
mkdir -p "$LOCAL"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP" \
    --source "Documents/$NAME" --destination "$LOCAL" > /dev/null
echo "   $(find "$LOCAL/keyframes" -name '*.jpg' | wc -l | tr -d ' ') keyframes, $(du -sh "$LOCAL" | cut -f1)"

echo "== uploading"
ARCHIVE=$(mktemp -d)/scan.tgz
tar czf "$ARCHIVE" -C "$ROOT/scans" --exclude twin "$NAME"
tar czf "${ARCHIVE%scan.tgz}furniture.tgz" -C "$ROOT" --exclude __pycache__ Furniture
remote "mkdir -p /content/scans" > /dev/null   # uploads fail with a 500 if the folder is missing
colab upload -s "$SESSION" "$ARCHIVE" "/content/scans/$NAME.tgz" > /dev/null
colab upload -s "$SESSION" "${ARCHIVE%scan.tgz}furniture.tgz" /content/furniture.tgz > /dev/null
remote "cd /content && tar xzf furniture.tgz && cd scans && tar xzf $NAME.tgz"

echo "== running on Colab (log: /content/scans/$NAME.log)"
TOKEN=$(cat ~/.cache/huggingface/token)
remote "cd /content/Furniture && HF_TOKEN=$TOKEN nohup bash run_pipeline.sh /content/scans/$NAME $* > /content/scans/$NAME.log 2>&1 &" > /dev/null
shown=0
while true; do
    sleep 20
    log=$(remote "cat /content/scans/$NAME.log; pgrep -f '[r]un_pipeline.sh' > /dev/null && echo __RUNNING__") || continue
    lines=$(printf '%s\n' "$log" | grep -E '^(=== |segment:|lift:|generate:|assemble:|Traceback|.*Error)' || true)
    printf '%s\n' "$lines" | tail -n +$((shown + 1)) | grep -v '^$' || true
    shown=$(printf '%s\n' "$lines" | wc -l)
    printf '%s\n' "$log" | grep -q '__RUNNING__' || break
done
printf '%s\n' "$log" | grep -q '^=== .* done' || { echo "pipeline failed; full log: /content/scans/$NAME.log"; exit 1; }

echo "== downloading results"
remote "cd /content/scans/$NAME && tar czf /content/scans/$NAME-twin.tgz twin debug objects.json generated"
colab download -s "$SESSION" "/content/scans/$NAME-twin.tgz" "$LOCAL/twin.tgz" > /dev/null
tar xzf "$LOCAL/twin.tgz" -C "$LOCAL" && rm "$LOCAL/twin.tgz"

RECONCHECK="$ROOT/build/DerivedData/Build/Products/Release/ReconCheck"
if [ ! -x "$RECONCHECK" ]; then
    xcodebuild -project "$ROOT/RoomTwin.xcodeproj" -scheme ReconCheck -configuration Release \
        -derivedDataPath "$ROOT/build/DerivedData" -destination 'platform=macOS' build > /dev/null
fi
"$RECONCHECK" usdz "$LOCAL/twin/room_twin.ply"
echo "== done: $LOCAL/twin/room_twin.usdz"
