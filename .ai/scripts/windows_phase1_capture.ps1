[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$Scenario,

    [string]$OutputDirectory = '.ai\evidence\phase1\windows'
)

$ErrorActionPreference = 'Stop'

function Get-DnsSummary {
    param([Parameter(Mandatory = $true)][string]$Name)

    try {
        $records = @(Resolve-DnsName -Name $Name -DnsOnly -NoHostsFile -ErrorAction Stop)
        $types = @($records | Group-Object -Property Type | ForEach-Object {
            [ordered]@{
                type = [string]$_.Name
                count = [int]$_.Count
            }
        })
        return [ordered]@{
            name = $Name
            success = $true
            recordTypes = $types
        }
    }
    catch {
        return [ordered]@{
            name = $Name
            success = $false
            errorType = $_.Exception.GetType().Name
        }
    }
}

function Get-HttpSummary {
    param([Parameter(Mandatory = $true)][string]$Url)

    try {
        $format = '%{http_code},%{time_namelookup},%{time_connect},%{time_appconnect},%{time_total}'
        $raw = & curl.exe -sS -o NUL --http1.1 --connect-timeout 10 --max-time 20 -w $format $Url
        if ($LASTEXITCODE -ne 0) {
            throw "curl exited with $LASTEXITCODE"
        }
        $parts = [string]$raw -split ','
        return [ordered]@{
            url = $Url
            success = $true
            httpStatus = $parts[0]
            dnsSeconds = $parts[1]
            connectSeconds = $parts[2]
            tlsSeconds = $parts[3]
            totalSeconds = $parts[4]
        }
    }
    catch {
        return [ordered]@{
            url = $Url
            success = $false
            errorType = $_.Exception.GetType().Name
        }
    }
}

function Get-ProcessSummary {
    param([Parameter(Mandatory = $true)][string]$Name)

    $processes = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
        return [ordered]@{
            name = $Name
            running = $false
        }
    }

    return [ordered]@{
        name = $Name
        running = $true
        count = $processes.Count
        cpuSecondsTotal = [math]::Round(($processes | Measure-Object -Property CPU -Sum).Sum, 3)
        workingSetMiBTotal = [math]::Round((($processes | Measure-Object -Property WorkingSet64 -Sum).Sum / 1MB), 3)
    }
}

$adapters = @(Get-NetAdapter -ErrorAction Stop)
$ipv4Routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)
$ipv6Routes = @(Get-NetRoute -AddressFamily IPv6 -ErrorAction Stop)
$ipConfigurations = @(Get-NetIPConfiguration -ErrorAction Stop)

$result = [ordered]@{
    schema = 'flclash-phase1-windows-capture-v1'
    verificationStatus = 'script-generated; environment must be reviewed on the Windows host'
    scenario = $Scenario
    capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    os = [ordered]@{
        caption = (Get-CimInstance Win32_OperatingSystem).Caption
        version = [Environment]::OSVersion.Version.ToString()
        architecture = $env:PROCESSOR_ARCHITECTURE
    }
    adapters = [ordered]@{
        total = $adapters.Count
        up = @($adapters | Where-Object Status -eq 'Up').Count
        physical = @($adapters | Where-Object { -not $_.Virtual }).Count
        virtual = @($adapters | Where-Object Virtual).Count
    }
    ipConfiguration = [ordered]@{
        interfaceCount = $ipConfigurations.Count
        ipv4AddressCount = @($ipConfigurations.IPv4Address | Where-Object { $null -ne $_ }).Count
        ipv6AddressCount = @($ipConfigurations.IPv6Address | Where-Object { $null -ne $_ }).Count
        ipv4DefaultGatewayCount = @($ipConfigurations.IPv4DefaultGateway | Where-Object { $null -ne $_ }).Count
        ipv6DefaultGatewayCount = @($ipConfigurations.IPv6DefaultGateway | Where-Object { $null -ne $_ }).Count
    }
    routes = [ordered]@{
        ipv4Count = $ipv4Routes.Count
        ipv6Count = $ipv6Routes.Count
        ipv4DefaultCount = @($ipv4Routes | Where-Object DestinationPrefix -eq '0.0.0.0/0').Count
        ipv6DefaultCount = @($ipv6Routes | Where-Object DestinationPrefix -eq '::/0').Count
    }
    dns = @(
        Get-DnsSummary -Name 'login.live.com'
        Get-DnsSummary -Name 'www.bing.com'
    )
    http = @(
        Get-HttpSummary -Url 'https://login.live.com/'
        Get-HttpSummary -Url 'https://www.bing.com/'
    )
    processes = @(
        Get-ProcessSummary -Name 'FlClash'
        Get-ProcessSummary -Name 'FlClashCore'
    )
    omittedSensitiveData = @(
        'adapter names and MAC addresses'
        'IP addresses and gateways'
        'resolved DNS addresses'
        'HTTP response headers and bodies'
        'profile, provider, proxy, rule, and account data'
    )
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$safeTimestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$outputPath = Join-Path $OutputDirectory "$Scenario-$safeTimestamp.json"
$result | ConvertTo-Json -Depth 8 | Set-Content -Path $outputPath -Encoding UTF8

Write-Host "Sanitized capture written to: $outputPath"
