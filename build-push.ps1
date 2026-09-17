# Build and push ghcr.io/ellexistech/arc-runner as :<VERSION> and :latest.
# Bump VERSION by hand before running.
#
# Usage:
#   .\build-push.ps1                 # build + push VERSION and latest
#   .\build-push.ps1 -NoPush         # build only
#   $env:IMAGE_REPO = "ghcr.io/org/name"; .\build-push.ps1
#
# Login first (example):
#   $env:GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin

[CmdletBinding()]
param(
  [switch]$NoPush,
  [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
  Get-Content $PSCommandPath -TotalCount 12 | Select-Object -Skip 1
  exit 0
}

Set-Location $PSScriptRoot

$versionPath = Join-Path $PSScriptRoot "VERSION"
if (-not (Test-Path $versionPath)) {
  Write-Error "VERSION file not found at $versionPath"
}

$Version = (Get-Content $versionPath -Raw).Trim()
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+([.-].+)?$') {
  Write-Error "VERSION must look like 1.2.3 (got: '$Version')"
}

$ImageRepo = if ($env:IMAGE_REPO) { $env:IMAGE_REPO } else { "ghcr.io/ellexistech/arc-runner" }
$TagVersion = "${ImageRepo}:${Version}"
$TagLatest = "${ImageRepo}:latest"

Write-Host "Building $TagVersion (also tagged $TagLatest)"
docker build `
  --build-arg "IMAGE_VERSION=$Version" `
  -t $TagVersion `
  -t $TagLatest `
  .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Smoke: node / pnpm / gh"
docker run --rm $TagVersion node -v
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
docker run --rm $TagVersion pnpm -v
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
docker run --rm $TagVersion gh --version
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if (-not $NoPush) {
  Write-Host "Pushing $TagVersion"
  docker push $TagVersion
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Host "Pushing $TagLatest"
  docker push $TagLatest
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Host "done: $TagVersion + $TagLatest"
} else {
  Write-Host "done: local tags only (-NoPush)"
}
