// ShopLite payments service (Go / net/http).
//
// Tracing: the vendor-neutral OpenTelemetry Go SDK. Go compiles to a static binary, so the
// HTTP handler is wrapped explicitly with otelhttp. Spans go out as OTLP/HTTP to
// OTEL_EXPORTER_OTLP_ENDPOINT, here the Datadog Agent's OTLP receiver (http://localhost:4318),
// which forwards them to Datadog. Service name and env come from OTEL_SERVICE_NAME and
// OTEL_RESOURCE_ATTRIBUTES (deployment.environment.name=lab).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"strings"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

var tracer = otel.Tracer("payments")

type chargeRequest struct {
	OrderID int64   `json:"orderId"`
	Amount  float64 `json:"amount"`
	UserID  string  `json:"userId"`
}

func main() {
	shutdown := setupOTel()
	defer shutdown()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]string{"status": "ok", "service": "payments"})
	})
	mux.HandleFunc("POST /charge", charge)
	mux.HandleFunc("GET /error", func(w http.ResponseWriter, r *http.Request) {
		err := errors.New("deliberate payments failure (chaos endpoint)")
		recordError(r.Context(), err)
		writeJSON(w, 500, map[string]string{"error": err.Error()})
	})

	handler := otelhttp.NewHandler(withRoute(mux), "payments",
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string { return r.Method + " " + r.URL.Path }))

	addr := ":" + envOr("PORT", "8003")
	log.Println("[payments] listening on", addr)
	log.Fatal(http.ListenAndServe(addr, handler))
}

func charge(w http.ResponseWriter, r *http.Request) {
	var req chargeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, 400, map[string]string{"error": "bad json"})
		return
	}
	ctx := r.Context()
	setAttr(ctx, "order_id", req.OrderID)

	// Custom span: business logic no instrumentation can see.
	score := fraudCheck(ctx, req)

	// Simulated call to the card network: usually fast, sometimes very slow.
	bankLatency := time.Duration(30+rand.IntN(60)) * time.Millisecond
	if rand.IntN(100) < 7 {
		bankLatency = time.Duration(1200+rand.IntN(800)) * time.Millisecond
	}
	callBank(ctx, bankLatency)

	if score > 0.92 || req.Amount > 900 {
		err := errors.New("card declined: fraud score too high")
		recordError(ctx, err)
		writeJSON(w, 402, map[string]any{"error": err.Error(), "fraudScore": score})
		return
	}
	writeJSON(w, 200, map[string]any{"status": "approved", "orderId": req.OrderID, "fraudScore": score})
}

func fraudCheck(ctx context.Context, req chargeRequest) float64 {
	ctx, span := tracer.Start(ctx, "fraud-check")
	defer span.End()
	time.Sleep(time.Duration(5+rand.IntN(20)) * time.Millisecond)
	score := rand.Float64()
	setAttr(ctx, "fraud_score", score)
	return score
}

func callBank(ctx context.Context, d time.Duration) {
	_, span := tracer.Start(ctx, "card-network authorize")
	defer span.End()
	time.Sleep(d)
}

// ---------------------------------------------------------------- helpers
// withRoute records the matched mux pattern ("/charge") as http.route, the standard OTel
// attribute Datadog uses for the resource name. Without it every request is just "POST".
func withRoute(mux *http.ServeMux) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, pattern := mux.Handler(r); pattern != "" {
			if _, path, ok := strings.Cut(pattern, " "); ok {
				pattern = path
			}
			trace.SpanFromContext(r.Context()).SetAttributes(attribute.String("http.route", pattern))
		}
		mux.ServeHTTP(w, r)
	})
}

func setAttr(ctx context.Context, key string, value any) {
	span := trace.SpanFromContext(ctx)
	switch v := value.(type) {
	case int64:
		span.SetAttributes(attribute.Int64(key, v))
	case float64:
		span.SetAttributes(attribute.Float64(key, v))
	default:
		span.SetAttributes(attribute.String(key, toString(v)))
	}
}

func recordError(ctx context.Context, err error) {
	span := trace.SpanFromContext(ctx)
	span.RecordError(err)
	span.SetStatus(codes.Error, err.Error())
}

func setupOTel() func() {
	// otlptracehttp reads OTEL_EXPORTER_OTLP_ENDPOINT (default http://localhost:4318).
	exp, err := otlptracehttp.New(context.Background())
	if err != nil {
		log.Fatal(err)
	}
	// resource.Default() reads OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES.
	res, _ := resource.Merge(resource.Default(), resource.NewSchemaless(attribute.String("service.version", "1.0.0")))
	tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exp), sdktrace.WithResource(res))
	otel.SetTracerProvider(tp)
	// W3C traceparent in and out. The Datadog tracers upstream send it alongside their own headers.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))
	tracer = otel.Tracer("payments")
	return func() { _ = tp.Shutdown(context.Background()) }
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func toString(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
