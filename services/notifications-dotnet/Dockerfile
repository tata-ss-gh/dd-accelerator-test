FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY . .
RUN dotnet publish -c Release -o /out

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=build /out .
# Datadog.Trace.Bundle publishes the tracer into ./datadog; these variables load it as a CLR profiler.
ENV BIND_HOST=0.0.0.0 PORT=8004 DD_SERVICE=notifications DD_RUNTIME_METRICS_ENABLED=true DD_TRACE_OTEL_ENABLED=true \
    CORECLR_ENABLE_PROFILING=1 \
    CORECLR_PROFILER={846F5F1C-F9AE-4B07-969E-05C26BC060D8} \
    CORECLR_PROFILER_PATH=/app/datadog/linux-x64/Datadog.Trace.ClrProfiler.Native.so \
    DD_DOTNET_TRACER_HOME=/app/datadog
EXPOSE 8004
ENTRYPOINT ["dotnet", "Notifications.dll"]
