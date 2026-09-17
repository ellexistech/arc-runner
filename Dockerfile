FROM ghcr.io/actions/actions-runner:latest

USER root

# Pin Node 24 LTS (linux-x64). Bump NODE_VERSION when moving LTS lines.
# IMAGE_VERSION is the arc-runner package tag (see VERSION + build-push.sh).
ARG NODE_VERSION=24.11.0
ARG PNPM_VERSION=11.23.0
ARG IMAGE_VERSION=0.0.0

LABEL org.opencontainers.image.title="ellexistech/arc-runner" \
      org.opencontainers.image.description="ARC runner with Node, pnpm, gh" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.source="https://github.com/ellexistech/arc-runner"

RUN apt-get update \
    && apt-get install -y \
        curl \
        jq \
        python3 \
        xz-utils \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
        | tar -xJ -C /usr/local --strip-components=1 \
    # Install pnpm into /usr/local so USER runner can run it (corepack prepare
    # as root only caches under /root and breaks at runtime for runner).
    && npm install -g --no-audit --no-fund "pnpm@${PNPM_VERSION}" \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/* \
    && node -v \
    && pnpm -v \
    && gh --version

USER runner
