# ShopLite (Datadog-instrumented demo)

A small polyglot shop used to exercise Datadog APM, logs, metrics and RUM. One checkout
travels through five services in five languages, so a single distributed trace covers all of them.

```
Browser (Datadog RUM) ─► gateway  (Node / Express  :3000)
                           ├─► catalog  (Python / FastAPI + SQLite  :8001)
                           └─► orders   (Java / Spring Boot + H2    :8002)
                                  ├─► payments      (Go / net/http      :8003)
                                  └─► notifications (.NET 8 minimal API :8004)
```

## How each service is instrumented

| Service | Language | Tracer | How it is loaded | Code-level usage |
|---|---|---|---|---|
| gateway | Node.js 24 | `dd-trace` (npm) | `node -r dd-trace/init server.js` | `tracer.trace()` custom spans, `scope().active().setTag()`, `tracer.setUser()`, DogStatsD via `tracer.dogstatsd` |
| catalog | Python 3 | `ddtrace` (pip) | `ddtrace-run uvicorn app:app` | `@tracer.wrap()` custom span, `current_root_span().set_tag()`, `datadog.DogStatsd` metrics |
| orders | Java 21 | `dd-java-agent.jar` | `-javaagent:agents/dd-java-agent.jar` | OpenTelemetry API only (`@WithSpan`, `Span.current().setAttribute()`), honoured via `DD_TRACE_OTEL_ENABLED=true` |
| payments | Go | OpenTelemetry Go SDK | compiled in (`otelhttp`) | OTLP/HTTP to the Datadog Agent's OTLP receiver (`:4318`) |
| notifications | .NET 8 | `Datadog.Trace.Bundle` (NuGet) | CLR profiler via `CORECLR_*` env vars | `Tracer.Instance.ActiveScope.Span.SetTag/SetException`, custom spans with `ActivitySource` |
| shop-frontend | Browser | Datadog Browser RUM SDK v7 (CDN) | `<script>` in `frontend/index.html` | `DD_RUM.init()`, `DD_RUM.setUser()`, `allowedTracingUrls` links RUM to backend traces |

Common settings (unified service tagging and friends), set by `scripts/start-services.ps1`:
`DD_SERVICE` (per service), `DD_ENV=lab`, `DD_VERSION=1.0.0`, `DD_LOGS_INJECTION=true`,
`DD_RUNTIME_METRICS_ENABLED=true`, `DD_TRACE_OTEL_ENABLED=true`.

### Logs
gateway, catalog and orders write JSON lines to `LOG_DIR` (default `C:\DatadogLab\logs\shoplite`):

| Service | Library | File | Notable fields |
|---|---|---|---|
| gateway | pino | `gateway.json` | `level`, `timestamp`, `message`, `error.{type,message,stack}`, `dd.trace_id` |
| catalog | python-json-logger | `catalog.json` | `level`, `timestamp`, `logger_name`, `message`, `dd.trace_id` |
| orders | Spring Boot structured logging (Logstash layout) | `orders.json` | `level`, `@timestamp`, `logger_name`, `thread_name`, `stack_trace`, `dd.trace_id` |

The Datadog Agent tails them with [`datadog/conf.d/shoplite.d/conf.yaml`](datadog/conf.d/shoplite.d/conf.yaml).

### Datadog integrations
| Integration | Config | What it reports |
|---|---|---|
| HTTP Check | [`datadog/conf.d/http_check.d`](datadog/conf.d/http_check.d/conf.yaml) | `/health` of each service plus the storefront page: `http.can_connect`, `network.http.response_time` |
| TCP Check | [`datadog/conf.d/tcp_check.d`](datadog/conf.d/tcp_check.d/conf.yaml) | ports 3000, 8001-8004: `tcp.can_connect`, `network.tcp.response_time` |
| Process | [`datadog/conf.d/process.d`](datadog/conf.d/process.d/conf.yaml) | one instance per service process: `process.up`, `system.processes.*` |
| Tomcat (JMX) | `DD_JMXFETCH_TOMCAT_ENABLED=true` on orders + `server.tomcat.mbeanregistry.enabled=true` | `tomcat.threads.*`, `tomcat.request_count`, `tomcat.error_count`, via JMXFetch in dd-java-agent |
| Logs | [`datadog/conf.d/shoplite.d`](datadog/conf.d/shoplite.d/conf.yaml) | the three JSON log files |
| OTLP ingest | Agent OTLP receiver on `:4318` | payments traces (OpenTelemetry SDK) |

Synthetic tests run from a Windows **private location** on the same host, so they can reach `localhost`.

### Custom metrics (DogStatsD)
`shoplite.checkout.count` (count, by `result`), `shoplite.gateway.checkouts_inflight` (gauge),
`shoplite.checkout.amount` (distribution, by `product_id`), `shoplite.checkout.amount_hist` (histogram),
`shoplite.checkout.by_user` (count by `user_id`: a deliberate high-cardinality anti-pattern),
`shoplite.catalog.db_queries_per_request` (histogram).

## Run it on Windows

Prerequisites: the Datadog Agent 7 (with `logs_enabled: true` and OTLP receiver on 4318), Node 20+,
Python 3.11+, JDK 21, Go 1.24+, .NET 8 SDK.

```powershell
copy .env.example .env        # optional: fill in DD_RUM_APP_ID / DD_RUM_CLIENT_TOKEN for browser RUM
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1            # install + build everything
# once, as Administrator: log collection and the HTTP / TCP / process checks
Copy-Item -Recurse -Force datadog\conf.d\* C:\ProgramData\Datadog\conf.d\
Restart-Service datadogagent -Force   # -Force: the trace/process/OTel agents depend on it
powershell -ExecutionPolicy Bypass -File scripts\start-services.ps1   # start (-Stop to stop)
node tools\load.js 60 4                                               # traffic: 60 s at 4 req/s
```

Open http://localhost:3000 for the shop.

## Run it with Docker

```bash
cp .env.example .env   # set DD_API_KEY (and optionally DD_RUM_*)
docker compose up --build
```

The compose file runs a Datadog Agent container next to the five services. It has not been
tested on the Windows machine this project was built on; the Windows scripts above are the reference.

## Chaos endpoints

| Endpoint | Effect |
|---|---|
| `GET /api/slow?ms=1800` (gateway), `/slow` (catalog, orders) | Latency |
| `GET /api/error` (gateway), `/error` (every service) | Exceptions |
| `GET /n-plus-one` (catalog) | N+1 SQL queries in one request |
| `POST /api/checkout` with `productId: 999` | 404 from catalog, failed checkout |
| payments | ~7% very slow card-network calls; random declines (402) |
| notifications | 12% simulated email-provider timeouts (503, handled by orders) |
