# prebake-devcontainer.sh

A tool that transforms a standard devcontainer setup into one that uses a pre-built Docker image, dramatically reducing Codespaces startup time. It handles both the **main repo** (pulling a pre-built image from GHCR) and **forks** (building from a Dockerfile without GHCR access).

## The problem

A typical `devcontainer.json` uses `features` and `postCreateCommand` to install dependencies at startup. For repos with heavy dependencies (PyTorch, sentence-transformers, Ollama, etc.), this means every new Codespace spends 5-15 minutes downloading and installing packages — painful for workshops, conferences, or any bandwidth-constrained environment.

## What this script does

Starting from an **original** `devcontainer.json` (one that uses `"image"` + `"features"`), the script:

1. **Analyzes** the source `devcontainer.json` to detect the base image, features, and dependencies
2. **Scans** for dependency files (`requirements.txt`, `pyproject.toml`, `package.json`) and known heavy deps (PyTorch, sentence-transformers, Ollama)
3. **Generates a Dockerfile** that bakes all dependencies into the image at build time
4. **Creates git branches** with transformed `devcontainer.json` files — one for image-pull mode, one for fork/build mode
5. **Generates `IMAGE-MAINTENANCE.md`** with rebuild and push instructions
6. **Prints next-step commands** for building, pushing, and configuring GHCR

## Two output modes

| Mode | devcontainer.json uses | Best for | Startup speed |
|------|----------------------|----------|---------------|
| `image` | `"image": "ghcr.io/org/name:latest"` | Main repo with GHCR push access | ~30 seconds (image pull) |
| `fork` | `"build": {"dockerfile": "Dockerfile", "context": ".."}` | Forks that can't access the org's GHCR | ~5-10 min first time (cached by prebuilds after) |

By default, the script creates **both** branches so you can use the image variant on the main repo and the fork variant for contributors.

## Prerequisites

- **git** — the script creates branches and commits
- **python3** — used for JSON parsing (handles devcontainer.json comments)
- A **GitHub-hosted repo** with a `.devcontainer/devcontainer.json`

## Quick start

```bash
# From the root of your repo
bash scripts/prebake-devcontainer.sh
```

The script will prompt you for:
- GHCR org/username (default: from `git remote`)
- Image name (default: `<repo-name>-devcontainer`)
- Branch names (defaults: `devcontainer-image`, `devcontainer-fork`)
- Base branch to create from (default: current branch)

Then it creates the branches, commits the generated files, and prints what to do next.

## Options

```
--mode image|fork|both   Which variant(s) to generate (default: both)
--source FILE            Source devcontainer.json to transform
                         (default: auto-detects devcontainer-original.json
                          or devcontainer.json)
--ghcr-org ORG           GitHub org or username for GHCR
                         (default: derived from git remote origin)
--image-name NAME        Image name on GHCR
                         (default: <repo>-devcontainer)
--image-branch NAME      Branch name for image variant
                         (default: devcontainer-image)
--fork-branch NAME       Branch name for fork variant
                         (default: devcontainer-fork)
--base-branch NAME       Branch to create new branches from
                         (default: current branch)
--no-prompt              Skip all interactive prompts; use defaults/args only
-h, --help               Show built-in help text
```

## Examples

### Generate both variants (interactive)

```bash
bash scripts/prebake-devcontainer.sh
```

You'll be prompted for each value with sensible defaults shown in brackets. Press Enter to accept defaults.

### Generate only the fork variant (non-interactive)

```bash
bash scripts/prebake-devcontainer.sh \
  --mode fork \
  --no-prompt
```

### Custom GHCR org and image name

```bash
bash scripts/prebake-devcontainer.sh \
  --ghcr-org mycompany \
  --image-name workshop-devcontainer \
  --no-prompt
```

### Use a specific source file

```bash
bash scripts/prebake-devcontainer.sh \
  --source .devcontainer/devcontainer-original.json \
  --mode image
```

### Custom branch names

```bash
bash scripts/prebake-devcontainer.sh \
  --image-branch prebaked-image \
  --fork-branch prebaked-fork \
  --base-branch develop
```

## What gets generated

On each branch, the script creates or updates three files in `.devcontainer/`:

| File | Contents |
|------|----------|
| `devcontainer.json` | Transformed config — either `"image"` (GHCR pull) or `"build"` (Dockerfile) |
| `Dockerfile` | Multi-stage build that pre-installs all detected dependencies |
| `IMAGE-MAINTENANCE.md` | Documentation: what's baked in, when to rebuild, how to push, GHCR visibility, fork instructions |

### What the Dockerfile includes (auto-detected)

The script inspects your repo and includes the appropriate sections:

| Detected | Dockerfile action |
|----------|------------------|
| `requirements.txt` | Creates `/opt/py_env` venv, installs packages |
| PyTorch (direct or via sentence-transformers) | Installs CPU-only PyTorch first, then cleans up nvidia/triton packages |
| sentence-transformers | Pre-downloads the `all-MiniLM-L6-v2` embedding model |
| Ollama in `postCreateCommand` | Pre-installs Ollama binary (no model pull) |
| Node.js feature or `package.json` | Installs Node.js LTS and runs `npm ci` |
| Python feature | Installs `python3`, `python3-venv`, `python3-pip` via apt |

### What changes in devcontainer.json

- `"image"` or `"build"` is set depending on the mode
- `"features"` that are now baked into the Dockerfile are removed (e.g., Python, Node)
- `postCreateCommand` is simplified (e.g., `startOllama.sh` is removed since Ollama is in the image)
- All other settings (VS Code config, extensions, hostRequirements) are preserved

## After running the script

The script prints detailed next steps, but here's the summary:

### For the image variant

1. **Build** the Docker image (from repo root):
   ```bash
   docker build --platform linux/amd64 \
     -f .devcontainer/Dockerfile \
     -t ghcr.io/YOUR_ORG/YOUR_IMAGE:latest .
   ```
2. **Push** to GHCR:
   ```bash
   docker login ghcr.io -u YOUR_GITHUB_USERNAME
   docker push ghcr.io/YOUR_ORG/YOUR_IMAGE:latest
   ```
3. **Make the GHCR package accessible** (public, or grant repo read access)
4. **Push the branch** and merge into main

### For the fork variant

1. **Push the branch** and merge into main (or provide as the default branch for forks)
2. **Set up Codespaces prebuilds** in each fork (Settings > Codespaces > Prebuilds) — this caches the Dockerfile build so subsequent codespace creations are fast

## How it handles uncommitted changes

If your working tree has uncommitted changes when you run the script, it will:

1. Warn you and ask for confirmation (unless `--no-prompt`)
2. Run `git stash push --include-untracked` to save your changes
3. Create the branch(es) and commit
4. Return to your original branch
5. Run `git stash pop` to restore your changes

The source `devcontainer.json` is copied to a temp file before stashing, so it survives even if it's an untracked file.

## Source file auto-detection

When `--source` is not specified, the script looks for files in this order:

1. `.devcontainer/devcontainer-original.json` — preferred (a saved copy of the original config)
2. `.devcontainer/devcontainer.json` — fallback

If your `devcontainer.json` has already been transformed (it uses `"image"` pointing to GHCR or `"build"` with a Dockerfile), save the original version as `devcontainer-original.json` first and point to it with `--source`.

## Troubleshooting

### `ERROR: Not inside a git repository`

Run the script from within a git repo. The script needs git for branch creation and for deriving the GHCR org/image defaults from the remote URL.

### `ERROR: python3 is required`

The script uses Python to parse `devcontainer.json` (which allows JS-style `//` comments that standard JSON parsers reject). Install Python 3 or run from a devcontainer that has it.

### `ERROR: Could not determine GHCR org/image name`

The script couldn't parse your git remote URL. Provide values explicitly:
```bash
bash scripts/prebake-devcontainer.sh --ghcr-org myorg --image-name myimage
```

### Branch already exists

If a target branch already exists, the script will ask whether to overwrite it (or overwrite automatically with `--no-prompt`). The old branch is deleted and re-created from the base branch.

### `git stash pop` conflicts

If stash restoration fails (e.g., due to conflicts with the generated files), your changes are still in the stash. Recover with:
```bash
git stash list        # find your stash
git stash pop         # or: git stash apply stash@{0}
```

### Dockerfile build fails with `"/requirements.txt": not found`

This happens when the build context is wrong. The fork variant uses `"context": ".."` in `devcontainer.json` because Codespaces defaults to `.devcontainer/` as the build context, but the Dockerfile needs to `COPY` files from the repo root. Make sure `"context": ".."` is present in the `"build"` block.

### Image too large for Codespaces (32GB limit)

The generated Dockerfile already optimizes for size (CPU-only PyTorch, nvidia package removal, test/pyc cleanup). If you're still over the limit:
- Check for unnecessary transitive dependencies: `pip show <package>`
- Add more packages to the `pip uninstall` list in the Dockerfile
- Ensure all installs and cleanups are in the **same `RUN` layer**

### `pip install` runs again at startup despite pre-built image

Your `postCreateCommand` scripts may have unconditional `pip install` commands. They need to check for `/opt/py_env` first:
```bash
if [ -d "/opt/py_env" ]; then
    cp -a /opt/py_env ./py_env
    # fix paths...
else
    python3 -m venv ./py_env
    pip install -r requirements.txt
fi
```
The script warns about this during the "Checking postCreateCommand scripts" phase.

### Forks can't pull the GHCR image

This is expected. Forks should use the **fork variant** (`"build"` mode), not the image variant. The fork variant builds from the Dockerfile without needing GHCR access. Set up Codespaces prebuilds on the fork so the build only happens once.

## Typical workflow

```
                    ┌─────────────────────────────┐
                    │   devcontainer-original.json │
                    │   (image + features)         │
                    └──────────────┬──────────────┘
                                   │
                    prebake-devcontainer.sh
                                   │
                    ┌──────────────┴──────────────┐
                    │                              │
          ┌────────▼────────┐           ┌─────────▼────────┐
          │  devcontainer-  │           │  devcontainer-    │
          │  image branch   │           │  fork branch      │
          │                 │           │                   │
          │  "image": GHCR  │           │  "build":         │
          │  Fast pull      │           │   Dockerfile      │
          │                 │           │  Works anywhere   │
          └────────┬────────┘           └─────────┬────────┘
                   │                              │
          Main repo merges              Forks use this
          this branch                   branch/config
```

Both branches share the same `Dockerfile` and `IMAGE-MAINTENANCE.md`. The only difference is how `devcontainer.json` references the image.

