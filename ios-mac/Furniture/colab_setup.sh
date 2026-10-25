#!/usr/bin/env bash
# Sets up a Colab GPU VM (A100 or H100; SAM 3D Objects needs >= 32 GB) for the
# furniture pipeline. Run once per VM:
#
#   HF_TOKEN=hf_... bash colab_setup.sh > /content/setup.log 2>&1
#
# SAM 3 and SAM 3D Objects need different Python and PyTorch versions, so each
# gets its own environment:
#   /content/envs/sam3                   Python 3.12, PyTorch 2.10 (uv venv)
#   /content/mamba/envs/sam3d-objects    Python 3.11, PyTorch 2.5.1, CUDA 12.1
#                                        (Meta's pinned conda environment)
set -eo pipefail
: "${HF_TOKEN:?set HF_TOKEN to a Hugging Face token with access to facebook/sam3 and facebook/sam-3d-objects}"
export HF_TOKEN
step() { echo "=== $(date +%T) $*"; }

cd /content
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
df -h /content | tail -1

step "SAM 3 environment"
command -v uv >/dev/null || pip install -q uv
[ -d sam3 ] || git clone -q --depth 1 https://github.com/facebookresearch/sam3
[ -x /content/envs/sam3/bin/python ] || uv venv -q -p 3.12 /content/envs/sam3
uv pip install -q --python /content/envs/sam3 torch==2.10.0 torchvision --index-url https://download.pytorch.org/whl/cu128
uv pip install -q --python /content/envs/sam3 -e /content/sam3 einops opencv-python-headless pycocotools scipy pillow psutil
/content/envs/sam3/bin/python -c "from huggingface_hub import snapshot_download; snapshot_download('facebook/sam3')"

step "micromamba"
export MAMBA_ROOT_PREFIX=/content/mamba
[ -x /usr/local/bin/micromamba ] || curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xj -C /usr/local bin/micromamba
[ -d sam-3d-objects ] || git clone -q --depth 1 https://github.com/facebookresearch/sam-3d-objects
cd sam-3d-objects

step "SAM 3D conda environment"
[ -d "$MAMBA_ROOT_PREFIX/envs/sam3d-objects" ] || micromamba create -y -q -f environments/default.yml
eval "$(micromamba shell hook -s bash)"
micromamba activate sam3d-objects
export CUDA_HOME=$CONDA_PREFIX FORCE_CUDA=1 MAX_JOBS=$(nproc)
# The repo also lists https://pypi.ngc.nvidia.com, which does not resolve from Colab and
# makes pip retry every package; nothing in the requirements needs it.
export PIP_EXTRA_INDEX_URL="https://download.pytorch.org/whl/cu121"
export PIP_PROGRESS_BAR=off

# The same three steps as the repo's doc/setup.md.
step "pip: core"
pip install -e '.[dev]'
step "pip: pytorch3d"
pip install -e '.[p3d]'
step "pip: inference"
export PIP_FIND_LINKS="https://nvidia-kaolin.s3.us-east-2.amazonaws.com/torch-2.5.1_cu121.html"
pip install -e '.[inference]'
./patching/hydra

step "SAM 3D checkpoints"
if [ ! -f checkpoints/hf/pipeline.yaml ]; then
    python -c "from huggingface_hub import snapshot_download; snapshot_download('facebook/sam-3d-objects', local_dir='checkpoints/hf-download')"
    mv checkpoints/hf-download/checkpoints checkpoints/hf
    rm -rf checkpoints/hf-download
fi

step "import check"
python -c "import torch, pytorch3d, kaolin, gsplat, spconv, flash_attn; print('torch', torch.__version__, 'cuda', torch.cuda.is_available())"
step "done"
