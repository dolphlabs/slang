using System.Net;
using System.Text;

const string body =
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567";
var bytes = Encoding.ASCII.GetBytes(body);

var ps = Environment.GetEnvironmentVariable("HTTP_PORT");
var port = string.IsNullOrEmpty(ps) ? 18186 : int.Parse(ps);

var listener = new HttpListener();
listener.Prefixes.Add($"http://127.0.0.1:{port}/");
listener.Prefixes.Add($"http://localhost:{port}/");
listener.Start();
Console.WriteLine($"LISTEN_PORT {port}");
Console.Out.Flush();

while (true)
{
    var ctx = await listener.GetContextAsync();
    _ = Task.Run(() =>
    {
        try
        {
            ctx.Response.StatusCode = 200;
            ctx.Response.ContentType = "text/plain";
            ctx.Response.ContentLength64 = bytes.Length;
            ctx.Response.KeepAlive = false;
            ctx.Response.Headers["Connection"] = "close";
            ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
            ctx.Response.OutputStream.Close();
            ctx.Response.Close();
        }
        catch
        {
            try { ctx.Response.Abort(); } catch { }
        }
    });
}
