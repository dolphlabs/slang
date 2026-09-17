// light/http-static for C#: raw async sockets, one accept loop per core.
// Same bytes as bench/http/main.c. See bench/SPEC.md.
using System.Net;
using System.Net.Sockets;
using System.Text;

var response = Encoding.ASCII.GetBytes(
    "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 200\r\nConnection: close\r\n\r\n" +
    string.Concat(Enumerable.Repeat("0123456789abcdef", 12)) + "01234567");
int port = int.TryParse(Environment.GetEnvironmentVariable("HTTP_PORT"), out var p) ? p : 18186;
int loops = int.TryParse(Environment.GetEnvironmentVariable("WORKERS"), out var w) && w > 0 ? w : Environment.ProcessorCount;

var listener = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
listener.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
listener.Bind(new IPEndPoint(IPAddress.Any, port));
listener.Listen(4096);
Console.WriteLine($"LISTEN_PORT {port}");

async Task Serve(Socket s) {
    var buf = new byte[2048];
    try {
        s.NoDelay = true;
        if (await s.ReceiveAsync(buf, SocketFlags.None) > 0)
            await s.SendAsync(response, SocketFlags.None);
    } catch (SocketException) {
    } finally {
        s.Dispose();
    }
}

async Task AcceptLoop() {
    while (true) {
        var s = await listener.AcceptAsync();
        _ = Serve(s);
    }
}

await Task.WhenAll(Enumerable.Range(0, loops).Select(_ => AcceptLoop()));
