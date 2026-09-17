# Ellexis ARC Runner

Image: `ghcr.io/ellexistech/arc-runner` ([GHCR package](https://github.com/orgs/ellexistech/packages?repo_name=arc-runner))

Custom [Actions Runner Controller](https://docs.github.com/en/actions/concepts/runners/actions-runner-controller)
image with **Node 24 LTS**, **pnpm**, `gh`, `jq`, and `scc` (static/official binaries,
no apt python3/cloc) so workflow setup steps can skip downloading those tools on
every ephemeral pod.

**Bootstrap a single-node k3s builder + ARC scale set:** [SETUP.md](SETUP.md)

## Versioning

Manual semver in `[VERSION](VERSION)`. Each release pushes:

| Tag                                     | Meaning                                     |
| --------------------------------------- | ------------------------------------------- |
| `ghcr.io/ellexistech/arc-runner:0.3.0`  | Immutable release (pin this in Helm values) |
| `ghcr.io/ellexistech/arc-runner:latest` | Same build, moving pointer                  |

### Release a new image

1. Edit `VERSION` (e.g. `0.3.0` → `0.4.0`).
2. Build and push both tags:

```bash
# Git Bash / Linux / macOS — login once:
#   echo "$GITHUB_TOKEN" | docker login ghcr.io -u USERNAME --password-stdin
bash ./build-push.sh
bash ./build-push.sh --no-push   # build only
```

```powershell
# Windows PowerShell — login once:
#   $env:GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin
.\build-push.ps1
.\build-push.ps1 -NoPush   # build only
```

1. Commit `VERSION` (and Dockerfile changes) on `main`. Optionally tag the git
   commit: `git tag v0.3.0; git push origin v0.3.0`.
2. Point the scale set at the new tag in `~/arc-runners-values.yaml` and
   `helm upgrade` (see [SETUP.md](SETUP.md)).

Use a PAT or `gh auth token` with `write:packages`. Keep the GHCR package
**public** so runner pods can pull without an imagePullSecret.

## Smoke test

```bash
VER=$(tr -d '[:space:]' < VERSION)
docker run --rm "ghcr.io/ellexistech/arc-runner:${VER}" node -v
docker run --rm "ghcr.io/ellexistech/arc-runner:${VER}" pnpm -v
docker run --rm "ghcr.io/ellexistech/arc-runner:${VER}" gh --version
docker run --rm "ghcr.io/ellexistech/arc-runner:${VER}" jq --version
docker run --rm "ghcr.io/ellexistech/arc-runner:${VER}" scc --version
```

## Day-2 scale

```bash
bash ./set-runner-max.sh 8          # max only
bash ./set-runner-max.sh 8 1        # max 8, min 1
MAX_RUNNERS_HOST=builder.example bash ./set-runner-max.sh 3
```
