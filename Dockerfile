FROM ghcr.io/actions/actions-runner:latest

USER root

# Pin tools; bump when releasing a new image (see VERSION + build-push).
ARG NODE_VERSION=24.11.0
ARG PNPM_VERSION=11.23.0
ARG GH_VERSION=2.101.0
ARG JQ_VERSION=1.8.2
ARG IMAGE_VERSION=0.0.0

LABEL org.opencontainers.image.title="ellexistech/arc-runner" \
      org.opencontainers.image.description="ARC runner with Node, pnpm, gh, jq" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.source="https://github.com/ellexistech/arc-runner"

# Base image already has curl + tar. Install Node + static gh/jq; pnpm via npm
# (standalone pnpm-linux-x64 needs libatomic; npm global install does not).
# No apt python3/jq/gh. Node uses .tar.gz so xz-utils is not required.
RUN set -eux; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz" \
      | tar -xz -C /usr/local --strip-components=1; \
    npm install -g --no-audit --no-fund "pnpm@${PNPM_VERSION}"; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
      | tar -xz -C /tmp; \
    install -m 755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh; \
    rm -rf "/tmp/gh_${GH_VERSION}_linux_amd64"; \
    curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64" \
      -o /usr/local/bin/jq; \
    chmod 755 /usr/local/bin/jq; \
    # Drop bulky npm docs/man from the Node tarball (keep npm CLI for fallbacks).
    rm -rf /usr/local/lib/node_modules/npm/{man,docs,html} \
      /usr/local/CHANGELOG.md /usr/local/README.md /usr/local/LICENSE; \
    node -v; \
    pnpm -v; \
    gh --version; \
    jq --version

USER runner
