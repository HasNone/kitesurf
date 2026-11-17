# kitesurf (container)

Runs [Cloudflare Kitesurf](https://github.com/cloudflare/kitesurf) locally in a
container so any Chrome DevTools Protocol (CDP) client, such as Puppeteer, can
drive it.

## Build and run

```sh
docker build -t kitesurf:local .          # or: podman build --format docker -t kitesurf:local .
cp .env.example .env && chmod 600 .env
docker compose up -d                      # or: podman-compose up -d
curl http://127.0.0.1:8787/health
```

To build a different upstream commit: `--build-arg KITESURF_REF=<sha-or-tag>`
(the default is pinned in the `Dockerfile`). Rebuild and recreate the container
to update.

## Connect

- CDP WebSocket: `ws://127.0.0.1:8787/devtools/browser`
- Discovery: `http://127.0.0.1:8787/json/version`
- Puppeteer: `puppeteer.connect({ browserWSEndpoint: "ws://127.0.0.1:8787/devtools/browser" })`

With a token set (see below), pass it as a header, e.g.
`puppeteer.connect({ browserWSEndpoint, headers: { Authorization: "Bearer <token>" } })`,
or append `?token=<token>` to the WebSocket URL.

## Configuration

See `.env.example`: bind address, port, memory and process limits, page CPU/wall
caps, allowed hosts, optional auth token, and the private-network toggle.

## Security

The Kitesurf engine has no authentication of its own, so this image puts a small
guard in front of it (`proxy.mjs`):

- **Host check:** requests whose `Host` header is not `127.0.0.1`, `localhost` or
  `[::1]` are rejected (HTTP 421), which stops DNS-rebinding attacks from web
  pages. Change the list with `KITESURF_ALLOWED_HOSTS`.
- **Optional token:** set `KITESURF_AUTH_TOKEN` and every request except
  `/health` must carry it.
- **Loopback only:** the port is published on `127.0.0.1`. Do not publish it on
  other addresses without an authenticated proxy in front.
- **Hardened container:** non-root user, read-only root filesystem, all
  capabilities dropped, `no-new-privileges`, and a process limit.
- **Private networks:** pages cannot reach private addresses unless
  `KITESURF_ALLOW_PRIVATE_NETWORK=1`.

## License

Kitesurf is Apache-2.0 (Cloudflare). Add your own license for these build files.
