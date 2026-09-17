# Ellexis ARC Runner

Image: `ghcr.io/ellexistech/arc-runner:latest`

Custom [Actions Runner Controller](https://docs.github.com/en/actions/concepts/runners/actions-runner-controller)
image with **Node 24 LTS**, **pnpm** (Corepack), `gh`, `jq`, and `python3` so
workflow setup steps can skip downloading those tools on every ephemeral pod.

**Bootstrap a single-node k3s builder + ARC scale set:** [SETUP.md](SETUP.md)

## Build and push

```powershell
docker build -t ghcr.io/ellexistech/arc-runner:latest .
$env:GITHUB_TOKEN | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
docker push ghcr.io/ellexistech/arc-runner:latest
```

Use a PAT or `gh auth token` with `write:packages`. Prefer making the GHCR
package **public** so runner pods can pull without an imagePullSecret.

After push, upgrade the scale set (or delete runner pods) so new jobs pick up
the image — see [SETUP.md](SETUP.md).

## Smoke test

```powershell
docker run --rm ghcr.io/ellexistech/arc-runner:latest node -v
docker run --rm ghcr.io/ellexistech/arc-runner:latest pnpm -v
docker run --rm ghcr.io/ellexistech/arc-runner:latest gh --version
docker run --rm ghcr.io/ellexistech/arc-runner:latest python3 --version
```

## Day-2 scale

```bash
bash ./set-runner-max.sh 8          # max only
bash ./set-runner-max.sh 8 1        # max 8, min 1
MAX_RUNNERS_HOST=builder.example bash ./set-runner-max.sh 3
```
