"""light/http-static for Python: uvloop raw asyncio Protocol, one process
per core on SO_REUSEPORT. Same bytes as bench/http/main.c. See bench/SPEC.md."""
import asyncio
import os
import socket

import uvloop

RESPONSE = (b"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 200\r\n"
            b"Connection: close\r\n\r\n" + b"0123456789abcdef" * 12 + b"01234567")
PORT = int(os.environ.get("HTTP_PORT", "18189"))


class Static(asyncio.Protocol):
    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        self.transport.write(RESPONSE)
        self.transport.close()


async def serve(sock):
    loop = asyncio.get_running_loop()
    server = await loop.create_server(Static, sock=sock, backlog=4096)
    await server.serve_forever()


def child():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(("0.0.0.0", PORT))
    sock.listen(4096)
    uvloop.run(serve(sock))


def main():
    workers = int(os.environ.get("WORKERS") or (len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count()))
    print(f"LISTEN_PORT {PORT}", flush=True)
    if workers == 1:
        child()
        return
    for _ in range(workers):
        if os.fork() == 0:
            child()
            os._exit(0)
    os.wait()


if __name__ == "__main__":
    main()
