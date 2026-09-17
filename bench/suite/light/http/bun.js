// light/http-static for Bun: raw TCP (Bun.listen), one process per core
// sharing the port. Same bytes as bench/http/main.c. See bench/SPEC.md.
import os from "node:os";

const RESPONSE = new TextEncoder().encode(
  "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 200\r\nConnection: close\r\n\r\n" +
  "0123456789abcdef".repeat(12) + "01234567");
const PORT = Number(process.env.HTTP_PORT) || 18188;
const WORKERS = Number(process.env.WORKERS) || os.availableParallelism();

if (!process.env.BENCH_CHILD && WORKERS > 1) {
  const kids = [];
  for (let i = 0; i < WORKERS; i++) {
    kids.push(Bun.spawn([process.execPath, import.meta.path], {
      env: { ...process.env, BENCH_CHILD: "1" }, stdout: "inherit", stderr: "inherit" }));
  }
  console.log(`LISTEN_PORT ${PORT}`);
  const stop = () => { for (const k of kids) k.kill(); process.exit(0); };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
  await Promise.race(kids.map((k) => k.exited));
  process.exit(1);
}

Bun.listen({
  hostname: "0.0.0.0",
  port: PORT,
  reusePort: true,
  socket: {
    data(sock) {
      sock.write(RESPONSE);
      sock.end();
    },
    error() {},
  },
});
if (WORKERS === 1) console.log(`LISTEN_PORT ${PORT}`);
