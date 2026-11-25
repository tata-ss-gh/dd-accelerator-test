package dev.shoplite.orders;

import io.opentelemetry.api.trace.Span;
import io.opentelemetry.instrumentation.annotations.WithSpan;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

@RestController
public class OrdersController {

    private static final Logger log = LoggerFactory.getLogger(OrdersController.class);
    private final JdbcTemplate db;
    private final RestClient http = RestClient.create();
    private final String paymentsUrl = env("PAYMENTS_URL", "http://localhost:8003");
    private final String notificationsUrl = env("NOTIFICATIONS_URL", "http://localhost:8004");

    public OrdersController(JdbcTemplate db) {
        this.db = db;
    }

    public record OrderRequest(int productId, int quantity, String userId, double amount) {}

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("status", "ok", "service", "orders");
    }

    @PostMapping("/orders")
    public ResponseEntity<Map<String, Object>> create(@RequestBody OrderRequest req) {
        tag("order_amount", req.amount());
        tag("product_id", req.productId());
        Span.current().setAttribute("usr.id", req.userId());   // Datadog's user attribute

        validate(req);

        // JDBC is auto-instrumented: this becomes an "INSERT INTO orders" span.
        db.update("INSERT INTO orders (product_id, quantity, user_id, amount, status) VALUES (?, ?, ?, ?, 'NEW')",
                req.productId(), req.quantity(), req.userId(), req.amount());
        Long orderId = db.queryForObject("SELECT MAX(id) FROM orders", Long.class);
        tag("order_id", orderId);

        // Outgoing HTTP is auto-instrumented and carries the trace context to the Go service.
        Map<?, ?> payment;
        try {
            payment = http.post().uri(paymentsUrl + "/charge")
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(Map.of("orderId", orderId, "amount", req.amount(), "userId", req.userId()))
                    .retrieve().body(Map.class);
        } catch (RestClientException e) {
            db.update("UPDATE orders SET status = 'PAYMENT_FAILED' WHERE id = ?", orderId);
            log.warn("order {} payment failed: {}", orderId, e.getMessage());
            throw new ResponseStatusExceptionWithBody(HttpStatus.PAYMENT_REQUIRED, "payment failed: " + e.getMessage());
        }
        db.update("UPDATE orders SET status = 'PAID' WHERE id = ?", orderId);
        log.info("order {} paid, amount {}", orderId, req.amount());

        // A failed notification must not fail the order: catch it, but still record it on the span.
        try {
            http.post().uri(notificationsUrl + "/send")
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(Map.of("orderId", orderId, "userId", req.userId(), "channel", "email"))
                    .retrieve().toBodilessEntity();
        } catch (RestClientException e) {
            log.warn("order {} notification failed, order still OK: {}", orderId, e.getMessage());
            Span.current().recordException(e);
        }

        return ResponseEntity.status(HttpStatus.CREATED)
                .body(Map.of("orderId", orderId, "status", "PAID", "payment", payment == null ? Map.of() : payment));
    }

    /** A custom span around business logic (OpenTelemetry annotation, honoured by dd-java-agent). */
    @WithSpan("validate-order")
    void validate(OrderRequest req) {
        sleepMs(ThreadLocalRandom.current().nextInt(5, 25));
        if (req.quantity() <= 0 || req.amount() <= 0) {
            throw new ResponseStatusExceptionWithBody(HttpStatus.BAD_REQUEST, "invalid order");
        }
    }

    @GetMapping("/orders/{id}")
    public Map<String, Object> get(@PathVariable long id) {
        return db.queryForMap("SELECT * FROM orders WHERE id = ?", id);
    }

    // ---- chaos endpoints ----
    @GetMapping("/slow")
    public Map<String, Object> slow(@RequestParam(defaultValue = "1500") int ms) {
        sleepMs(ms);
        return Map.of("sleptMs", ms);
    }

    @GetMapping("/error")
    public Map<String, Object> error() {
        throw new IllegalStateException("Deliberate orders failure (chaos endpoint)");
    }

    // ---- helpers ----
    private static void tag(String key, Number value) {
        Span.current().setAttribute(key, value.doubleValue());
    }

    private static void sleepMs(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }

    private static String env(String k, String d) {
        String v = System.getenv(k);
        return v == null || v.isBlank() ? d : v;
    }

    /** Turns into an HTTP error response with a JSON body. */
    static class ResponseStatusExceptionWithBody extends org.springframework.web.server.ResponseStatusException {
        ResponseStatusExceptionWithBody(HttpStatus status, String reason) { super(status, reason); }
    }
}
