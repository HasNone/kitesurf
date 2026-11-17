# syntax=docker/dockerfile:1
# Kitesurf (Cloudflare's Workers-based browser engine), run locally over CDP.
# Debian trixie (glibc) throughout: upstream's toolchain (Bazel's bundled JDK,
# the Rust nightly, wasm tools) and the runtime (workerd) ship glibc binaries.
# The build stage compiles; nothing from it but /app (JS, Wasm, node_modules)
# is shipped.

# Base images are pinned by multi-arch index digest (amd64 + arm64); refresh
# them with the build script's --refresh-base option.
ARG NODE_TRIXIE_DIGEST=sha256:c103d7b5aa3bf627c8b98db941d52556f04e0b5d9352b3d7b6391245d26620f8
ARG NODE_TRIXIE_SLIM_DIGEST=sha256:68c76cfad89921b927eae28ba21407475e29d0ce450afcdbe70c1532db042b64

FROM node:22-trixie@${NODE_TRIXIE_DIGEST} AS build

# Describes the build itself: which upstream commit to build.
ARG KITESURF_REF=6dd23026b233f594f32b911ab4d82e3b717cec43
ARG TARGETARCH
ARG BAZELISK_VERSION=v1.30.0
ARG BAZELISK_SHA256_amd64=a248ae2b2b62b5baebb748f6fba7203bff1a27e5d01b55399a8406744cb539e8
ARG BAZELISK_SHA256_arm64=b2bcc040c213b44586b121bda6d983c35df121b917c3a7a66fb16f2fa0df1a4f

# Unpinned apt versions on purpose: the base image is digest-pinned, and
# distro security updates arrive when the digest is refreshed.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends zip unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) sum="$BAZELISK_SHA256_amd64";; \
      arm64) sum="$BAZELISK_SHA256_arm64";; \
      *) echo "unsupported arch $TARGETARCH" >&2; exit 1;; \
    esac; \
    curl -fsSL -o /usr/local/bin/bazel \
      "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-${TARGETARCH}"; \
    echo "${sum}  /usr/local/bin/bazel" | sha256sum -c -; \
    chmod +x /usr/local/bin/bazel; \
    corepack enable; \
    corepack prepare pnpm@9.15.4+sha512.b2dc20e2fc72b3e18848459b37359a32064663e5627a51e4c74b2c29dd8e8e0491483c3abb40789cfd578bf362fb6ba8261b05f0387d76792ed6e23ea3b1b6a0 --activate

WORKDIR /app
RUN git init -q . \
 && git remote add origin https://github.com/cloudflare/kitesurf.git \
 && git fetch -q --depth 1 origin "${KITESURF_REF}" \
 && git checkout -q FETCH_HEAD

RUN pnpm install --frozen-lockfile

# Compiles the Rust core to WebAssembly and stages the bundles (slow: first
# build compiles the vendored crates). Bazel's cache lives outside /app so it
# is not copied to the runtime image.
ENV CI=1 DO_NOT_TRACK=1
# The cache mount survives failed builds and is never part of an image layer.
# No `bazel shutdown`: it cannot kill its server in a rootless build and would
# fail the layer; the server ends with the RUN step.
RUN --mount=type=cache,target=/var/cache/bazel \
    bazel --output_user_root=/var/cache/bazel run //packages/engine:dev_build

# Build leftovers the runtime does not need: git history and Bazel's output
# symlinks (dangling once the cache mount is gone).
RUN rm -rf /app/.git /app/bazel-*

# Writable dirs for the non-root runtime user (numeric uid, no passwd entry).
RUN mkdir -p /state /app/packages/engine/.wrangler \
      /app/packages/engine/node_modules/.mf \
      /app/packages/engine/test/fixtures-worker/.wrangler \
      /app/packages/engine/test/fixtures-worker/node_modules/.mf \
 && chown -R 65532:65532 /state /app/packages/engine/.wrangler \
      /app/packages/engine/node_modules/.mf \
      /app/packages/engine/test/fixtures-worker/.wrangler \
      /app/packages/engine/test/fixtures-worker/node_modules/.mf

# Runtime: workerd (run by wrangler dev) is a glibc binary.
FROM node:22-trixie-slim@${NODE_TRIXIE_SLIM_DIGEST}

# workerd needs libc++; ca-certificates lets pages fetch over HTTPS.
# Unpinned apt versions on purpose (see the build stage).
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends libc++1 ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /app /app
COPY --from=build --chown=65532:65532 /state /state
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY proxy.mjs /usr/local/lib/kitesurf/proxy.mjs

ARG KITESURF_REF=6dd23026b233f594f32b911ab4d82e3b717cec43
LABEL org.opencontainers.image.title="kitesurf" \
      org.opencontainers.image.source="https://github.com/cloudflare/kitesurf" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.revision="${KITESURF_REF}"

ENV HOME=/state \
    XDG_CONFIG_HOME=/state/config \
    XDG_CACHE_HOME=/state/cache \
    WRANGLER_SEND_METRICS=false \
    NO_UPDATE_NOTIFIER=1 \
    CI=1

WORKDIR /app/packages/engine
USER 65532:65532
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.KITESURF_PORT||8787)+'/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"]
ENTRYPOINT ["/bin/sh", "/usr/local/bin/entrypoint.sh"]
