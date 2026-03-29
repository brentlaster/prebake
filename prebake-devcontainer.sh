#!/usr/bin/env bash
#
# prebake-devcontainer.sh
# =======================
# Transforms a repo's devcontainer setup to use a pre-built Docker image.
# Produces two branch variants:
#
#   --mode image  : devcontainer.json references a GHCR pre-built image
#                   (fast startup, requires image push access)
#
#   --mode fork   : devcontainer.json uses "build" with the generated
#                   Dockerfile (works in forks without GHCR access)
#
#   --mode both   : creates both branches (default)
#
# The script:
#   1. Reads a source devcontainer.json (original format with "image" + "features")
#   2. Generates a Dockerfile that bakes all dependencies into the image
#   3. Creates git branch(es) with the transformed devcontainer.json
#   4. Generates IMAGE-MAINTENANCE.md with rebuild/push instructions
#   5. Prints next-step commands
#
# Usage:
#   cd /path/to/your/repo
#   bash scripts/prebake-devcontainer.sh [OPTIONS]
#
# Options:
#   --mode image|fork|both   Which variant(s) to generate (default: both)
#   --source FILE            Source devcontainer.json (default: auto-detect)
#   --ghcr-org ORG           GitHub org/user for GHCR (default: from git remote)
#   --image-name NAME        Image name on GHCR (default: <repo>-devcontainer)
#   --image-branch NAME      Branch name for image variant (default: devcontainer-image)
#   --fork-branch NAME       Branch name for fork variant (default: devcontainer-fork)
#   --base-branch NAME       Branch to create new branches from (default: current branch)
#   --no-prompt              Skip interactive prompts, use defaults/args only
#   -h, --help               Show this help
#
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}▸${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }
header(){ echo -e "\n${BOLD}── $* ──${NC}"; }

# ── Defaults ──────────────────────────────────────────────────────────
MODE="both"
SOURCE_JSON=""
GHCR_ORG=""
IMAGE_NAME=""
IMAGE_BRANCH="devcontainer-image"
FORK_BRANCH="devcontainer-fork"
BASE_BRANCH=""
NO_PROMPT=0
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DEVCONTAINER_DIR="$REPO_ROOT/.devcontainer"

# ── Parse arguments ───────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --mode)         MODE="$2"; shift 2 ;;
        --source)       SOURCE_JSON="$2"; shift 2 ;;
        --ghcr-org)     GHCR_ORG="$2"; shift 2 ;;
        --image-name)   IMAGE_NAME="$2"; shift 2 ;;
        --image-branch) IMAGE_BRANCH="$2"; shift 2 ;;
        --fork-branch)  FORK_BRANCH="$2"; shift 2 ;;
        --base-branch)  BASE_BRANCH="$2"; shift 2 ;;
        --no-prompt)    NO_PROMPT=1; shift ;;
        -h|--help)
            sed -n '/^# prebake/,/^[^#]/{/^#/{ s/^# //; s/^#//; p; }}' "$0"
            exit 0
            ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate mode
case "$MODE" in
    image|fork|both) ;;
    *) err "Invalid --mode: $MODE (must be image, fork, or both)"; exit 1 ;;
esac

# ── Helper: prompt with default ───────────────────────────────────────
prompt_val() {
    local varname="$1" prompt_text="$2" default="$3"
    local current_val="${!varname}"
    if [[ -n "$current_val" ]]; then
        return  # already set via CLI arg
    fi
    if [[ $NO_PROMPT -eq 1 ]]; then
        eval "$varname=\"$default\""
        return
    fi
    local input
    read -r -p "$(echo -e "${CYAN}?${NC}") $prompt_text [${BOLD}$default${NC}]: " input
    eval "$varname=\"${input:-$default}\""
}

# ── Preflight checks ─────────────────────────────────────────────────
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    err "Not inside a git repository. Run this from within a git repo."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    err "python3 is required (used for JSON parsing)."
    exit 1
fi

# ── Find source devcontainer.json ─────────────────────────────────────
if [[ -z "$SOURCE_JSON" ]]; then
    # Try to find the original (unmodified) devcontainer.json
    if [[ -f "$DEVCONTAINER_DIR/devcontainer-original.json" ]]; then
        SOURCE_JSON="$DEVCONTAINER_DIR/devcontainer-original.json"
        info "Auto-detected source: $SOURCE_JSON"
    elif [[ -f "$DEVCONTAINER_DIR/devcontainer.json" ]]; then
        SOURCE_JSON="$DEVCONTAINER_DIR/devcontainer.json"
        info "Using source: $SOURCE_JSON"
    else
        err "No devcontainer.json found. Provide one with --source."
        exit 1
    fi
fi

if [[ ! -f "$SOURCE_JSON" ]]; then
    err "Source file not found: $SOURCE_JSON"
    exit 1
fi

# ── Derive defaults from git remote ──────────────────────────────────
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
GIT_ORG="" GIT_REPO=""
if [[ -n "$REMOTE_URL" ]]; then
    REPO_SLUG=$(echo "$REMOTE_URL" | sed -E 's#.+github\.com[:/]##; s/\.git$//')
    GIT_ORG=$(echo "$REPO_SLUG" | cut -d/ -f1)
    GIT_REPO=$(echo "$REPO_SLUG" | cut -d/ -f2)
fi

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "main")
[[ -z "$BASE_BRANCH" ]] && BASE_BRANCH="$CURRENT_BRANCH"

# ── Interactive prompts ───────────────────────────────────────────────
header "Configuration"

prompt_val GHCR_ORG    "GHCR org/username"               "${GIT_ORG:-myorg}"
prompt_val IMAGE_NAME  "GHCR image name"                  "${GIT_REPO:+${GIT_REPO}-devcontainer}"

if [[ -z "$IMAGE_NAME" ]]; then
    IMAGE_NAME="devcontainer"
fi

FULL_IMAGE="ghcr.io/${GHCR_ORG}/${IMAGE_NAME}:latest"

if [[ "$MODE" == "image" || "$MODE" == "both" ]]; then
    prompt_val IMAGE_BRANCH "Branch name for image variant"  "$IMAGE_BRANCH"
fi
if [[ "$MODE" == "fork" || "$MODE" == "both" ]]; then
    prompt_val FORK_BRANCH  "Branch name for fork variant"   "$FORK_BRANCH"
fi
prompt_val BASE_BRANCH "Base branch to create from"        "$BASE_BRANCH"

# ── Banner ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  prebake-devcontainer${NC}"
echo -e "${BOLD}============================================================${NC}"
echo -e "  Repo root:     $REPO_ROOT"
echo -e "  Source:        $SOURCE_JSON"
echo -e "  GHCR image:    $FULL_IMAGE"
echo -e "  Mode:          $MODE"
if [[ "$MODE" == "image" || "$MODE" == "both" ]]; then
    echo -e "  Image branch:  $IMAGE_BRANCH"
fi
if [[ "$MODE" == "fork" || "$MODE" == "both" ]]; then
    echo -e "  Fork branch:   $FORK_BRANCH"
fi
echo -e "  Base branch:   $BASE_BRANCH"
echo -e "${BOLD}============================================================${NC}"
echo ""

if [[ $NO_PROMPT -eq 0 ]]; then
    read -r -p "$(echo -e "${CYAN}?${NC}") Proceed? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# ── Detect current setup from source JSON ─────────────────────────────
header "Analyzing source devcontainer.json"

PARSE_TMPFILE=$(mktemp)
python3 << PYEOF > "$PARSE_TMPFILE"
import json, re, sys, shlex

with open("$SOURCE_JSON") as f:
    text = f.read()

# Strip JS-style comments and trailing commas (JSONC -> JSON)
text = re.sub(r'//.*', '', text)
text = re.sub(r',\s*([\]}])', r'\1', text)
data = json.loads(text)

base_image = data.get('image', '')
has_build = '1' if 'build' in data else '0'
features = ' '.join(data.get('features', {}).keys())
post_create = data.get('postCreateCommand', '')

print(f'BASE_IMAGE={shlex.quote(base_image)}')
print(f'HAS_BUILD={has_build}')
print(f'FEATURES={shlex.quote(features)}')
print(f'POST_CREATE={shlex.quote(post_create)}')
PYEOF

source "$PARSE_TMPFILE"
rm -f "$PARSE_TMPFILE"

info "Base image:        ${BASE_IMAGE:-<none - uses build>}"
info "Has Dockerfile:    $([ "$HAS_BUILD" = "1" ] && echo "yes" || echo "no")"
info "Features:          $FEATURES"
info "postCreateCommand: $POST_CREATE"

# ── Detect dependencies ──────────────────────────────────────────────
header "Scanning dependencies"

HAS_PYTHON_REQS=0
HAS_PYPROJECT=0
HAS_PACKAGE_JSON=0
PYTHON_FEATURE=0
NODE_FEATURE=0
HAS_PYTORCH=0
HAS_SENTENCE_TRANSFORMERS=0

[[ -f "$REPO_ROOT/requirements.txt" ]] && HAS_PYTHON_REQS=1 && ok "requirements.txt"
[[ -f "$REPO_ROOT/pyproject.toml" ]]   && HAS_PYPROJECT=1    && ok "pyproject.toml"
[[ -f "$REPO_ROOT/package.json" ]]     && HAS_PACKAGE_JSON=1  && ok "package.json"

echo "$FEATURES" | grep -qi "python" && PYTHON_FEATURE=1
echo "$FEATURES" | grep -qi "node"   && NODE_FEATURE=1

if [[ $HAS_PYTHON_REQS -eq 1 ]] && grep -qi "sentence.transformers" "$REPO_ROOT/requirements.txt"; then
    HAS_SENTENCE_TRANSFORMERS=1
    ok "sentence-transformers detected"
fi

# PyTorch can be a direct dep or a transitive dep (via sentence-transformers, etc.)
if [[ $HAS_PYTHON_REQS -eq 1 ]]; then
    if grep -qi "torch" "$REPO_ROOT/requirements.txt" || [[ $HAS_SENTENCE_TRANSFORMERS -eq 1 ]]; then
        HAS_PYTORCH=1
        ok "PyTorch dependency detected (direct or transitive via sentence-transformers)"
    fi
fi

# Check for Ollama references in scripts
HAS_OLLAMA=0
if echo "$POST_CREATE" | grep -qi "ollama"; then
    HAS_OLLAMA=1
    ok "Ollama detected in postCreateCommand"
fi

# ── Detect scripts that may re-download deps ──────────────────────────
header "Checking postCreateCommand scripts"

POST_CREATE_CLEAN=$(echo "$POST_CREATE" | tr -d "'\"")
HAS_PIP_IN_POST=0
if [[ -n "$POST_CREATE_CLEAN" ]]; then
    for script in $(echo "$POST_CREATE_CLEAN" | grep -oE '[^ ]+\.sh'); do
        # Strip any args after the script name
        script_path="$REPO_ROOT/$script"
        if [[ -f "$script_path" ]]; then
            if grep -qE 'pip.*install.*(--upgrade|torch|requirements)' "$script_path" 2>/dev/null; then
                HAS_PIP_IN_POST=1
                warn "$script contains pip install commands."
                warn "Ensure they only run when /opt/py_env is missing (fallback path)."
            fi
        fi
    done
fi
if [[ $HAS_PIP_IN_POST -eq 0 ]]; then
    ok "No re-download issues detected."
fi

# ── Determine base image for Dockerfile ──────────────────────────────
DOCKERFILE_BASE="$BASE_IMAGE"
if [[ -z "$DOCKERFILE_BASE" || "$DOCKERFILE_BASE" == "''" || "$DOCKERFILE_BASE" == "None" ]]; then
    DOCKERFILE_BASE="mcr.microsoft.com/devcontainers/base:bookworm"
fi
# Strip surrounding quotes
DOCKERFILE_BASE=$(echo "$DOCKERFILE_BASE" | tr -d "'\"")

# ── Generate Dockerfile content ───────────────────────────────────────
header "Generating Dockerfile"

DOCKERFILE_CONTENT=""

# Header
DOCKERFILE_CONTENT+="FROM $DOCKERFILE_BASE"$'\n'
DOCKERFILE_CONTENT+=""$'\n'

# Base packages
APT_PACKAGES="zstd curl ca-certificates"
if [[ $HAS_PYTHON_REQS -eq 1 || $PYTHON_FEATURE -eq 1 ]]; then
    APT_PACKAGES+=" python3 python3-venv python3-pip"
fi

DOCKERFILE_CONTENT+="# Install prerequisites"$'\n'
DOCKERFILE_CONTENT+="RUN apt-get update && \\"$'\n'
DOCKERFILE_CONTENT+="    apt-get install -y --no-install-recommends \\"$'\n'
DOCKERFILE_CONTENT+="        $APT_PACKAGES && \\"$'\n'
DOCKERFILE_CONTENT+="    rm -rf /var/lib/apt/lists/*"$'\n'

# Python venv with dependencies
if [[ $HAS_PYTHON_REQS -eq 1 ]]; then
    DOCKERFILE_CONTENT+=""$'\n'
    if [[ $HAS_PYTORCH -eq 1 ]]; then
        DOCKERFILE_CONTENT+="# Pre-build the Python virtual environment"$'\n'
        DOCKERFILE_CONTENT+="# Install CPU-only PyTorch FIRST to avoid pulling in GPU/triton packages"$'\n'
        DOCKERFILE_CONTENT+="COPY requirements.txt /tmp/requirements.txt"$'\n'
        DOCKERFILE_CONTENT+="RUN python3 -m venv /opt/py_env && \\"$'\n'
        DOCKERFILE_CONTENT+="    /opt/py_env/bin/pip install --no-cache-dir \\"$'\n'
        DOCKERFILE_CONTENT+="        torch torchvision torchaudio \\"$'\n'
        DOCKERFILE_CONTENT+="        --index-url https://download.pytorch.org/whl/cpu && \\"$'\n'
        DOCKERFILE_CONTENT+="    /opt/py_env/bin/pip install --no-cache-dir -r /tmp/requirements.txt && \\"$'\n'
        DOCKERFILE_CONTENT+="    /opt/py_env/bin/pip uninstall -y \\"$'\n'
        DOCKERFILE_CONTENT+="        triton nvidia-cublas-cu12 nvidia-cuda-cupti-cu12 \\"$'\n'
        DOCKERFILE_CONTENT+="        nvidia-cuda-nvrtc-cu12 nvidia-cuda-runtime-cu12 \\"$'\n'
        DOCKERFILE_CONTENT+="        nvidia-cufft-cu12 nvidia-cufile-cu12 \\"$'\n'
        DOCKERFILE_CONTENT+="        nvidia-curand-cu12 nvidia-cusparse-cu12 \\"$'\n'
        DOCKERFILE_CONTENT+="        nvidia-cusparselt-cu12 nvidia-nccl-cu12 \\"$'\n'
        DOCKERFILE_CONTENT+="        nvidia-nvjitlink-cu12 nvidia-nvshmem-cu12 \\"$'\n'
        DOCKERFILE_CONTENT+="        nvidia-nvtx-cu12 2>/dev/null || true && \\"$'\n'
        DOCKERFILE_CONTENT+="    find /opt/py_env -type d -name \"tests\" -exec rm -rf {} + 2>/dev/null || true && \\"$'\n'
        DOCKERFILE_CONTENT+="    find /opt/py_env -name \"*.pyc\" -delete 2>/dev/null || true"$'\n'
    else
        DOCKERFILE_CONTENT+="# Pre-build the Python virtual environment"$'\n'
        DOCKERFILE_CONTENT+="COPY requirements.txt /tmp/requirements.txt"$'\n'
        DOCKERFILE_CONTENT+="RUN python3 -m venv /opt/py_env && \\"$'\n'
        DOCKERFILE_CONTENT+="    /opt/py_env/bin/pip install --no-cache-dir -r /tmp/requirements.txt"$'\n'
    fi
elif [[ $HAS_PYPROJECT -eq 1 ]]; then
    DOCKERFILE_CONTENT+=""$'\n'
    DOCKERFILE_CONTENT+="# Pre-build the Python virtual environment"$'\n'
    DOCKERFILE_CONTENT+="COPY pyproject.toml /tmp/pyproject.toml"$'\n'
    DOCKERFILE_CONTENT+="RUN python3 -m venv /opt/py_env && \\"$'\n'
    DOCKERFILE_CONTENT+="    /opt/py_env/bin/pip install --no-cache-dir /tmp/"$'\n'
fi

# Pre-download sentence-transformers model
if [[ $HAS_SENTENCE_TRANSFORMERS -eq 1 ]]; then
    DOCKERFILE_CONTENT+=""$'\n'
    DOCKERFILE_CONTENT+="# Pre-download the sentence-transformers embedding model"$'\n'
    DOCKERFILE_CONTENT+="RUN /opt/py_env/bin/python -c \\"$'\n'
    DOCKERFILE_CONTENT+="    \"from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L6-v2')\""$'\n'
fi

# Node.js
if [[ $HAS_PACKAGE_JSON -eq 1 || $NODE_FEATURE -eq 1 ]]; then
    DOCKERFILE_CONTENT+=""$'\n'
    DOCKERFILE_CONTENT+="# Install Node.js LTS"$'\n'
    DOCKERFILE_CONTENT+="RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \\"$'\n'
    DOCKERFILE_CONTENT+="    apt-get install -y nodejs && \\"$'\n'
    DOCKERFILE_CONTENT+="    rm -rf /var/lib/apt/lists/*"$'\n'
    if [[ $HAS_PACKAGE_JSON -eq 1 ]]; then
        DOCKERFILE_CONTENT+=""$'\n'
        DOCKERFILE_CONTENT+="COPY package.json package-lock.json* /tmp/app/"$'\n'
        DOCKERFILE_CONTENT+="RUN cd /tmp/app && npm ci --ignore-scripts 2>/dev/null || npm install --ignore-scripts"$'\n'
    fi
fi

# Ollama
if [[ $HAS_OLLAMA -eq 1 ]]; then
    DOCKERFILE_CONTENT+=""$'\n'
    DOCKERFILE_CONTENT+="# Pre-install Ollama (binary only — no model pull)"$'\n'
    DOCKERFILE_CONTENT+="RUN curl -fsSL https://ollama.com/install.sh | sh"$'\n'
fi

ok "Dockerfile content generated"

# ── Compute new postCreateCommand ─────────────────────────────────────
# Remove scripts that are no longer needed when deps are baked in.
# Specifically, remove startOllama.sh since Ollama is now in the image.
NEW_POST_CREATE="$POST_CREATE"
if [[ $HAS_OLLAMA -eq 1 ]]; then
    # Remove "bash -i scripts/startOllama.sh" or "&& bash -i scripts/startOllama.sh" etc.
    NEW_POST_CREATE=$(echo "$NEW_POST_CREATE" | sed -E 's/\s*&&\s*bash\s+-i\s+scripts\/startOllama\.sh//g')
    NEW_POST_CREATE=$(echo "$NEW_POST_CREATE" | sed -E 's/bash\s+-i\s+scripts\/startOllama\.sh\s*&&\s*//g')
    NEW_POST_CREATE=$(echo "$NEW_POST_CREATE" | sed -E 's/bash\s+-i\s+scripts\/startOllama\.sh//g')
    # Trim whitespace
    NEW_POST_CREATE=$(echo "$NEW_POST_CREATE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
fi

# ── Build rebuild-triggers table for docs ─────────────────────────────
REBUILD_TRIGGERS="| File changed | Why rebuild is needed |\n|---|---|"
REBUILD_TRIGGERS+="\n| \`.devcontainer/Dockerfile\` | Image build instructions changed |"
[[ $HAS_PYTHON_REQS -eq 1 ]] && REBUILD_TRIGGERS+="\n| \`requirements.txt\` | Python packages are pre-installed in \`/opt/py_env\` |"
[[ $HAS_PYPROJECT -eq 1 ]]   && REBUILD_TRIGGERS+="\n| \`pyproject.toml\` | Python packages are pre-installed in \`/opt/py_env\` |"
[[ $HAS_PACKAGE_JSON -eq 1 ]] && REBUILD_TRIGGERS+="\n| \`package.json\` / \`package-lock.json\` | Node modules are pre-installed |"
[[ $HAS_SENTENCE_TRANSFORMERS -eq 1 ]] && REBUILD_TRIGGERS+="\n| Embedding model (in Dockerfile) | Model is pre-cached in the image |"

# ── GHCR settings URL ─────────────────────────────────────────────────
GHCR_SETTINGS_URL="github.com/orgs/$GHCR_ORG/packages/container/$IMAGE_NAME/settings"

# ── Generate IMAGE-MAINTENANCE.md content ─────────────────────────────
generate_maintenance_doc() {
    local variant="$1"  # "image" or "fork"

    cat << MAINTEOF
# Dev Container Image Maintenance

The Codespaces dev container uses a pre-built Docker image hosted on GitHub Container Registry (GHCR) to avoid large downloads at startup. When certain files change, the image must be rebuilt and pushed.

## Image location

\`\`\`
$FULL_IMAGE
\`\`\`

## What's baked into the image

| Component | How it got there |
|-----------|-----------------|
MAINTEOF

    [[ $HAS_PYTHON_REQS -eq 1 || $PYTHON_FEATURE -eq 1 ]] && echo "| Python 3 + venv | \`apt-get install\` |"
    [[ $HAS_PYTHON_REQS -eq 1 ]] && echo "| \`/opt/py_env/\` (full virtualenv) | CPU-only PyTorch installed first, then \`pip install -r requirements.txt\` |"
    [[ $HAS_SENTENCE_TRANSFORMERS -eq 1 ]] && echo "| sentence-transformers embedding model | Pre-downloaded at build time |"
    [[ $HAS_OLLAMA -eq 1 ]] && echo "| Ollama binary | Installed via \`ollama.com/install.sh\` (no model pulled) |"
    echo "| zstd, curl, ca-certificates | \`apt-get install\` |"

    cat << MAINTEOF

At codespace startup, \`scripts/pysetup.sh\` copies \`/opt/py_env\` to the workspace and fixes paths. No network downloads are needed.

## When to rebuild the image

Rebuild whenever you change any of these files:

$(echo -e "$REBUILD_TRIGGERS")

Changes to these files do **not** require a rebuild:

- \`.devcontainer/devcontainer.json\` (VS Code settings, extensions, postCreateCommand)
- \`scripts/pysetup.sh\` (runs at startup, not at image build)
- Any Python source files (\`.py\`), data files, or docs

## How to rebuild and push

Run from the repo root (the \`COPY requirements.txt\` in the Dockerfile needs the repo root as build context).

**You must specify \`--platform linux/amd64\`** — Codespaces runs on amd64. If you build on Apple Silicon (ARM) without this flag, the image will be arm64 and Codespaces will fail with "No manifest found."

\`\`\`bash
# 1. Log in to GHCR (one-time, or when token expires)
docker login ghcr.io -u YOUR_GITHUB_USERNAME

# 2. Build the image (always specify platform)
docker build --platform linux/amd64 -f .devcontainer/Dockerfile -t $FULL_IMAGE .

# 3. Push to GHCR
docker push $FULL_IMAGE
\`\`\`

Then commit and push your code changes (e.g. updated \`requirements.txt\`) so the repo and image stay in sync.

## Image size constraints

Free Codespaces have a 32GB storage limit. The image must fit within this along with the Codespaces system overhead (agent, VS Code server, mounts). To keep the image small:
MAINTEOF

    if [[ $HAS_PYTORCH -eq 1 ]]; then
        cat << 'MAINTEOF'

- **Install CPU-only PyTorch first** (before `requirements.txt`) using `--index-url https://download.pytorch.org/whl/cpu`. This prevents pip from ever downloading the GPU variant.
- **Remove `triton`** — a ~1GB PyTorch dependency not needed for CPU inference. Include it in the `pip uninstall` list in the Dockerfile.
- **Remove all `nvidia-*` packages** — CUDA libraries are not usable in Codespaces.
MAINTEOF
    fi

    cat << 'MAINTEOF'

- **Clean up test directories and .pyc files** to recover additional space.
- **Keep all installs and removals in the same `RUN` layer** — otherwise Docker preserves deleted files in earlier layers and the image stays large.

If a new dependency causes the image to exceed 32GB, check for unnecessary transitive dependencies (`pip show <package>`) and uninstall them in the Dockerfile.

## GHCR package visibility

Codespaces must be able to pull the image. There are two options:

### Option A: Make the package public

MAINTEOF

    echo "Go to: \`$GHCR_SETTINGS_URL\`"

    cat << 'MAINTEOF'

Under "Danger Zone", set visibility to **Public**. This may require org admin permissions.

### Option B: Grant repository access (for private packages)

If org restrictions prevent making the package public:

1. Go to the package settings page (same URL as above)
2. Under **"Manage Actions access"**, add the repository with **Read** access
3. Under **"Manage repository access"**, also add the repository with **Read** access

Both access grants are needed for Codespaces to authenticate the pull.

## Forked repos and prebuilds

Forked repos **cannot pull GHCR images** from the original org's private packages. Even if the image is public, forks should use the Dockerfile build approach for reliability.

### devcontainer.json for forks

Forks must use `"build"` instead of `"image"`, and **must include `"context": ".."`** because Codespaces uses `.devcontainer/` as the default build context, but the Dockerfile needs to `COPY` files (e.g. `requirements.txt`) from the repo root:

```jsonc
// For the original repo (pulls pre-built image — fast):
"image": "ghcr.io/ORG/IMAGE:latest",

// For forks or when GHCR image is unavailable (builds from Dockerfile):
"build": {
    "dockerfile": "Dockerfile",
    "context": ".."
},
```

Without `"context": ".."`, the build will fail with:
```
"/requirements.txt": not found
```

### Setting up prebuilds on a fork

1. In the forked repo, change `devcontainer.json` to use the `"build"` config shown above
2. Go to the fork's **Settings > Codespaces > Prebuilds > Set up prebuild**
3. Configure for the `main` branch and your preferred region
4. The prebuild will build the Dockerfile on GitHub's infra and cache the result
5. Subsequent codespace creations from the fork will use the cached prebuild

This is slower than pulling a pre-built image (~5-10 min for the initial prebuild) but only happens once. After the prebuild completes, users get fast startup.

### Keeping forks in sync

When the upstream repo updates dependency files or the Dockerfile:

1. Sync the fork with upstream
2. The prebuild will automatically re-trigger (if configured for "on push")
3. No need to rebuild or push any GHCR image — the fork builds its own

## Startup script considerations

If your `postCreateCommand` runs scripts that install packages (e.g., `pip install`), those commands must be **conditional** — they should only run when the pre-built venv is NOT available. Otherwise the script will re-download packages that are already baked into the image, defeating the purpose of pre-building.

Example pattern for a setup script:

```bash
if [ -d "/opt/py_env" ]; then
    # Fast path: copy pre-built venv from image
    cp -a /opt/py_env ./py_env
    # Fix hardcoded paths
    sed -i "s|/opt/py_env|$(pwd)/py_env|g" ./py_env/bin/activate
    sed -i "s|/opt/py_env|$(pwd)/py_env|g" ./py_env/bin/pip*
    sed -i "s|/opt/py_env|$(pwd)/py_env|g" ./py_env/pyvenv.cfg 2>/dev/null || true
else
    # Fallback: create venv and install from scratch
    python3 -m venv ./py_env
    pip install -r requirements.txt
fi
```

Any `pip install`, `pip install --upgrade`, or NVIDIA/CUDA cleanup commands must be inside the `else` block. If they run unconditionally after the copy, they will download new versions over the network on every codespace creation.

## Testing after a rebuild

1. Create a new codespace from the main branch
2. Confirm `py_env/` is populated and no `pip install` runs
3. Confirm `which ollama` returns `/usr/local/bin/ollama`
4. Confirm `python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L6-v2')"` loads instantly (no download)
5. Check disk usage with `df -h` — ensure adequate free space remains
MAINTEOF
}

# ── Generate devcontainer.json for a given mode ───────────────────────
generate_devcontainer_json() {
    local variant="$1"   # "image" or "fork"
    local source="$2"
    local output="$3"

    python3 << PYEOF
import json, re

with open("$source") as f:
    text = f.read()

# Preserve comment lines for reference, but strip for parsing (JSONC -> JSON)
clean = re.sub(r'//.*', '', text)
clean = re.sub(r',\s*([\]}])', r'\1', clean)
data = json.loads(clean)

# Set the container source based on variant
if "$variant" == "image":
    # Use pre-built GHCR image
    data.pop("build", None)
    data["image"] = "$FULL_IMAGE"
elif "$variant" == "fork":
    # Use Dockerfile build (works without GHCR access)
    data.pop("image", None)
    data["build"] = {
        "dockerfile": "Dockerfile",
        "context": ".."
    }

# Remove features that are now in the Dockerfile
features_to_remove = []
for key in list(data.get("features", {}).keys()):
    key_lower = key.lower()
    if "python" in key_lower:
        features_to_remove.append(key)
    if "node" in key_lower:
        features_to_remove.append(key)

for key in features_to_remove:
    del data["features"][key]

# Remove empty features block
if "features" in data and not data["features"]:
    del data["features"]

# Update postCreateCommand if needed
new_post = """$NEW_POST_CREATE"""
if new_post:
    data["postCreateCommand"] = new_post.strip("'\"")
elif "postCreateCommand" in data:
    del data["postCreateCommand"]

# Reorder so build/image comes first for readability
ordered = {}
for first_key in ("image", "build"):
    if first_key in data:
        ordered[first_key] = data.pop(first_key)
ordered.update(data)

with open("$output", "w") as f:
    json.dump(ordered, f, indent=4)
    f.write("\n")

removed = ", ".join(features_to_remove)
if removed:
    print(f"  Removed features (now in Dockerfile): {removed}")
if "$variant" == "image":
    print(f"  Set image to: $FULL_IMAGE")
else:
    print(f"  Set build with Dockerfile + context")
PYEOF
}

# ── Preserve source JSON before any git operations ────────────────────
# The source file may be untracked and would be removed by stash --include-untracked.
# Copy it to a temp location so it survives stash/checkout operations.
SOURCE_JSON_TMP=$(mktemp)
cp "$SOURCE_JSON" "$SOURCE_JSON_TMP"

# ── Ensure working tree is clean ──────────────────────────────────────
header "Checking git status"

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    warn "Working tree has uncommitted changes."
    warn "Changed files will be stashed before creating branches and restored after."
    echo ""
    if [[ $NO_PROMPT -eq 0 ]]; then
        read -r -p "$(echo -e "${CYAN}?${NC}") Stash changes and continue? [Y/n]: " stash_confirm
        if [[ "$stash_confirm" =~ ^[Nn] ]]; then
            rm -f "$SOURCE_JSON_TMP"
            echo "Aborted. Commit or stash your changes first."
            exit 0
        fi
    fi
    git stash push -m "prebake-devcontainer: auto-stash before branch creation" --include-untracked
    STASHED=1
    ok "Changes stashed"
else
    STASHED=0
    ok "Working tree clean"
fi

# ── Helper: create a branch with generated files ─────────────────────
create_branch() {
    local variant="$1"       # "image" or "fork"
    local branch_name="$2"

    header "Creating branch: $branch_name ($variant variant)"

    # Check if branch already exists
    if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
        warn "Branch '$branch_name' already exists."
        if [[ $NO_PROMPT -eq 0 ]]; then
            read -r -p "$(echo -e "${CYAN}?${NC}") Overwrite it? [y/N]: " overwrite
            if [[ ! "$overwrite" =~ ^[Yy] ]]; then
                warn "Skipping $variant variant."
                return
            fi
        else
            warn "Overwriting (--no-prompt mode)."
        fi
        git branch -D "$branch_name" >/dev/null 2>&1
    fi

    # Create branch from base
    git checkout -b "$branch_name" "$BASE_BRANCH" >/dev/null 2>&1
    ok "Created branch from $BASE_BRANCH"

    # Ensure .devcontainer directory exists
    mkdir -p "$DEVCONTAINER_DIR"

    # Write Dockerfile
    echo "$DOCKERFILE_CONTENT" > "$DEVCONTAINER_DIR/Dockerfile"
    ok "Wrote .devcontainer/Dockerfile"

    # Write devcontainer.json
    generate_devcontainer_json "$variant" "$SOURCE_JSON_TMP" "$DEVCONTAINER_DIR/devcontainer.json"
    ok "Wrote .devcontainer/devcontainer.json"

    # Write IMAGE-MAINTENANCE.md
    generate_maintenance_doc "$variant" > "$DEVCONTAINER_DIR/IMAGE-MAINTENANCE.md"
    ok "Wrote .devcontainer/IMAGE-MAINTENANCE.md"

    # Stage and commit
    git add "$DEVCONTAINER_DIR/Dockerfile" \
            "$DEVCONTAINER_DIR/devcontainer.json" \
            "$DEVCONTAINER_DIR/IMAGE-MAINTENANCE.md"

    local commit_msg
    if [[ "$variant" == "image" ]]; then
        commit_msg="devcontainer: use pre-built GHCR image

Switch devcontainer.json to pull $FULL_IMAGE instead of
installing dependencies at startup. The Dockerfile and
IMAGE-MAINTENANCE.md are included for rebuilding the image."
    else
        commit_msg="devcontainer: use Dockerfile build for forks

Switch devcontainer.json to build from Dockerfile (with context: ..)
so forks can create codespaces without GHCR access. The Dockerfile
bakes all dependencies into the image at build time."
    fi

    git commit -m "$commit_msg" >/dev/null 2>&1
    ok "Committed to $branch_name"
}

# ── Create the branch(es) ────────────────────────────────────────────
if [[ "$MODE" == "image" || "$MODE" == "both" ]]; then
    create_branch "image" "$IMAGE_BRANCH"
fi

if [[ "$MODE" == "fork" || "$MODE" == "both" ]]; then
    create_branch "fork" "$FORK_BRANCH"
fi

# ── Return to original branch and restore stash ──────────────────────
header "Cleanup"

git checkout "$BASE_BRANCH" >/dev/null 2>&1
ok "Returned to $BASE_BRANCH"

if [[ $STASHED -eq 1 ]]; then
    git stash pop >/dev/null 2>&1
    ok "Restored stashed changes"
fi

rm -f "$SOURCE_JSON_TMP"

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  Done!${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""

if [[ "$MODE" == "image" || "$MODE" == "both" ]]; then
    echo -e "${BOLD}  Image variant branch: ${GREEN}$IMAGE_BRANCH${NC}"
    echo "  └─ devcontainer.json uses: \"image\": \"$FULL_IMAGE\""
fi
if [[ "$MODE" == "fork" || "$MODE" == "both" ]]; then
    echo -e "${BOLD}  Fork variant branch:  ${GREEN}$FORK_BRANCH${NC}"
    echo "  └─ devcontainer.json uses: \"build\": {\"dockerfile\": \"Dockerfile\", \"context\": \"..\"}"
fi

echo ""
echo -e "${BOLD}  Next steps:${NC}"
echo -e "  ────────────────────────────────────────────────"

if [[ "$MODE" == "image" || "$MODE" == "both" ]]; then
    echo ""
    echo -e "  ${BOLD}For the image variant (branch: $IMAGE_BRANCH):${NC}"
    echo ""
    echo "  1. Build and push the Docker image:"
    echo ""
    echo "     docker login ghcr.io -u YOUR_GITHUB_USERNAME"
    echo "     docker build --platform linux/amd64 \\"
    echo "       -f .devcontainer/Dockerfile \\"
    echo "       -t $FULL_IMAGE ."
    echo "     docker push $FULL_IMAGE"
    echo ""
    echo "  2. Make the GHCR package accessible:"
    echo "     https://$GHCR_SETTINGS_URL"
    echo ""
    echo "  3. Push the branch:"
    echo "     git push -u origin $IMAGE_BRANCH"
    echo ""
    echo "  4. Merge into your main branch (or create a PR)"
fi

if [[ "$MODE" == "fork" || "$MODE" == "both" ]]; then
    echo ""
    echo -e "  ${BOLD}For the fork variant (branch: $FORK_BRANCH):${NC}"
    echo ""
    echo "  1. Push the branch:"
    echo "     git push -u origin $FORK_BRANCH"
    echo ""
    echo "  2. Merge into your main branch (or create a PR)"
    echo ""
    echo "  3. In each fork, set up Codespaces prebuilds:"
    echo "     Fork Settings > Codespaces > Prebuilds > Set up prebuild"
    echo "     (The prebuild caches the Dockerfile build — subsequent"
    echo "      codespace creations will be fast)"
fi

echo ""
echo -e "  ${BOLD}Optional: Enable Codespaces prebuilds on the main repo:${NC}"
echo "  Repo Settings > Codespaces > Prebuilds > Set up prebuild"
echo ""

if [[ "$MODE" == "both" ]]; then
    echo -e "  ${BOLD}Typical workflow:${NC}"
    echo -e "  • Main repo uses the ${BOLD}image${NC} branch (fast pull from GHCR)"
    echo -e "  • Forks use the ${BOLD}fork${NC} branch (builds Dockerfile, no GHCR needed)"
    echo -e "  • Both branches share the same Dockerfile and IMAGE-MAINTENANCE.md"
    echo ""
fi

echo -e "${BOLD}============================================================${NC}"
