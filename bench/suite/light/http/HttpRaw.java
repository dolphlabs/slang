// light/http-static for Java: raw TCP, a virtual thread per connection.
// Same bytes as bench/http/main.c. See bench/SPEC.md.
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;

public class HttpRaw {
    static final byte[] RESPONSE = ("HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 200\r\n"
            + "Connection: close\r\n\r\n" + "0123456789abcdef".repeat(12) + "01234567")
            .getBytes(StandardCharsets.US_ASCII);

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(System.getenv().getOrDefault("HTTP_PORT", "18184"));
        var server = new ServerSocket();
        server.setReuseAddress(true);
        server.bind(new InetSocketAddress("0.0.0.0", port), 4096);
        System.out.println("LISTEN_PORT " + port);
        System.out.flush();
        try (var pool = Executors.newVirtualThreadPerTaskExecutor()) {
            while (true) {
                Socket s = server.accept();
                pool.execute(() -> {
                    try (s) {
                        s.setTcpNoDelay(true);
                        InputStream in = s.getInputStream();
                        byte[] buf = new byte[2048];
                        if (in.read(buf) > 0) {
                            OutputStream out = s.getOutputStream();
                            out.write(RESPONSE);
                            out.flush();
                        }
                    } catch (Exception ignored) {
                    }
                });
            }
        }
    }
}
