#!/bin/sh
# Starts the Kitesurf engine (wrangler dev) behind the Host-checking proxy.
# Optional engine settings are passed through from the environment; unset or
# empty ones keep upstream's defaults.
set -eu

INNER_PORT="${KITESURF_INNER_PORT:-8788}"

# The engine listens on loopback only; proxy.mjs is the only way in.
set -- --env local -c wrangler.jsonc -c test/fixtures-worker/wrangler.jsonc \
  --ip 127.0.0.1 --port "$INNER_PORT" --inspector-port 9229 \
  --persist-to /state/wrangler "$@"

# Allow-listed engine vars (see packages/engine/wrangler.jsonc).
for v in KITESURF_PAGE_CPU_MS_CAP KITESURF_PAGE_WALL_MS_CAP \
         KITESURF_ALLOW_PRIVATE_NETWORK KITESURF_DISABLE_PARTIAL_RASTER \
         KITESURF_RESOURCE_DRAIN_QUIET_TURNS KITESURF_OTLP_ENDPOINT; do
  eval "val=\${$v:-}"
  [ -n "$val" ] && set -- --var "$v:$val" "$@"
done

# --expose-gc is required to survive many navigations (upstream README).
export MINIFLARE_WORKERD_V8_FLAGS="${MINIFLARE_WORKERD_V8_FLAGS:---expose-gc}"

exec node /usr/local/lib/kitesurf/proxy.mjs node_modules/.bin/wrangler dev "$@"
