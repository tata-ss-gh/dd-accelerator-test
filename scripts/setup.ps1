# Installs dependencies and builds all five ShopLite services (Windows).
#   powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
# Needs: Node 20+, Python 3.11+ (py launcher), JDK 21, Go 1.24+, .NET 8 SDK.
# Exit codes decide failure: build tools write notices to stderr, which PowerShell 5.1 would treat as errors.
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
function Step($name, [scriptblock]$block) {
    Write-Host "== $name"
    & $block
    if ($LASTEXITCODE) { throw "$name failed (exit $LASTEXITCODE)" }
}

Step 'gateway (npm)' { Push-Location "$root\services\gateway-node"; npm install --no-audit --no-fund; Pop-Location }

Step 'catalog (venv + pip)' {
    Push-Location "$root\services\catalog-python"
    if (-not (Test-Path .venv)) { py -m venv .venv }
    .venv\Scripts\python -m pip install -q -r requirements.txt
    Pop-Location
}

Step 'orders (Maven + dd-java-agent)' {
    Push-Location "$root\services\orders-java"
    .\mvnw.cmd -q -B -DskipTests package
    New-Item -ItemType Directory -Force agents | Out-Null
    if (-not (Test-Path agents\dd-java-agent.jar)) {
        curl.exe -sSL -o agents\dd-java-agent.jar https://dtdg.co/latest-java-tracer
    }
    Pop-Location
}

Step 'payments (go build)' { Push-Location "$root\services\payments-go"; go build -o payments.exe .; Pop-Location }

Step 'notifications (dotnet build)' { Push-Location "$root\services\notifications-dotnet"; dotnet build -c Release --nologo -v q; Pop-Location }

Write-Host "`nDone. Start everything with: powershell -ExecutionPolicy Bypass -File scripts\start-services.ps1"
