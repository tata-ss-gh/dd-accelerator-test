package dev.shoplite.orders;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * ShopLite orders service (Java / Spring Boot).
 *
 * Tracing: the Datadog Java agent is attached on the command line, no code change:
 *   java -javaagent:agents/dd-java-agent.jar -jar target/orders-0.0.1-SNAPSHOT.jar
 * Custom spans and attributes use the vendor-neutral OpenTelemetry API; the Datadog agent
 * honours it when DD_TRACE_OTEL_ENABLED=true.
 */
@SpringBootApplication
public class OrdersApplication {

    public static void main(String[] args) {
        SpringApplication.run(OrdersApplication.class, args);
    }
}
