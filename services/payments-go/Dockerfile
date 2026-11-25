FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /payments .

FROM gcr.io/distroless/static-debian12
COPY --from=build /payments /payments
# OpenTelemetry SDK -> OTLP/HTTP -> Datadog Agent (OTLP receiver on 4318)
ENV OTEL_SERVICE_NAME=payments OTEL_EXPORTER_OTLP_ENDPOINT=http://datadog-agent:4318
EXPOSE 8003
ENTRYPOINT ["/payments"]
