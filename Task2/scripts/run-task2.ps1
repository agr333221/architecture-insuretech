# Задание 2: динамическое масштабирование в Kubernetes (minikube в Docker).
# Часть 1 - HPA по памяти, часть 2 - HPA по RPS (Prometheus + Prometheus Adapter).
# Результаты: ..\logs (логи) и ..\screenshots (скриншоты).
# Повторный запуск безопасен: существующие ресурсы обновляются.

param(
    [ValidateSet('all','part1','part2')] [string]$Stage = 'all',
    [int]$Users = 300,          # число пользователей locust
    [int]$SpawnRate = 10,       # пользователей в секунду
    [string]$Duration = '6m'    # длительность нагрузки
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Task2  = Split-Path $PSScriptRoot -Parent
$Logs   = Join-Path $Task2 'logs'
$Shots  = Join-Path $Task2 'screenshots'
$P1     = Join-Path $Task2 'part1'
$P2     = Join-Path $Task2 'part2'
$Locustfile = Join-Path $Task2 'locustfile.py'
$Prof   = 'sprint8'
$Tmp    = Join-Path $env:TEMP 'sprint8-task2'
New-Item -ItemType Directory -Force $Logs, $Shots, $Tmp | Out-Null
Start-Transcript -Path (Join-Path $Logs '00-run-transcript.log') -Append | Out-Null

function Log([string]$m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor Cyan }
function Has([string]$c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function RefreshPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
}
function Fail([string]$m) { Write-Host "ОШИБКА: $m" -ForegroundColor Red; Stop-Transcript | Out-Null; exit 1 }
function K { & kubectl --context $Prof @args }
function Save([string]$name, [scriptblock]$cmd) {
    $f = Join-Path $Logs $name
    ("# {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) | Out-File -FilePath $f -Encoding utf8 -Append
    (& $cmd 2>&1 | Out-String) | Out-File -FilePath $f -Encoding utf8 -Append
}

# ---------- Edge headless для скриншотов ----------
$Edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
          "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
          "$env:ProgramFiles\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
function Shot([string]$url, [string]$name, [int]$wait = 15000) {
    if (-not $Edge) { Log "Браузер для скриншотов не найден, пропуск $name"; return }
    $file = Join-Path $Shots $name
    $eargs = @('--headless=new','--disable-gpu','--hide-scrollbars','--no-first-run',
              "--user-data-dir=$Tmp\edge-profile",'--window-size=1680,1050',
              "--virtual-time-budget=$wait","--screenshot=$file", $url)
    Start-Process -FilePath $Edge -ArgumentList $eargs -Wait -WindowStyle Hidden
    if (Test-Path $file) { Log "Скриншот: $name" } else { Log "Не удалось сделать скриншот $name" }
}

# ---------- фоновые процессы (service url, dashboard, port-forward) ----------
$Bg = @()
function StartBg([string]$exe, [string]$argline, [string]$outName) {
    $out = Join-Path $Tmp "$outName.out"; $err = Join-Path $Tmp "$outName.err"
    Remove-Item $out, $err -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $exe -ArgumentList $argline -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
    $script:Bg += $p
    return $out
}
function WaitUrl([string]$outFile, [int]$timeoutSec = 180) {
    $t = 0
    while ($t -lt $timeoutSec) {
        if (Test-Path $outFile) {
            $m = Select-String -Path $outFile -Pattern 'http://127\.0\.0\.1:\d+\S*' -AllMatches | Select-Object -First 1
            if ($m) { return $m.Matches[0].Value }
        }
        Start-Sleep 2; $t += 2
    }
    return $null
}
function StopBg { foreach ($p in $script:Bg) { try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } } catch {} }; $script:Bg = @() }

# ---------- 1. Проверка и установка инструментов ----------
Log 'Проверка инструментов'
if (-not (Has docker)) { Fail 'Docker Desktop не установлен. Установите Docker Desktop (https://www.docker.com/products/docker-desktop/), запустите его и повторите.' }
docker info *> $null
if ($LASTEXITCODE -ne 0) { Fail 'Docker Desktop не запущен. Запустите Docker Desktop, дождитесь статуса Engine running и повторите.' }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Tools = Join-Path $env:LOCALAPPDATA 'sprint8-tools'
New-Item -ItemType Directory -Force $Tools | Out-Null
$env:Path = "$Tools;" + $env:Path
function Download([string]$url, [string]$dest) {
    Log "Скачивание $url"
    try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest; return $true }
    catch { Log ("Ошибка скачивания: " + $_.Exception.Message); return $false }
}
if (-not (Has 'minikube')) {
    if (-not (Download 'https://github.com/kubernetes/minikube/releases/latest/download/minikube-windows-amd64.exe' (Join-Path $Tools 'minikube.exe'))) { Fail 'Не удалось скачать minikube (проверьте доступ в интернет / VPN)' }
}
if (-not (Has 'kubectl')) {
    $kv = 'v1.31.2'
    try { $kv = (Invoke-WebRequest -UseBasicParsing 'https://dl.k8s.io/release/stable.txt').Content.Trim() } catch {}
    if (-not (Download "https://dl.k8s.io/release/$kv/bin/windows/amd64/kubectl.exe" (Join-Path $Tools 'kubectl.exe'))) { Fail 'Не удалось скачать kubectl' }
}
if (-not (Has 'helm')) {
    $zip = Join-Path $Tmp 'helm.zip'
    if (-not (Download 'https://get.helm.sh/helm-v3.16.2-windows-amd64.zip' $zip)) { Fail 'Не удалось скачать helm' }
    Expand-Archive -Path $zip -DestinationPath (Join-Path $Tmp 'helm') -Force
    Copy-Item (Join-Path $Tmp 'helm\windows-amd64\helm.exe') (Join-Path $Tools 'helm.exe') -Force
}
foreach ($c in 'minikube','kubectl','helm') { if (-not (Has $c)) { Fail "$c не найден" } }
$Py = $null
foreach ($c in 'py','python','python3') {
    if (Has $c) { & $c --version *> $null; if ($LASTEXITCODE -eq 0) { $Py = $c; break } }
}
if (-not $Py) { Fail 'Python не найден. Установите Python 3 с https://www.python.org/downloads/ и повторите.' }
& $Py -m locust --version *> $null
if ($LASTEXITCODE -ne 0) { Log 'Установка locust (pip)'; & $Py -m pip install --upgrade pip locust }
Save '00-versions.log' { docker version; minikube version; kubectl version --client; helm version; & $Py --version; & $Py -m locust --version }

# ---------- 2. Кластер minikube ----------
Log "Запуск minikube (профиль $Prof, драйвер docker)"
$dockerMemMb = [int]([int64](docker info --format '{{.MemTotal}}') / 1MB)
$dockerCpu   = [int](docker info --format '{{.NCPU}}')
$mem  = [Math]::Min(6144, $dockerMemMb - 512)
$cpus = [Math]::Min(4, $dockerCpu)
if ($mem -lt 3500) { Log "ВНИМАНИЕ: Docker выделено мало памяти ($dockerMemMb MB). Для части 2 нужно >= 4 GB (Docker Desktop -> Settings -> Resources / .wslconfig)." }
minikube start -p $Prof --driver=docker --cpus=$cpus --memory=${mem}mb --addons=metrics-server
if ($LASTEXITCODE -ne 0) { Fail 'minikube start завершился с ошибкой' }
minikube addons enable metrics-server -p $Prof
minikube addons enable dashboard -p $Prof
Save '01-cluster.log' { minikube status -p $Prof; K get nodes -o wide; K get pods -A }

$dashOut = StartBg 'minikube' "dashboard -p $Prof --url" 'dashboard'
$DashUrl = WaitUrl $dashOut 240
if ($DashUrl) { Log "Dashboard: $DashUrl" } else { Log 'Dashboard URL не получен - скриншоты дашборда будут пропущены' }
function DashShot([string]$name) {
    if ($DashUrl) { Shot ($DashUrl.TrimEnd('/') + '/#/workloads?namespace=default') $name 20000 }
}

# ---------- 3. Приложение ----------
Log 'Деплой приложения'
K apply -f (Join-Path $P1 'deployment.yaml')
K apply -f (Join-Path $P1 'service.yaml')
K rollout status deployment/scaletestapp --timeout=300s
if ($LASTEXITCODE -ne 0) { Save '02-deploy-error.log' { K describe pods -l app=scaletestapp }; Fail 'Под приложения не поднялся (см. logs\02-deploy-error.log)' }

$svcOut = StartBg 'minikube' "service scaletestapp -p $Prof --url" 'service'
$AppUrl = WaitUrl $svcOut 120
if (-not $AppUrl) { Fail 'Не удалось получить URL сервиса (minikube service --url)' }
Log "URL приложения: $AppUrl"
Save '02-app-check.log' { "GET $AppUrl/"; (Invoke-WebRequest -UseBasicParsing "$AppUrl/").Content; "GET $AppUrl/metrics"; (Invoke-WebRequest -UseBasicParsing "$AppUrl/metrics").Content }

function RunLoad([string]$tag) {
    $csv  = Join-Path $Logs "$tag-locust"
    $html = Join-Path $Logs "$tag-locust-report.html"
    $watch = Join-Path $Logs "$tag-hpa-watch.log"
    Log "Нагрузка locust: $Users пользователей, $Duration ($tag)"
    $largs = "-m locust -f `"$Locustfile`" --headless -u $Users -r $SpawnRate -t $Duration --host $AppUrl --csv `"$csv`" --html `"$html`" --only-summary"
    $lp = Start-Process -FilePath $Py -ArgumentList $largs -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Logs "$tag-locust-stdout.log") -RedirectStandardError (Join-Path $Logs "$tag-locust-stderr.log")
    $i = 0
    while (-not $lp.HasExited) {
        $ts = Get-Date -Format 'HH:mm:ss'
        "===== $ts =====" | Out-File $watch -Append -Encoding utf8
        (K get hpa scaletestapp 2>&1 | Out-String) | Out-File $watch -Append -Encoding utf8
        (K top pods -l app=scaletestapp 2>&1 | Out-String) | Out-File $watch -Append -Encoding utf8
        (K get pods -l app=scaletestapp -o wide 2>&1 | Out-String) | Out-File $watch -Append -Encoding utf8
        if ($i % 9 -eq 4) { DashShot ("{0}-dashboard-load-{1:d2}.png" -f $tag, $i) ; if ($tag -eq 'part2') { PromShots ("{0:d2}" -f $i) } }
        Start-Sleep 10; $i++
    }
    Log 'Нагрузка завершена, ожидание 60 c'
    Start-Sleep 60
    DashShot "$tag-dashboard-after.png"
    Save "$tag-hpa-describe.log" { K get hpa; K describe hpa scaletestapp; K get deploy scaletestapp; K get pods -l app=scaletestapp -o wide }
    Save "$tag-events.log" { K get events --sort-by=.lastTimestamp }
}

# ---------- 4. Часть 1: HPA по памяти ----------
if ($Stage -in 'all','part1') {
    Log 'Часть 1: HPA по памяти'
    K delete hpa scaletestapp --ignore-not-found
    K scale deployment/scaletestapp --replicas=1
    K apply -f (Join-Path $P1 'hpa-memory.yaml')
    Log 'Ожидание метрик metrics-server (до 3 мин)'
    for ($t = 0; $t -lt 180; $t += 10) { K top pods -l app=scaletestapp *> $null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep 10 }
    Start-Sleep 30
    Save 'part1-before.log' { K get hpa; K top pods; K get pods -o wide }
    DashShot 'part1-dashboard-before.png'
    RunLoad 'part1'
}

# ---------- 5. Часть 2: Prometheus + HPA по RPS ----------
$PromUrl = 'http://localhost:9090'
function PromShots([string]$suffix) {
    $q1 = [uri]::EscapeDataString('http_requests_total{service="scaletestapp"}')
    $q2 = [uri]::EscapeDataString('sum by (pod) (rate(http_requests_total{service="scaletestapp"}[1m]))')
    Shot "$PromUrl/graph?g0.expr=$q2&g0.tab=0&g0.range_input=15m" "part2-prometheus-graph-rps-$suffix.png" 20000
}
if ($Stage -in 'all','part2') {
    Log 'Часть 2: установка Prometheus (kube-prometheus-stack)'
    K delete hpa scaletestapp --ignore-not-found
    K scale deployment/scaletestapp --replicas=1
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
    helm repo update
    helm upgrade --install prometheus-operator prometheus-community/kube-prometheus-stack --kube-context $Prof -n monitoring --create-namespace -f (Join-Path $P2 'kube-prometheus-stack-values.yaml') --wait --timeout 20m
    if ($LASTEXITCODE -ne 0) { Save 'part2-prometheus-error.log' { K get pods -n monitoring; K get events -n monitoring --sort-by=.lastTimestamp }; Fail 'Установка kube-prometheus-stack не удалась' }
    K apply -f (Join-Path $P2 'servicemonitor.yaml')

    $pfOut = StartBg 'kubectl' "--context $Prof -n monitoring port-forward svc/prometheus-operator-kube-p-prometheus 9090:9090" 'pf-prometheus'
    Log 'Ожидание, пока Prometheus найдет target scaletestapp (до 4 мин)'
    $ok = $false
    for ($t = 0; $t -lt 240; $t += 10) {
        Start-Sleep 10
        try {
            $r = Invoke-RestMethod "$PromUrl/api/v1/query?query=up%7Bservice%3D%22scaletestapp%22%7D"
            if ($r.data.result.Count -gt 0 -and $r.data.result[0].value[1] -eq '1') { $ok = $true; break }
        } catch {}
    }
    if (-not $ok) { Log 'ВНИМАНИЕ: target scaletestapp не найден в Prometheus' }
    1..30 | ForEach-Object { try { Invoke-WebRequest -UseBasicParsing "$AppUrl/" | Out-Null } catch {} }
    Start-Sleep 30
    Save 'part2-prometheus-targets.log' { (Invoke-WebRequest -UseBasicParsing "$PromUrl/api/v1/targets?state=active").Content }
    Save 'part2-prometheus-query.log' { (Invoke-WebRequest -UseBasicParsing "$PromUrl/api/v1/query?query=http_requests_total").Content }
    Shot "$PromUrl/targets?search=scaletestapp" 'part2-prometheus-targets.png' 20000
    $q = [uri]::EscapeDataString('http_requests_total')
    Shot "$PromUrl/graph?g0.expr=$q&g0.tab=1" 'part2-prometheus-graph-table.png' 20000
    Shot "$PromUrl/graph?g0.expr=$q&g0.tab=0&g0.range_input=15m" 'part2-prometheus-graph.png' 20000

    Log 'Установка Prometheus Adapter'
    helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter --kube-context $Prof -n monitoring -f (Join-Path $P2 'prometheus-adapter-values.yaml') --wait --timeout 10m
    Log 'Ожидание Custom Metrics API (до 5 мин)'
    for ($t = 0; $t -lt 300; $t += 10) {
        K get --raw '/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/*/http_requests_per_second' *> $null
        if ($LASTEXITCODE -eq 0) { break }; Start-Sleep 10
    }
    Save 'part2-custom-metrics.log' { K get apiservice v1beta1.custom.metrics.k8s.io; K get --raw '/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/*/http_requests_per_second' }

    K apply -f (Join-Path $P2 'hpa-rps.yaml')
    Start-Sleep 30
    Save 'part2-before.log' { K get hpa; K describe hpa scaletestapp; K get pods -o wide }
    DashShot 'part2-dashboard-before.png'
    RunLoad 'part2'
    PromShots 'after'
}

StopBg
Log 'Готово. Логи: Task2\logs, скриншоты: Task2\screenshots'
Log "Кластер оставлен запущенным. Остановить: minikube stop -p $Prof, удалить: minikube delete -p $Prof"
Stop-Transcript | Out-Null
