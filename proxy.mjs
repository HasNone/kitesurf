// Guard + supervisor in front of the Kitesurf engine (no dependencies).
//
// The engine has no authentication. This process listens on KITESURF_PORT,
// forwards to the engine on 127.0.0.1:KITESURF_INNER_PORT, and:
//   - rejects requests whose Host header is not allow-listed (stops DNS
//     rebinding: a web page whose domain resolves to 127.0.0.1 would otherwise
//     look same-origin to the engine's Origin check),
//   - optionally requires KITESURF_AUTH_TOKEN (Bearer header, X-Kitesurf-Token
//     header or ?token= query); /health is exempt so health checks work.
// It runs the engine command given as its arguments and exits with it.
//
//   node proxy.mjs <engine command> [args...]
//
// KITESURF_ALLOWED_HOSTS: comma-separated host names, any port
//   (default 127.0.0.1,localhost,[::1]); "*" disables the check.
import { spawn } from "node:child_process";
import { createHash, timingSafeEqual } from "node:crypto";
import http from "node:http";
import net from "node:net";

const PORT = Number(process.env.KITESURF_PORT || 8787);
const INNER_PORT = Number(process.env.KITESURF_INNER_PORT || 8788);
const TOKEN = process.env.KITESURF_AUTH_TOKEN || "";
const ALLOWED = (process.env.KITESURF_ALLOWED_HOSTS || "127.0.0.1,localhost,[::1]")
  .split(",")
  .map((h) => h.trim().toLowerCase())
  .filter(Boolean);
const ALLOW_ANY_HOST = ALLOWED.includes("*");

const command = process.argv.slice(2);
if (command.length === 0) {
  console.error("proxy: no engine command given");
  process.exit(2);
}

function hostName(header) {
  const h = String(header || "").toLowerCase();
  if (h.startsWith("[")) return h.slice(0, h.indexOf("]") + 1);
  return h.split(":")[0];
}

function digest(value) {
  return createHash("sha256").update(value).digest();
}

function tokenOk(req) {
  if (!TOKEN) return true;
  const url = new URL(req.url, "http://placeholder");
  if (url.pathname === "/health") return true;
  const auth = req.headers["authorization"] || "";
  const given =
    (auth.startsWith("Bearer ") ? auth.slice(7) : "") ||
    req.headers["x-kitesurf-token"] ||
    url.searchParams.get("token") ||
    "";
  return timingSafeEqual(digest(String(given)), digest(TOKEN));
}

/** Returns an [status, message] rejection, or null when the request may pass. */
function reject(req) {
  if (!ALLOW_ANY_HOST && !ALLOWED.includes(hostName(req.headers.host))) {
    return [421, "Misdirected Request: Host not allowed"];
  }
  if (!tokenOk(req)) return [401, "Unauthorized"];
  return null;
}

const server = http.createServer((req, res) => {
  const denied = reject(req);
  if (denied) {
    res.writeHead(denied[0], { "content-type": "text/plain" }).end(denied[1] + "\n");
    return;
  }
  const upstream = http.request(
    { host: "127.0.0.1", port: INNER_PORT, method: req.method, path: req.url, headers: req.headers },
    (up) => {
      res.writeHead(up.statusCode || 502, up.headers);
      up.pipe(res);
    },
  );
  upstream.on("error", () => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
    res.end("engine not ready\n");
  });
  req.pipe(upstream);
});

server.on("upgrade", (req, socket, head) => {
  const denied = reject(req);
  if (denied) {
    socket.end(`HTTP/1.1 ${denied[0]} ${denied[1]}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
    return;
  }
  const upstream = net.connect(INNER_PORT, "127.0.0.1", () => {
    let raw = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      raw += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`;
    }
    upstream.write(raw + "\r\n");
    if (head.length > 0) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  upstream.on("error", () => socket.destroy());
  socket.on("error", () => upstream.destroy());
  socket.on("close", () => upstream.destroy());
  upstream.on("close", () => socket.destroy());
});

server.listen(PORT, "0.0.0.0");

const child = spawn(command[0], command.slice(1), { stdio: "inherit" });
child.on("exit", (code, signal) => process.exit(code ?? (signal ? 1 : 0)));
for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => child.kill(sig));
}
