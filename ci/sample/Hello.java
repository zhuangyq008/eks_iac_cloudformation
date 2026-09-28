import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
public class Hello {
  public static void main(String[] a) throws Exception {
    HttpServer s = HttpServer.create(new InetSocketAddress(8080), 0);
    s.createContext("/", x -> {
      byte[] b = ("order-service ok, java " + System.getProperty("java.version") + ", arch " + System.getProperty("os.arch") + "\n").getBytes();
      x.sendResponseHeaders(200, b.length); x.getResponseBody().write(b); x.close();
    });
    s.start();
  }
}
