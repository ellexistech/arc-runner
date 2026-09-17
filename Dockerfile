FROM ghcr.io/actions/actions-runner:latest

USER root

# Pin Node 24 LTS (linux-x64). Bump NODE_VERSION when moving LTS lines.
ARG NODE_VERSION=24.11.0
ARG PNPM_VERSION=11.23.0

RUN apt-get update \
    && apt-get install -y \
        curl \
        jq \
        python3 \
        xz-utils \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
        | tar -xJ -C /usr/local --strip-components=1 \
    && corepack enable \
    && corepack prepare "pnpm@${PNPM_VERSION}" --activate \
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
