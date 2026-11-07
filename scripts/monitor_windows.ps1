#requires -Version 5.1
<#
    Windows System Monitor
    Native PowerShell implementation.

    Expected layout:
        project/
        ├── scripts/
        │   └── monitor.ps1
        ├── logs/
        └── reports/

    Metrics are collected through CIM and native PowerShell cmdlets.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# DTOs
# ---------------------------------------------------------------------------

class StatusDto {
    [long]$Timestamp
    [double]$Cpu
    [double]$Ram
    [double]$Swap
    [double]$Disk

    StatusDto([long]$timestamp, [double]$cpu, [double]$ram, [double]$swap, [double]$disk) {
        $this.Timestamp = $timestamp
        $this.Cpu = $cpu
        $this.Ram = $ram
        $this.Swap = $swap
        $this.Disk = $disk
    }
}

class TableDto {
    [long]$Timestamp
    [double]$MinCpu
    [double]$MinRam
    [double]$MinSwap
    [double]$MinDisk
    [double]$LastDisk
    [double]$AvgCpu
    [double]$AvgRam
    [double]$AvgSwap
    [double]$MaxCpu
    [double]$MaxRam
    [double]$MaxSwap
    [double]$MaxDisk

    TableDto(
        [long]$timestamp,
        [double]$minCpu, [double]$minRam, [double]$minSwap, [double]$minDisk,
        [double]$lastDisk,
        [double]$avgCpu, [double]$avgRam, [double]$avgSwap,
        [double]$maxCpu, [double]$maxRam, [double]$maxSwap, [double]$maxDisk
    ) {
        $this.Timestamp = $timestamp
        $this.MinCpu = $minCpu
        $this.MinRam = $minRam
        $this.MinSwap = $minSwap
        $this.MinDisk = $minDisk
        $this.LastDisk = $lastDisk
        $this.AvgCpu = $avgCpu
        $this.AvgRam = $avgRam
        $this.AvgSwap = $avgSwap
        $this.MaxCpu = $maxCpu
        $this.MaxRam = $maxRam
        $this.MaxSwap = $maxSwap
        $this.MaxDisk = $maxDisk
    }
}

class AlertDto {
    [string]$Problem
    [long]$Timestamp

    AlertDto([string]$problem, [long]$timestamp) {
        $this.Problem = $problem
        $this.Timestamp = $timestamp
    }
}

# ---------------------------------------------------------------------------
# Configuration and state
# ---------------------------------------------------------------------------

$script:IntervalSeconds = 10
$script:CpuAlertThreshold = 80
$script:DiskFreeThreshold = 15
$script:RamFreeThreshold = 10
$script:AdminEmail = "santiagokgutierrez@gmail.com"

# Configure this environment variable if SMTP notifications are required:
# $env:MONITOR_SMTP_SERVER = "smtp.example.com"
$script:SmtpServer = $env:MONITOR_SMTP_SERVER

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:LogDir = Join-Path $script:RepoRoot "logs"
$script:ReportDir = Join-Path $script:RepoRoot "reports"
$script:LogFile = Join-Path $script:LogDir "monitor-ps.log"

$script:MetricSamples = [System.Collections.Generic.List[object]]::new()
$script:ConsecutiveCpuAlerts = 0
$script:CpuAlertAlreadySent = $false
$script:DiskAlertPending = $false

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-MonitorLog {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("INFO", "WARNING", "ERROR", "DEBUG")]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $script:LogFile `
        -Value "[$timestamp] [$Level] $Message" `
        -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Metric collection - Windows native commands / CIM
# ---------------------------------------------------------------------------

function Get-CpuUsage {
    # Win32_Processor.LoadPercentage is supplied by Windows through CIM.
    $processors = @(Get-CimInstance -ClassName Win32_Processor)
    if ($processors.Count -eq 0) {
        throw "Windows did not return processor information."
    }

    $values = @($processors | ForEach-Object { [double]$_.LoadPercentage })
    return [math]::Round(($values | Measure-Object -Average).Average, 0)
}

function Get-MemoryUsage {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem

    $totalKb = [double]$os.TotalVisibleMemorySize
    $freeKb = [double]$os.FreePhysicalMemory

    if ($totalKb -le 0) {
        throw "Unable to determine the total physical memory."
    }

    $usedPercent = (($totalKb - $freeKb) / $totalKb) * 100
    return [math]::Round($usedPercent, 0)
}

function Get-SwapUsage {
    # Win32_PageFileUsage reports page-file allocation and current usage in MB.
    $pageFiles = @(Get-CimInstance -ClassName Win32_PageFileUsage)

    if ($pageFiles.Count -eq 0) {
        return 0
    }

    $totalMb = [double](($pageFiles | Measure-Object -Property AllocatedBaseSize -Sum).Sum)
    $usedMb = [double](($pageFiles | Measure-Object -Property CurrentUsage -Sum).Sum)

    if ($totalMb -le 0) {
        return 0
    }

    return [math]::Round(($usedMb / $totalMb) * 100, 0)
}

function Get-SystemDiskUsage {
    $systemDrive = $env:SystemDrive

    $volume = Get-Volume -DriveLetter $systemDrive.TrimEnd(":") -ErrorAction Stop
    if ($null -eq $volume -or [double]$volume.Size -le 0) {
        throw "Unable to determine disk capacity for $systemDrive."
    }

    $usedPercent = (($volume.Size - $volume.SizeRemaining) / $volume.Size) * 100
    return [math]::Round($usedPercent, 0)
}

function Get-TopRamProcesses {
    Get-Process |
        Sort-Object -Property WorkingSet64 -Descending |
        Select-Object -First 5 `
            @{Name = "Process"; Expression = { $_.ProcessName } },
            Id,
            @{Name = "MemoryMB"; Expression = { [math]::Round($_.WorkingSet64 / 1MB, 1) } } |
        Format-Table -AutoSize |
        Out-String |
        Write-Host
}

# ---------------------------------------------------------------------------
# DTO factories and alerts
# ---------------------------------------------------------------------------

function New-StatusDto {
    param(
        [long]$Timestamp,
        [double]$Cpu,
        [double]$Ram,
        [double]$Swap,
        [double]$Disk
    )

    return [StatusDto]::new($Timestamp, $Cpu, $Ram, $Swap, $Disk)
}

function New-AlertDto {
    param(
        [string]$Problem,
        [long]$Timestamp
    )

    return [AlertDto]::new($Problem, $Timestamp)
}

function Send-Alert {
    param([Parameter(Mandatory)][string]$Problem)

    $alert = New-AlertDto -Problem $Problem -Timestamp ([DateTimeOffset]::Now.ToUnixTimeSeconds())
    Write-MonitorLog -Level "WARNING" -Message $alert.Problem

    Write-Host "Warning: $($alert.Problem)" -ForegroundColor Yellow
    Write-Host "Date: $([DateTimeOffset]::FromUnixTimeSeconds($alert.Timestamp).ToLocalTime())"
}

function Send-AlertMail {
    param([Parameter(Mandatory)][string]$Problem)

    if ([string]::IsNullOrWhiteSpace($script:SmtpServer)) {
        Write-MonitorLog -Level "INFO" -Message "Email notification skipped: MONITOR_SMTP_SERVER is not configured."
        return
    }

    try {
        $subject = "Alerta monitor - $Problem"
        Send-MailMessage -SmtpServer $script:SmtpServer `
            -From "monitor@example.com" `
            -To $script:AdminEmail `
            -Subject $subject `
            -Body $Problem `
            -ErrorAction Stop

        Write-MonitorLog -Level "INFO" -Message "Alert email sent to $script:AdminEmail."
    }
    catch {
        Write-MonitorLog -Level "ERROR" -Message "Failed to send alert email: $($_.Exception.Message)"
    }
}

function Clear-UserTemporaryFiles {
    $tempPath = $env:TEMP

    if ([string]::IsNullOrWhiteSpace($tempPath) -or -not (Test-Path -LiteralPath $tempPath)) {
        Write-MonitorLog -Level "ERROR" -Message "The user TEMP directory does not exist; cleanup skipped."
        return
    }

    try {
        # Remove contents of the current user's TEMP directory, not the directory itself.
        Get-ChildItem -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        Write-MonitorLog -Level "INFO" -Message "Temporary-file cleanup requested for $tempPath."
        Write-Host "Se intentó limpiar el directorio temporal: $tempPath"
    }
    catch {
        Write-MonitorLog -Level "ERROR" -Message "Temporary-file cleanup failed: $($_.Exception.Message)"
    }
}

function Invoke-AlertChecks {
    param(
        [double]$Cpu,
        [double]$Ram,
        [double]$Disk
    )

    # CPU: alert once after three consecutive samples above the threshold.
    if ($Cpu -gt $script:CpuAlertThreshold) {
        $script:ConsecutiveCpuAlerts++
    }
    else {
        $script:ConsecutiveCpuAlerts = 0
        $script:CpuAlertAlreadySent = $false
    }

    if ($script:ConsecutiveCpuAlerts -ge 3 -and -not $script:CpuAlertAlreadySent) {
        $problem = "CPU insufficiency: consumo de CPU en $Cpu%"
        Send-Alert -Problem $problem
        Send-AlertMail -Problem $problem
        $script:CpuAlertAlreadySent = $true
    }

    # Disk metric represents percentage used; alert when free space is below 15%.
    $diskFree = 100 - $Disk
    if ($diskFree -lt $script:DiskFreeThreshold -and -not $script:DiskAlertPending) {
        $script:DiskAlertPending = $true
        Send-Alert -Problem "Disk insufficiency: espacio restante $diskFree%"

        $answer = Read-Host "¿Desea eliminar archivos temporales del usuario? (s/n)"
        if ($answer -match '^(s|S)$') {
            Clear-UserTemporaryFiles
        }
    }
    elseif ($diskFree -ge $script:DiskFreeThreshold) {
        $script:DiskAlertPending = $false
    }

    # RAM metric represents percentage used; alert when free RAM is below 10%.
    $ramFree = 100 - $Ram
    if ($ramFree -lt $script:RamFreeThreshold) {
        Send-Alert -Problem "RAM insufficiency: espacio restante de RAM en $ramFree%"
        Get-TopRamProcesses
    }
}

# ---------------------------------------------------------------------------
# Capture and statistics
# ---------------------------------------------------------------------------

function Invoke-MetricsCapture {
    $timestamp = [DateTimeOffset]::Now.ToUnixTimeSeconds()

    $cpu = Get-CpuUsage
    $ram = Get-MemoryUsage
    $swap = Get-SwapUsage
    $disk = Get-SystemDiskUsage

    $status = New-StatusDto -Timestamp $timestamp -Cpu $cpu -Ram $ram -Swap $swap -Disk $disk
    $script:MetricSamples.Add($status)

    $sampleDate = [DateTimeOffset]::FromUnixTimeSeconds($timestamp).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host ("[{0}] CPU: {1}% | RAM: {2}% | Swap: {3}% | Disk: {4}%" -f `
        $sampleDate, $status.Cpu, $status.Ram, $status.Swap, $status.Disk)

    Write-MonitorLog -Level "INFO" -Message `
        ("CPU={0}% RAM={1}% Swap={2}% Disk={3}%" -f $cpu, $ram, $swap, $disk)

    Invoke-AlertChecks -Cpu $cpu -Ram $ram -Disk $disk
}

function Get-Statistics {
    if ($script:MetricSamples.Count -eq 0) {
        return @{
            Timestamp = [DateTimeOffset]::Now.ToUnixTimeSeconds()
            MinCpu = 0; MaxCpu = 0; AvgCpu = 0
            MinRam = 0; MaxRam = 0; AvgRam = 0
            MinSwap = 0; MaxSwap = 0; AvgSwap = 0
            MinDisk = 0; MaxDisk = 0; LastDisk = 0
        }
    }

    $cpu = @($script:MetricSamples | ForEach-Object { $_.Cpu })
    $ram = @($script:MetricSamples | ForEach-Object { $_.Ram })
    $swap = @($script:MetricSamples | ForEach-Object { $_.Swap })
    $disk = @($script:MetricSamples | ForEach-Object { $_.Disk })

    return @{
        Timestamp = [DateTimeOffset]::Now.ToUnixTimeSeconds()
        MinCpu = ($cpu | Measure-Object -Minimum).Minimum
        MaxCpu = ($cpu | Measure-Object -Maximum).Maximum
        AvgCpu = [math]::Round(($cpu | Measure-Object -Average).Average, 0)
        MinRam = ($ram | Measure-Object -Minimum).Minimum
        MaxRam = ($ram | Measure-Object -Maximum).Maximum
        AvgRam = [math]::Round(($ram | Measure-Object -Average).Average, 0)
        MinSwap = ($swap | Measure-Object -Minimum).Minimum
        MaxSwap = ($swap | Measure-Object -Maximum).Maximum
        AvgSwap = [math]::Round(($swap | Measure-Object -Average).Average, 0)
        MinDisk = ($disk | Measure-Object -Minimum).Minimum
        MaxDisk = ($disk | Measure-Object -Maximum).Maximum
        LastDisk = $disk[-1]
    }
}

function New-TableDto {
    param([hashtable]$Statistics)

    return [TableDto]::new(
        $Statistics.Timestamp,
        $Statistics.MinCpu, $Statistics.MinRam, $Statistics.MinSwap, $Statistics.MinDisk,
        $Statistics.LastDisk,
        $Statistics.AvgCpu, $Statistics.AvgRam, $Statistics.AvgSwap,
        $Statistics.MaxCpu, $Statistics.MaxRam, $Statistics.MaxSwap, $Statistics.MaxDisk
    )
}

# ---------------------------------------------------------------------------
# HTML report
# ---------------------------------------------------------------------------

function ConvertTo-HtmlText {
    param([AllowEmptyString()][string]$Value)
    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function New-HtmlReport {
    param([Parameter(Mandatory)][hashtable]$Statistics)

    $reportTitle = Read-Host "Report title"
    $reportDescription = Read-Host "Report description"
    $generatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $rows = foreach ($sample in $script:MetricSamples) {
        $date = [DateTimeOffset]::FromUnixTimeSeconds($sample.Timestamp).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
        "<tr><td>$(ConvertTo-HtmlText $date)</td><td>$($sample.Cpu)%</td><td>$($sample.Ram)%</td><td>$($sample.Swap)%</td><td>$($sample.Disk)%</td></tr>"
    }
    $metricsRows = $rows -join "`r`n"

    if ([string]::IsNullOrWhiteSpace($metricsRows)) {
        $metricsRows = '<tr><td colspan="5">No se registraron mediciones.</td></tr>'
    }

    # Self-contained template: no external template engine or module is required.
    $html = @'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${REPORT_TITLE}</title>
<style>
    body { font-family: Segoe UI, Arial, sans-serif; background:#f4f6f9; color:#263445; margin:0; padding:30px; }
    .container { max-width:1100px; margin:auto; }
    header, section { background:#fff; padding:24px; margin-bottom:20px; border-radius:10px; box-shadow:0 2px 8px rgba(0,0,0,.05); }
    h1,h2 { color:#263445; }
    .metadata { color:#667085; font-size:14px; }
    .statistics { display:grid; grid-template-columns:repeat(auto-fit,minmax(190px,1fr)); gap:14px; }
    .stat-card { background:#eef2f7; padding:16px; border-radius:8px; }
    .stat-card h3 { margin-top:0; }
    table { width:100%; border-collapse:collapse; margin-top:15px; }
    th,td { padding:12px; text-align:center; border-bottom:1px solid #ddd; }
    th { background:#263445; color:#fff; }
    tr:nth-child(even) { background:#f2f2f2; }
    footer { text-align:center; color:#777; padding:20px; }
</style>
</head>
<body>
<div class="container">
<header>
    <h1>${REPORT_TITLE}</h1>
    <p class="metadata">Fecha de generación: ${GENERATED_AT}</p>
    <p>${REPORT_DESCRIPTION}</p>
</header>
<section>
    <h2>Resumen de estadísticas</h2>
    <div class="statistics">
        <div class="stat-card"><h3>CPU</h3><p>Mínimo: ${CPU_MIN}%</p><p>Máximo: ${CPU_MAX}%</p><p>Promedio: ${CPU_AVG}%</p></div>
        <div class="stat-card"><h3>Memoria RAM</h3><p>Mínimo: ${MEM_MIN}%</p><p>Máximo: ${MEM_MAX}%</p><p>Promedio: ${MEM_AVG}%</p></div>
        <div class="stat-card"><h3>Swap</h3><p>Mínimo: ${SWAP_MIN}%</p><p>Máximo: ${SWAP_MAX}%</p><p>Promedio: ${SWAP_AVG}%</p></div>
        <div class="stat-card"><h3>Disco (unidad del sistema)</h3><p>Mínimo: ${DISK_MIN}%</p><p>Máximo: ${DISK_MAX}%</p><p>Última medición: ${DISK_LAST}%</p></div>
    </div>
</section>
<section>
    <h2>Historial de mediciones</h2>
    <table>
        <thead><tr><th>Fecha</th><th>CPU</th><th>RAM</th><th>Swap</th><th>Disco</th></tr></thead>
        <tbody>${METRICS_ROWS}</tbody>
    </table>
</section>
<footer><p>System Monitoring Report</p><p>Generated automatically by PowerShell Monitor</p></footer>
</div>
</body>
</html>
'@

    $replacements = @{
        '${REPORT_TITLE}' = ConvertTo-HtmlText $reportTitle
        '${REPORT_DESCRIPTION}' = ConvertTo-HtmlText $reportDescription
        '${GENERATED_AT}' = ConvertTo-HtmlText $generatedAt
        '${CPU_MIN}' = [string]$Statistics.MinCpu
        '${CPU_MAX}' = [string]$Statistics.MaxCpu
        '${CPU_AVG}' = [string]$Statistics.AvgCpu
        '${MEM_MIN}' = [string]$Statistics.MinRam
        '${MEM_MAX}' = [string]$Statistics.MaxRam
        '${MEM_AVG}' = [string]$Statistics.AvgRam
        '${SWAP_MIN}' = [string]$Statistics.MinSwap
        '${SWAP_MAX}' = [string]$Statistics.MaxSwap
        '${SWAP_AVG}' = [string]$Statistics.AvgSwap
        '${DISK_MIN}' = [string]$Statistics.MinDisk
        '${DISK_MAX}' = [string]$Statistics.MaxDisk
        '${DISK_LAST}' = [string]$Statistics.LastDisk
        '${METRICS_ROWS}' = $metricsRows
    }

    foreach ($key in $replacements.Keys) {
        $html = $html.Replace($key, [string]$replacements[$key])
    }

    if (-not (Test-Path -LiteralPath $script:ReportDir)) {
        New-Item -ItemType Directory -Path $script:ReportDir -Force | Out-Null
    }

    $outputFile = Join-Path $script:ReportDir ("report_{0}.html" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    Set-Content -LiteralPath $outputFile -Value $html -Encoding UTF8

    Write-Host "HTML report generated: $outputFile" -ForegroundColor Green
    Write-MonitorLog -Level "INFO" -Message "HTML report generated: $outputFile"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    $timerInput = Read-Host "Introducir tiempo limite (minutos)"
    $timerMinutes = 0

    if (-not [int]::TryParse($timerInput, [ref]$timerMinutes) -or $timerMinutes -le 0) {
        throw "El tiempo debe ser un número entero mayor que cero."
    }

    $duration = [TimeSpan]::FromMinutes($timerMinutes)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-MonitorLog -Level "INFO" -Message "Monitor started. Duration: $timerMinutes minute(s)."
    Write-Host "Monitor iniciado. Intervalo: $script:IntervalSeconds segundos." -ForegroundColor Cyan

    while ($stopwatch.Elapsed -lt $duration) {
        Invoke-MetricsCapture

        $remaining = $duration - $stopwatch.Elapsed
        if ($remaining.TotalSeconds -le 0) {
            break
        }

        $sleepSeconds = [math]::Min($script:IntervalSeconds, [math]::Ceiling($remaining.TotalSeconds))
        Start-Sleep -Seconds ([int]$sleepSeconds)
    }

    $stopwatch.Stop()

    $statistics = Get-Statistics
    $tableDto = New-TableDto -Statistics $statistics

    Write-Host "`n=== Statistics ===" -ForegroundColor Cyan
    Write-Host "CPU  - Min: $($tableDto.MinCpu)% | Max: $($tableDto.MaxCpu)% | Avg: $($tableDto.AvgCpu)%"
    Write-Host "RAM  - Min: $($tableDto.MinRam)% | Max: $($tableDto.MaxRam)% | Avg: $($tableDto.AvgRam)%"
    Write-Host "Swap - Min: $($tableDto.MinSwap)% | Max: $($tableDto.MaxSwap)% | Avg: $($tableDto.AvgSwap)%"
    Write-Host "Disk - Min: $($tableDto.MinDisk)% | Max: $($tableDto.MaxDisk)% | Last: $($tableDto.LastDisk)%"

    New-HtmlReport -Statistics $statistics

    Write-MonitorLog -Level "INFO" -Message "Monitor finished. Samples collected: $($script:MetricSamples.Count)."
}
catch {
    Write-Error $_
    try {
        Write-MonitorLog -Level "ERROR" -Message $_.Exception.Message
    }
    catch {
        # Logging itself must not hide the original failure.
    }
    exit 1
}
