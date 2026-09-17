// light/http-static for Node: raw TCP, one process per core (cluster).
// Same bytes as bench/http/main.c. See bench/SPEC.md.
import cluster from "node:cluster";
import net from "node:net";
import os from "node:os";

const RESPONSE = Buffer.from(
  "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 200\r\nConnection: close\r\n\r\n" +
  "0123456789abcdef".repeat(12) + "01234567");
const PORT = Number(process.env.HTTP_PORT) || 18187;
const WORKERS = Number(process.env.WORKERS) || os.availableParallelism();

if (cluster.isPrimary && WORKERS > 1) {
  for (let i = 0; i < WORKERS; i++) cluster.fork();
  console.log(`LISTEN_PORT ${PORT}`);
} else {
  net.createServer({ noDelay: true }, (sock) => {
    sock.once("data", () => sock.end(RESPONSE));
    sock.on("error", () => {});
  }).listen({ port: PORT, backlog: 4096 });
  if (WORKERS === 1) console.log(`LISTEN_PORT ${PORT}`);
}
