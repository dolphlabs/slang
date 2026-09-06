import com.sun.net.httpserver.HttpServer;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;

public class HttpBench {
    static final byte[] BODY =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567"
            .getBytes(StandardCharsets.US_ASCII);

    public static void main(String[] args) throws Exception {
        String ps = System.getenv("HTTP_PORT");
        int port = (ps == null || ps.isEmpty()) ? 18184 : Integer.parseInt(ps);
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 1024);
        server.createContext("/", exchange -> {
            exchange.getResponseHeaders().set("Content-Type", "text/plain");
            exchange.getResponseHeaders().set("Connection", "close");
            exchange.sendResponseHeaders(200, BODY.length);
            OutputStream os = exchange.getResponseBody();
            os.write(BODY);
            os.close();
        });
        server.setExecutor(Executors.newCachedThreadPool());
        System.out.println("LISTEN_PORT " + port);
        System.out.flush();
        server.start();
    }
}
