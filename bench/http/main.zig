const std = @import("std");

const RESPONSE =
    "HTTP/1.0 200 OK\r\n" ++
    "Content-Type: text/plain\r\n" ++
    "Content-Length: 200\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ++
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ++
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ++
    "01234567";

fn handle(conn: std.net.Server.Connection) void {
    defer conn.stream.close();
    var buf: [2048]u8 = undefined;
    _ = conn.stream.read(&buf) catch return;
    _ = conn.stream.writeAll(RESPONSE) catch return;
}

pub fn main() !void {
    const port_str = std.posix.getenv("HTTP_PORT") orelse "18185";
    const port = try std.fmt.parseInt(u16, port_str, 10);
    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    var server = try addr.listen(.{ .reuse_address = true });
    const stdout = std.io.getStdOut().writer();
    try stdout.print("LISTEN_PORT {d}\n", .{port});

    while (true) {
        const conn = server.accept() catch continue;
        const th = std.Thread.spawn(.{}, handle, .{conn}) catch {
            handle(conn);
            continue;
        };
        th.detach();
    }
}
