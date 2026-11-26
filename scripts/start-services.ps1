# Starts all five ShopLite services on Windows, each in its own minimized window, traced by Datadog.
#
#   powershell -ExecutionPolicy Bypass -File scripts\start-services.ps1                   # start
#   powershell -ExecutionPolicy Bypass -File scripts\start-services.ps1 -RemoteSampling   # let Datadog decide sampling
#   powershell -ExecutionPolicy Bypass -File scripts\start-services.ps1 -Stop             # stop
#
# Needs the Datadog Agent running locally: traces :8126, DogStatsD :8125/udp, OTLP :4318,
# and log collection for the files in $env:LOG_DIR (see datadog/conf.d/shoplite.d/conf.yaml).
# Console output of each service goes to logs\<service>.log.
param(
    [switch]$RemoteSampling,
    [switch]$Stop
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$ports = [ordered]@{ gateway = 3000; catalog = 8001; orders = 8002; payments = 8003; notifications = 8004 }

function Stop-Port($port) {
    $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($c) { Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue; return $true }
    return $false
}

foreach ($name in $ports.Keys) { if (Stop-Port $ports[$name]) { Write-Host "stopped $name" } }
if ($Stop) { return }

# Optional .env (git-ignored): DD_RUM_APP_ID, DD_RUM_CLIENT_TOKEN, DD_SITE, DD_ENV, LOG_DIR. See .env.example.
$envFile = Join-Path $root '.env'
if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object {
        $k, $v = $_.Trim() -split '=', 2; Set-Item "env:$k" $v
    }
}

# Unified service tagging: env / version on every span, log and metric (service is set per process).
if (-not $env:DD_ENV) { $env:DD_ENV = 'lab' }
$env:DD_VERSION = '1.0.0'
$env:DD_LOGS_INJECTION = 'true'           # dd.trace_id / dd.span_id in every log line
$env:DD_RUNTIME_METRICS_ENABLED = 'true'  # heap, GC, threads, event loop via DogStatsD
$env:DD_TRACE_OTEL_ENABLED = 'true'       # honour OpenTelemetry API calls (@WithSpan, ActivitySource)
$env:DD_REMOTE_CONFIGURATION_ENABLED = $(if ($RemoteSampling) { 'true' } else { 'false' })

# Application log files (JSON lines). The Datadog Agent runs as ddagentuser and cannot read
# the user profile, so they go to a shared folder.
if (-not $env:LOG_DIR) { $env:LOG_DIR = 'C:\DatadogLab\logs\shoplite' }
New-Item -ItemType Directory -Force $env:LOG_DIR, (Join-Path $root 'logs') | Out-Null

$java = (Get-Command java -ErrorAction SilentlyContinue).Source
if (-not $java) { $java = 'C:\Program Files\Eclipse Adoptium\jdk-21.0.13.9-hotspot\bin\java.exe' }

function Start-Svc($name, $dir, $command, $extra = @{}) {
    $log = Join-Path $root "logs\$name.log"
    $env:DD_SERVICE = $name
    # Per-service variables, restored after the process has started.
    $saved = @{}
    foreach ($k in $extra.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); Set-Item "env:$k" $extra[$k] }
    # "title ... &&" first: cmd.exe would otherwise strip the quotes of a command that starts with a quoted path.
    Start-Process cmd.exe -WorkingDirectory (Join-Path $root $dir) -WindowStyle Minimized `
        -ArgumentList "/c title $name && $command > `"$log`" 2>&1"
    foreach ($k in $saved.Keys) { if ($null -eq $saved[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } else { Set-Item "env:$k" $saved[$k] } }
    Write-Host ("started {0,-14}" -f $name)
}

# --- Go payments: OpenTelemetry SDK, OTLP to the Datadog Agent's receiver.
Start-Svc 'payments' 'services\payments-go' '.\payments.exe' @{
    OTEL_SERVICE_NAME = 'payments'
    OTEL_EXPORTER_OTLP_ENDPOINT = 'http://localhost:4318'
    OTEL_RESOURCE_ATTRIBUTES = "deployment.environment.name=$env:DD_ENV,service.version=$env:DD_VERSION"
}

# --- .NET notifications: Datadog CLR profiler from the Datadog.Trace.Bundle package.
$ddHome = Join-Path $root 'services\notifications-dotnet\bin\Release\net8.0\datadog'
Start-Svc 'notifications' 'services\notifications-dotnet' 'dotnet bin\Release\net8.0\Notifications.dll' @{
    CORECLR_ENABLE_PROFILING = '1'
    CORECLR_PROFILER = '{846F5F1C-F9AE-4B07-969E-05C26BC060D8}'
    CORECLR_PROFILER_PATH_64 = "$ddHome\win-x64\Datadog.Trace.ClrProfiler.Native.dll"
    DD_DOTNET_TRACER_HOME = $ddHome
}

# --- Java orders: dd-java-agent on the command line; JSON log file for the Agent to tail.
# DD_JMXFETCH_TOMCAT_ENABLED turns on the Datadog Tomcat integration inside the tracer (tomcat.* metrics).
Start-Svc 'orders' 'services\orders-java' "`"$java`" -Xmx256m -javaagent:agents\dd-java-agent.jar -Dlogging.file.name=$env:LOG_DIR\orders.json -jar target\orders-0.0.1-SNAPSHOT.jar" @{
    DD_JMXFETCH_TOMCAT_ENABLED = 'true'
}

# --- Python catalog: ddtrace-run.
Start-Svc 'catalog' 'services\catalog-python' '.venv\Scripts\ddtrace-run .venv\Scripts\python -m uvicorn app:app --port 8001 --log-level warning'

# --- Node gateway: dd-trace preloaded with -r. No span per Express middleware, so inside a
# route handler the active span is the request span and tags land on it.
Start-Svc 'gateway' 'services\gateway-node' 'node -r dd-trace/init server.js' @{ DD_TRACE_MIDDLEWARE_TRACING_ENABLED = 'false' }

Write-Host "`nWaiting for health checks..."
$deadline = (Get-Date).AddSeconds(90)
foreach ($name in $ports.Keys) {
    do {
        $ok = (& curl.exe -s -m 2 -o NUL -w '%{http_code}' "http://localhost:$($ports[$name])/health") -eq '200'
        if (-not $ok) { Start-Sleep -Milliseconds 800 }
    } until ($ok -or (Get-Date) -gt $deadline)
    Write-Host ("  {0,-14} {1}" -f $name, $(if ($ok) { 'up' } else { "NOT UP. See logs\$name.log" }))
}

# PID files for the Datadog process check. The Agent runs as ddagentuser, which cannot read the
# command lines of our processes, so it finds each service by the PID of the process on its port.
$pidDir = Join-Path (Split-Path $env:LOG_DIR -Parent) 'pids'
New-Item -ItemType Directory -Force $pidDir | Out-Null
foreach ($name in $ports.Keys) {
    $c = Get-NetTCPConnection -LocalPort $ports[$name] -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { Set-Content -Path (Join-Path $pidDir "$name.pid") -Value $c.OwningProcess -Encoding ascii -NoNewline }
}
Write-Host "`nOpen http://localhost:3000 for the shop, or run: node tools/load.js 60 4"
