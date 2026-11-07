# Monitor Script
# PowerShell port of the bash monitor (scripts/monitor.sh).

# DTO to print output Messages with metrics 
class StatusDto {
    [int64]$Timestamp
    [double]$Cpu
    [double]$Ram
    [double]$Swap
    [double]$Disk

    StatusDto([int64]$timestamp, [double]$cpu, [double]$ram, [double]$swap, [double]$disk) {
        $this.Timestamp = $timestamp
        $this.Cpu = $cpu
        $this.Ram = $ram
        $this.Swap = $swap
        $this.Disk = $disk
    }
}

# DTO to print table when finish the loop
class TableDto {
    [int64]$Timestamp
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

    TableDto([int64]$timestamp, [double]$minCpu, [double]$minRam, [double]$minSwap, [double]$minDisk, [double]$lastDisk, [double]$avgCpu, [double]$avgRam, [double]$avgSwap, [double]$maxCpu, [double]$maxRam, [double]$maxSwap, [double]$maxDisk) {
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

# DTO to make logs
class AlertDto {
    [string]$Problem
    [int64]$Timestamp

    AlertDto([string]$problem, [int64]$timestamp) {
        $this.Problem = $problem
        $this.Timestamp = $timestamp
    }
}

# Values and arrays
$Interval = 10
$AdminEmail = "santiagokgutierrez@gmail.com"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LogFile = Join-Path (Join-Path $RepoRoot "logs") "monitor.log"
$TemplatePath = Join-Path (Join-Path $RepoRoot "templates") "report_template.html"
$OutputDir = Join-Path (Join-Path $RepoRoot "reports") ""

$script:metricTimestamps = [System.Collections.Generic.List[long]]::new()
$script:metricCpu = [System.Collections.Generic.List[double]]::new()
$script:metricRam = [System.Collections.Generic.List[double]]::new()
$script:metricSwap = [System.Collections.Generic.List[double]]::new()
$script:metricDisk = [System.Collections.Generic.List[double]]::new()

$consecutiveCpuAlerts = 0
$diskAlertPending = 0

# function to make logs
function Log-Message {
    param(
        [string]$Level,
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logDir = Split-Path -Parent $LogFile

    if (-not (Test-Path -Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $LogFile -Value "[$timestamp] [$Level] $Message"
}


# capture cpu
function Get-CPUUsage {
    # top -bn1 | grep 'Cpu(s)' | awk '{print int($2 + $4)}'
    $topOutput = & top -bn1 2>$null | Out-String
    $cpuLine = $null
    foreach ($line in ($topOutput -split "`n")) {
        if ($line -match 'Cpu') {
            $cpuLine = $line.Trim()
            break
        }
    }
    if ($null -ne $cpuLine) {
        $tokens = @($cpuLine -split '\s+' | Where-Object { $_ })
        if ($tokens.Count -ge 4) {
            return [int]([double]$tokens[1] + [double]$tokens[3])
        }
    }
    return 0
}

# capture ram
function Get-MemUsage {
    # free | grep Mem | awk '{print int($3/$2 * 100.0)}'
    $freeOutput = & free | Out-String
    $memLine = $null
    foreach ($line in ($freeOutput -split "`n")) {
        if ($line -match '^Mem:') {
            $memLine = $line
            break
        }
    }
    if ($null -ne $memLine) {
        $fields = @($memLine -split '\s+' | Where-Object { $_ })
        if ($fields.Count -ge 3) {
            $total = [double]$fields[1]
            $used = [double]$fields[2]
            if ($total -gt 0) {
                return [int]($used / $total * 100.0)
            }
        }
    }
    return 0
}

# capture swap
function Get-SwapUsage {
    # free | grep Swap | awk '{if ($2 > 0) print int($3/$2 * 100.0); else print 0}'
    $freeOutput = & free | Out-String
    $swapLine = $null
    foreach ($line in ($freeOutput -split "`n")) {
        if ($line -match '^Swap:') {
            $swapLine = $line
            break
        }
    }
    if ($null -ne $swapLine) {
        $fields = @($swapLine -split '\s+' | Where-Object { $_ })
        if ($fields.Count -ge 3) {
            $total = [double]$fields[1]
            $used = [double]$fields[2]
            if ($total -gt 0) {
                return [int]($used / $total * 100.0)
            }
        }
    }
    return 0
}

# capture disk
function Get-DiskUsage {
    # df / | grep / | awk '{print int($5)}'
    $dfOutput = & df / | Out-String
    $diskLine = $null
    foreach ($line in ($dfOutput -split "`n")) {
        if ($line -match '/') {
            $diskLine = $line
            break
        }
    }
    if ($null -ne $diskLine) {
        $fields = @($diskLine -split '\s+' | Where-Object { $_ })
        if ($fields.Count -ge 5) {
            return [int]([double]$fields[4])
        }
    }
    return 0
}

# function to list five most ram expensive process 
function Get-TopRamProcesses {
    # ps aux | awk 'NR > 1 { printf "%-10s %5s%% %s\n", $1, $4, $11 }' | head -5
    $psOutput = & ps aux | Out-String
    $processLines = @()
    $lineNumber = 0
    foreach ($line in ($psOutput -split "`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }
        $lineNumber++
        if ($lineNumber -le 1) {
            continue
        }
        if ($processLines.Count -ge 5) {
            break
        }
        $fields = @($trimmed -split '\s+' | Where-Object { $_ })
        if ($fields.Count -ge 11) {
            $processLines += ("{0,-10} {1,5}% {2}" -f $fields[0], $fields[3], $fields[10])
        }
    }
    foreach ($processLine in $processLines) {
        Write-Output $processLine
    }
}

# create status dto 
function New-StatusDto {
    param(
        [int64]$Timestamp,
        [double]$Cpu,
        [double]$Ram,
        [double]$Swap,
        [double]$Disk
    )
    return [StatusDto]::new($Timestamp, $Cpu, $Ram, $Swap, $Disk)
}

# create table dto
function New-TableDto {
    param(
        [int64]$Timestamp,
        [double]$MinCpu,
        [double]$MinRam,
        [double]$MinSwap,
        [double]$MinDisk,
        [double]$LastDisk,
        [double]$AvgCpu,
        [double]$AvgRam,
        [double]$AvgSwap,
        [double]$MaxCpu,
        [double]$MaxRam,
        [double]$MaxSwap,
        [double]$MaxDisk
    )
    return [TableDto]::new(
        $Timestamp,
        $MinCpu,
        $MinRam,
        $MinSwap,
        $MinDisk,
        $LastDisk,
        $AvgCpu,
        $AvgRam,
        $AvgSwap,
        $MaxCpu,
        $MaxRam,
        $MaxSwap,
        $MaxDisk
    )
}

# Auxiliar function to create alerts - logs
function New-AlertDto {
    param(
        [string]$Problem,
        [int64]$Timestamp
    )
    return [AlertDto]::new($Problem, $Timestamp)
}

# create alerts 
function Send-Alert {
    param(
        [string]$Problem,
        [int64]$Timestamp
    )
    $alertDto = New-AlertDto -Problem $Problem -Timestamp $Timestamp
    Log-Message -Level "WARNING" -Message $alertDto.Problem
    Write-Output "Warning: $($alertDto.Problem)"
    Write-Output "Date: $($alertDto.Timestamp)"
}

# send mails
function Send-Mail {
    param(
        [string]$Problem
    )
    $subject = "Alerta monitor - $Problem"
    try {
        Send-MailMessage -Subject $subject -Body $Problem -From "monitor@example.com" -To $AdminEmail -SmtpServer "localhost"
    } catch {
        Log-Message -Level "ERROR" -Message "Failed to send mail: $($_.Exception.Message)"
    }
}

# alert business logic 
function Invoke-AlertChecks {
    param(
        [double]$Cpu,
        [double]$Mem,
        [double]$Disk
    )

    if ($Cpu -ge 80) {
        $script:consecutiveCpuAlerts = $script:consecutiveCpuAlerts + 1
    } else {
        $script:consecutiveCpuAlerts = 0
    }

    if ($script:consecutiveCpuAlerts -ge 3) {
        $problem = "CPU insufficiency: consumo de CPU en $Cpu%"
        Send-Alert -Problem $problem -Timestamp ([DateTimeOffset]::Now.ToUnixTimeSeconds())
        Send-Mail -Problem $problem
    }

    if (((100 - $Disk) -lt 15 -and $script:diskAlertPending -eq 0)) {
        $script:diskAlertPending = 1
        $remaining = 100 - $Disk
        $problem = "Disk insufficiency: espacio restante $remaining%"
        Send-Alert -Problem $problem -Timestamp ([DateTimeOffset]::Now.ToUnixTimeSeconds())
        $answer = Read-Host "¿Desea eliminar archivos temporales? (s/n)"
        if ($answer -eq "s" -or $answer -eq "S") {
            Remove-Item -Path "/tmp/*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (((100 - $Mem) -lt 10)) {
        $remainingRam = 100 - $Mem
        $problem = "RAM insufficiency: espacio restante de RAM en $remainingRam%"
        Send-Alert -Problem $problem -Timestamp ([DateTimeOffset]::Now.ToUnixTimeSeconds())
        Get-TopRamProcesses
    }
}

# Auxiliar function to capture metrics 
function Invoke-MetricsCapture {
    param(
        [int64]$Timestamp
    )

    $cpu = Get-CPUUsage
    $mem = Get-MemUsage
    $swap = Get-SwapUsage
    $disk = Get-DiskUsage

    $script:metricTimestamps.Add($Timestamp)
    $script:metricCpu.Add($cpu)
    $script:metricRam.Add($mem)
    $script:metricSwap.Add($swap)
    $script:metricDisk.Add($disk)

    $statusDto = New-StatusDto -Timestamp $Timestamp -Cpu $cpu -Ram $mem -Swap $swap -Disk $disk

    Write-Output "CPU: $($statusDto.Cpu)% | Mem: $($statusDto.Ram)% | Swap: $($statusDto.Swap)% | Disk: $($statusDto.Disk)%"

    Invoke-AlertChecks -Cpu $cpu -Mem $mem -Disk $disk
}

# businesss logic to make stadistics(avg, max and min) cpu, mem, swap and disk
function Get-Statistics {
    $cpuCount = $script:metricCpu.Count
    if ($cpuCount -gt 0) {
        $cpuMin = $script:metricCpu[0]
        $cpuMax = $script:metricCpu[0]
        $cpuSum = 0.0
        for ($i = 0; $i -lt $cpuCount; $i++) {
            if ($script:metricCpu[$i] -lt $cpuMin) {
                $cpuMin = $script:metricCpu[$i]
            }
            if ($script:metricCpu[$i] -gt $cpuMax) {
                $cpuMax = $script:metricCpu[$i]
            }
            $cpuSum += $script:metricCpu[$i]
        }
        $cpuAvg = [int]($cpuSum / $cpuCount)
    } else {
        $cpuMin = 0.0
        $cpuMax = 0.0
        $cpuAvg = 0.0
    }

    $memCount = $script:metricRam.Count
    if ($memCount -gt 0) {
        $memMin = $script:metricRam[0]
        $memMax = $script:metricRam[0]
        $memSum = 0.0
        for ($i = 0; $i -lt $memCount; $i++) {
            if ($script:metricRam[$i] -lt $memMin) {
                $memMin = $script:metricRam[$i]
            }
            if ($script:metricRam[$i] -gt $memMax) {
                $memMax = $script:metricRam[$i]
            }
            $memSum += $script:metricRam[$i]
        }
        $memAvg = [int]($memSum / $memCount)
    } else {
        $memMin = 0.0
        $memMax = 0.0
        $memAvg = 0.0
    }

    $swapCount = $script:metricSwap.Count
    if ($swapCount -gt 0) {
        $swapMin = $script:metricSwap[0]
        $swapMax = $script:metricSwap[0]
        $swapSum = 0.0
        for ($i = 0; $i -lt $swapCount; $i++) {
            if ($script:metricSwap[$i] -lt $swapMin) {
                $swapMin = $script:metricSwap[$i]
            }
            if ($script:metricSwap[$i] -gt $swapMax) {
                $swapMax = $script:metricSwap[$i]
            }
            $swapSum += $script:metricSwap[$i]
        }
        $swapAvg = [int]($swapSum / $swapCount)
    } else {
        $swapMin = 0.0
        $swapMax = 0.0
        $swapAvg = 0.0
    }

    $diskCount = $script:metricDisk.Count
    if ($diskCount -gt 0) {
        $diskLast = $script:metricDisk[$diskCount - 1]
        $diskMin = $diskLast
        $diskMax = $diskLast
    } else {
        $diskLast = 0.0
        $diskMin = 0.0
        $diskMax = 0.0
    }

    return @{
        Timestamp = [DateTimeOffset]::Now.ToUnixTimeSeconds()
        MinCpu = $cpuMin
        MinRam = $memMin
        MinSwap = $swapMin
        MinDisk = $diskMin
        LastDisk = $diskLast
        AvgCpu = $cpuAvg
        AvgRam = $memAvg
        AvgSwap = $swapAvg
        MaxCpu = $cpuMax
        MaxRam = $memMax
        MaxSwap = $swapMax
        MaxDisk = $diskMax
    }
}

# Create html page to view statics
function New-HtmlReport {
    param(
        [hashtable]$Statistics
    )

    $reportTitle = Read-Host "Report title"
    $reportDescription = Read-Host "Report description"
    $generatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $metricsRows = ""
    for ($i = 0; $i -lt $script:metricTimestamps.Count; $i++) {
        $ts = $script:metricTimestamps[$i]
        $c = $script:metricCpu[$i]
        $r = $script:metricRam[$i]
        $s = $script:metricSwap[$i]
        $d = $script:metricDisk[$i]
        $metricsRows += "<tr>`n            <td>$ts</td>`n            <td>$c%</td>`n            <td>$r%</td>`n            <td>$s%</td>`n            <td>$d%</td>`n        </tr>`n"
    }

    $html = Get-Content -Raw -Path $TemplatePath
    $html = $html.Replace('${REPORT_TITLE}', $reportTitle)
    $html = $html.Replace('${REPORT_DESCRIPTION}', $reportDescription)
    $html = $html.Replace('${GENERATED_AT}', $generatedAt)
    $html = $html.Replace('${CPU_MIN}', ([string]$Statistics.MinCpu))
    $html = $html.Replace('${CPU_MAX}', ([string]$Statistics.MaxCpu))
    $html = $html.Replace('${CPU_AVG}', ([string]$Statistics.AvgCpu))
    $html = $html.Replace('${MEM_MIN}', ([string]$Statistics.MinRam))
    $html = $html.Replace('${MEM_MAX}', ([string]$Statistics.MaxRam))
    $html = $html.Replace('${MEM_AVG}', ([string]$Statistics.AvgRam))
    $html = $html.Replace('${SWAP_MIN}', ([string]$Statistics.MinSwap))
    $html = $html.Replace('${SWAP_MAX}', ([string]$Statistics.MaxSwap))
    $html = $html.Replace('${SWAP_AVG}', ([string]$Statistics.AvgSwap))
    $html = $html.Replace('${DISK_MIN}', ([string]$Statistics.MinDisk))
    $html = $html.Replace('${DISK_MAX}', ([string]$Statistics.MaxDisk))
    $html = $html.Replace('${DISK_LAST}', ([string]$Statistics.LastDisk))
    $html = $html.Replace('${METRICS_ROWS}', $metricsRows)

    if (-not (Test-Path -Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $outputFile = Join-Path $OutputDir ("report_{0}.html" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    Set-Content -Path $outputFile -Value $html -Encoding utf8
    Write-Output "HTML report generated: $outputFile"
}

# Read timer from user (in minutes)
Write-Host "Introducir tiempo limite(minutos)"
$timer = [int](Read-Host)
$timerInSeconds = $timer * 60

$startTime = [DateTimeOffset]::Now.ToUnixTimeSeconds()
$endTime = $startTime + $timerInSeconds

while ([DateTimeOffset]::Now.ToUnixTimeSeconds() -lt $endTime) {
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    Invoke-MetricsCapture -Timestamp $now
    Start-Sleep -Seconds $Interval
}

$statistics = Get-Statistics

$tableDto = New-TableDto -Timestamp $statistics.Timestamp -MinCpu $statistics.MinCpu -MinRam $statistics.MinRam -MinSwap $statistics.MinSwap -MinDisk $statistics.MinDisk -LastDisk $statistics.LastDisk -AvgCpu $statistics.AvgCpu -AvgRam $statistics.AvgRam -AvgSwap $statistics.AvgSwap -MaxCpu $statistics.MaxCpu -MaxRam $statistics.MaxRam -MaxSwap $statistics.MaxSwap -MaxDisk $statistics.MaxDisk

Write-Output "=== Statistics ==="
Write-Output "CPU - Min: $($tableDto.MinCpu)% | Max: $($tableDto.MaxCpu)% | Avg: $($tableDto.AvgCpu)%"
Write-Output "Mem - Min: $($tableDto.MinRam)% | Max: $($tableDto.MaxRam)% | Avg: $($tableDto.AvgRam)%"
Write-Output "Swap - Min: $($tableDto.MinSwap)% | Max: $($tableDto.MaxSwap)% | Avg: $($tableDto.AvgSwap)%"
Write-Output "Disk - Last: $($tableDto.LastDisk)%"

New-HtmlReport -Statistics $statistics
