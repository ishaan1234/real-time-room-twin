#!/usr/bin/env bash
# Runs the furniture pipeline on a Colab VM prepared by colab_setup.sh:
#
#   HF_TOKEN=hf_... bash run_pipeline.sh /content/scans/RoomTwin-... [steps...]
#
# Steps, in order (default: all four):
#   segment   SAM 3 masks for every keyframe              (SAM 3 env)
#   lift      scan vertices -> objects, best view each    (SAM 3 env)
#   generate  SAM 3D Objects model per object, posed      (SAM 3D env)
#   assemble  fit models, cut scanned furniture, merge    (SAM 3 env)
set -eo pipefail
SCAN=${1:?usage: run_pipeline.sh SCAN_DIR [segment|lift|generate|assemble ...]}
shift
STEPS=${*:-segment lift generate assemble}
HERE=$(cd "$(dirname "$0")" && pwd)
SAM3=/content/envs/sam3/bin/python
export MAMBA_ROOT_PREFIX=/content/mamba
cd "$HERE"
for step in $STEPS; do
    echo "=== $(date +%T) $step"
    case $step in
        segment|lift|assemble) $SAM3 "$step.py" "$SCAN" ;;
        generate) micromamba run -n sam3d-objects python generate.py "$SCAN" ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac
done
echo "=== $(date +%T) done"
