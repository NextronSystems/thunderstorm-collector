##################################################
# Script Title: THOR Thunderstorm Collector (PS 2)
# Script File Name: thunderstorm-collector-ps2.ps1
# Author: Florian Roth
# Version: 0.1.0
# Date Created: 22.02.2026
# Last Modified: 22.02.2026
# Compatibility: PowerShell 2.0+
##################################################

<#
    .SYNOPSIS
        The Thunderstorm Collector collects and submits files to THOR Thunderstorm servers for analysis.
        This version is compatible with PowerShell 2.0+ (uses System.Net.HttpWebRequest instead of Invoke-WebRequest).
    .DESCRIPTION
        The Thunderstorm collector processes a local directory (C:\ by default) and selects files for submission.
        This selection is based on various filters. The filters include file size, age, extension and location.
    .PARAMETER ThunderstormServer
        Server name (FQDN) or IP address of your Thunderstorm instance
    .PARAMETER ThunderstormPort
        Port number on which the Thunderstorm service is listening (default: 8080)
    .PARAMETER Source
        Source of the submission (default: hostname of the system)
    .PARAMETER Folder
        Folder to process (default: C:\)
    .PARAMETER MaxAge
        Select files based on the number of days in which the file has been created or modified (default: 0 = no age selection)
    .PARAMETER MaxSize
        Maximum file size in MegaBytes for submission (default: 20MB)
    .PARAMETER Extensions
        Extensions to select for submission (default: preset list)
    .PARAMETER UseSSL
        Use HTTPS instead of HTTP for Thunderstorm communication
    .PARAMETER Debugging
        Show debug output for troubleshooting purposes
    .EXAMPLE
        powershell.exe -ExecutionPolicy Bypass -File thunderstorm-collector-ps2.ps1 -ThunderstormServer ts.local
    .EXAMPLE
        powershell.exe -ExecutionPolicy Bypass -File thunderstorm-collector-ps2.ps1 -ThunderstormServer ts.local -MaxAge 1 -UseSSL
#>

# #####################################################################
# Parameters ----------------------------------------------------------
# #####################################################################

param(
    [Parameter(HelpMessage='Server name (FQDN) or IP address of your Thunderstorm instance')]
        [ValidateNotNullOrEmpty()]
        [Alias('TS')]
        [string]$ThunderstormServer,

    [Parameter(HelpMessage='Port number on which the Thunderstorm service is listening (default: 8080)')]
        [ValidateNotNullOrEmpty()]
        [Alias('TP')]
        [int]$ThunderstormPort = 8080,

    [Parameter(HelpMessage='Source of the submission (default: hostname of the system)')]
        [Alias('S')]
        [string]$Source,

    [Parameter(HelpMessage='Folder to process (default: C:\)')]
        [ValidateNotNullOrEmpty()]
        [Alias('F')]
        [string]$Folder = "C:\",

    [Parameter(HelpMessage='Select files based on days since last modification (default: 0 = no age selection)')]
        [ValidateNotNullOrEmpty()]
        [Alias('MA')]
        [int]$MaxAge,

    [Parameter(HelpMessage='Maximum file size in MegaBytes (default: 20MB)')]
        [ValidateNotNullOrEmpty()]
        [Alias('MS')]
        [int]$MaxSize = 20,

    [Parameter(HelpMessage='Extensions to select for submission')]
        [ValidateNotNullOrEmpty()]
        [Alias('E')]
        [string[]]$Extensions,

    [Parameter(HelpMessage='Submit all file extensions (overrides -Extensions)')]
        [switch]$AllExtensions = $False,

    [Parameter(HelpMessage='Use HTTPS instead of HTTP')]
        [Alias('SSL')]
        [switch]$UseSSL,

    [Parameter(HelpMessage='Skip TLS certificate verification')]
        [Alias('k')]
        [switch]$Insecure,

    [Parameter(HelpMessage='Custom CA certificate bundle for TLS verification')]
        [string]$CACert = "",

    [Parameter(HelpMessage='Log file path (append mode)')]
        [string]$LogFile = "",

    [Parameter(HelpMessage='Enable debug output')]
        [Alias('D')]
        [switch]$Debugging,

    [Parameter(HelpMessage='Force progress reporting on')]
        [switch]$Progress,

    [Parameter(HelpMessage='Force progress reporting off')]
        [switch]$NoProgress
)

# Default source to hostname (cross-platform)
if (-not $Source) {
    if ($env:COMPUTERNAME) { $Source = $env:COMPUTERNAME }
    else { $Source = [System.Net.Dns]::GetHostName() }
}

# Fixing Certain Platform Environments --------------------------------
$AutoDetectPlatform = ""
$OutputPath = $PSScriptRoot

# Microsoft Defender ATP - Live Response
if ( $OutputPath -eq "" -or $OutputPath -like "*Advanced Threat Protection*" ) {
    $AutoDetectPlatform = "MDATP"
    if ( $OutputPath -eq "" ) {
        $OutputPath = "$($env:ProgramData)\thor"
    }
}

# #####################################################################
# Presets -------------------------------------------------------------
# #####################################################################

# Maximum Size - apply default only when not explicitly passed
if (-not $PSBoundParameters.ContainsKey('MaxSize')) {
    [int]$MaxSize = 20
}

# Extensions
# -AllExtensions overrides any -Extensions value
# Note: PS 2.0 permanently binds parameter validation to $Extensions,
# so we use a separate $ActiveExtensions variable for the working copy.
if ($AllExtensions) {
    [string[]]$ActiveExtensions = @()
} elseif ($PSBoundParameters.ContainsKey('Extensions')) {
    [string[]]$ActiveExtensions = $Extensions
} else {
    # Apply recommended preset only when no -Extensions parameter was explicitly passed
    [string[]]$ActiveExtensions = @('.asp','.vbs','.ps','.ps1','.rar','.tmp','.bas','.bat','.chm','.cmd','.com','.cpl','.crt','.dll','.exe','.hta','.js','.lnk','.msc','.ocx','.pcd','.pif','.pot','.reg','.scr','.sct','.sys','.url','.vb','.vbe','.vbs','.wsc','.wsf','.wsh','.ct','.t','.input','.war','.jsp','.php','.asp','.aspx','.doc','.docx','.pdf','.xls','.xlsx','.ppt','.pptx','.tmp','.log','.dump','.pwd','.w','.txt','.conf','.cfg','.conf','.config','.psd1','.psm1','.ps1xml','.clixml','.psc1','.pssc','.pl','.www','.rdp','.jar','.docm','.ace','.job','.temp','.plg','.asm')
}

# Debug
$Debug = $Debugging

# Show Help -----------------------------------------------------------
if ( $Args.Count -eq 0 -and (-not $ThunderstormServer) ) {
    Get-Help $MyInvocation.MyCommand.Definition -Detailed
    Write-Host -ForegroundColor Yellow 'Note: You must at least define a Thunderstorm server (-ThunderstormServer)'
    return
}

# #####################################################################
# Functions -----------------------------------------------------------
# #####################################################################

function Write-Log {
    param (
        [Parameter(Mandatory=$True, Position=0, HelpMessage="Log entry")]
            [ValidateNotNullOrEmpty()]
            [String]$Entry,

        [Parameter(Position=1, HelpMessage="Level")]
            [ValidateNotNullOrEmpty()]
            [String]$Level = "Info"
    )

    # Indicator
    $Indicator = "[+]"
    if ( $Level -eq "Warning" ) {
        $Indicator = "[!]"
    } elseif ( $Level -eq "Error" ) {
        $Indicator = "[E]"
    } elseif ( $Level -eq "Progress" ) {
        $Indicator = "[.]"
    } elseif ($Level -eq "Note" ) {
        $Indicator = "[i]"
    }

    # Output Pipe
    if ( $Level -eq "Warning" ) {
        Write-Warning "$($Indicator) $($Entry)"
    } elseif ( $Level -eq "Error" ) {
        # Write to stderr (Write-Host goes to console only, invisible when redirected)
        [Console]::Error.WriteLine("$($Indicator) $($Entry)")
    } elseif ( $Level -eq "Debug" -and $Debug -eq $False ) {
        return
    } else {
        Write-Host "$($Indicator) $($Entry)"
    }

    # Log File (only if specified via script-level -LogFile parameter)
    if ( $script:LogFile -and ($script:LogFile -ne "") ) {
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        "$ts $($env:COMPUTERNAME): $Entry" | Out-File -FilePath $script:LogFile -Append
    }
}

# Submit-File: uploads a file using System.Net.HttpWebRequest (PS 2.0 compatible)
# Returns the HTTP status code (int) or 0 on connection failure.
function Submit-File {
    param(
        [Parameter(Mandatory=$True)][string]$Url,
        [Parameter(Mandatory=$True)][string]$FilePath,
        [Parameter(Mandatory=$True)][byte[]]$FileBytes
    )

    $boundary = [System.Guid]::NewGuid().ToString()
    $CRLF = "`r`n"

    # Sanitize filename for Content-Disposition header (escape quotes and strip control chars)
    $safeFilename = $FilePath -replace '["\r\n]', '_'
    # Build multipart header and footer as UTF-8 bytes
    $headerText = "--$boundary$CRLF" +
        "Content-Disposition: form-data; name=`"file`"; filename=`"$safeFilename`"$CRLF" +
        "Content-Type: application/octet-stream$CRLF$CRLF"
    $footerText = "$CRLF--$boundary--$CRLF"

    $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($headerText)
    $footerBytes = [System.Text.Encoding]::ASCII.GetBytes($footerText)

    $contentLength = $headerBytes.Length + $FileBytes.Length + $footerBytes.Length

    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = "POST"
        $request.ContentType = "multipart/form-data; boundary=$boundary"
        $request.ContentLength = $contentLength
        $request.Timeout = 120000  # 120 seconds
        $request.AllowAutoRedirect = $true

        # Write raw bytes directly to the request stream — no encoding layer
        $stream = $null
        try {
            $stream = $request.GetRequestStream()
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $stream.Write($FileBytes, 0, $FileBytes.Length)
            $stream.Write($footerBytes, 0, $footerBytes.Length)
        } finally {
            if ($stream) { $stream.Close() }
        }

        $response = $request.GetResponse()
        $statusCode = [int]$response.StatusCode
        $response.Close()
        return $statusCode
    }
    catch [System.Net.WebException] {
        $ex = $_.Exception
        if ( $ex.Response -ne $null ) {
            $errResponse = $ex.Response
            $statusCode = [int]$errResponse.StatusCode

            # Extract Retry-After header if present
            $retryAfter = $errResponse.Headers["Retry-After"]
            if ( $retryAfter -ne $null ) {
                $script:LastRetryAfter = $retryAfter
            }

            $errResponse.Close()
            return $statusCode
        }
        # No response at all (connection refused, DNS failure, etc.)
        Write-Log "Connection error: $($ex.Message)" -Level "Error"
        return 0
    }
}

# #####################################################################
# Main Program --------------------------------------------------------
# #####################################################################

Write-Host "=============================================================="
Write-Host "    ________                __            __                  "
Write-Host "   /_  __/ /  __ _____  ___/ /__ _______ / /____  ______ _    "
Write-Host "    / / / _ \/ // / _ \/ _  / -_) __(_--/ __/ _ \/ __/  ' \   "
Write-Host "   /_/ /_//_/\_,_/_//_/\_,_/\__/_/ /___/\__/\___/_/ /_/_/_/   "
Write-Host "                                                              "
Write-Host "   Florian Roth, Nextron Systems GmbH, 2020-2026              "
Write-Host "   PowerShell 2.0+ compatible version                         "
Write-Host "                                                              "
Write-Host "=============================================================="

# Measure time
$StartTime = Get-Date

Write-Log "Started Thunderstorm Collector (PS2) with PowerShell v$($PSVersionTable.PSVersion)"

# ---------------------------------------------------------------------
# Evaluation ----------------------------------------------------------
# ---------------------------------------------------------------------

# Output Info on Auto-Detection
if ( $AutoDetectPlatform -ne "" ) {
    Write-Log "Auto Detect Platform: $($AutoDetectPlatform)"
    Write-Log "Note: Some automatic changes have been applied"
}

# TLS Configuration
$Protocol = "http"
if ( $UseSSL ) {
    $Protocol = "https"
    try {
        # .NET 4.5+ enum values; TLS 1.2 = 3072, TLS 1.3 = 12288
        [System.Net.ServicePointManager]::SecurityProtocol = 3072 -bor 12288
    } catch {
        try {
            # Fall back to TLS 1.2 only
            [System.Net.ServicePointManager]::SecurityProtocol = 3072
        } catch {
            Write-Log "WARNING: Could not set TLS 1.2. HTTPS may fail on this system." -Level "Warning"
        }
    }
    Write-Log "HTTPS mode enabled"

    if ($Insecure) {
        Write-Log "WARNING: TLS certificate verification disabled (-Insecure)" -Level "Warning"
        # PS 2.0 compatible: use a custom type for cert validation bypass
        try {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        } catch {
            # Alternative for PS 2.0: define a type if callback assignment fails
            try {
                Add-Type @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class TrustAll {
    public static void Enable() {
        ServicePointManager.ServerCertificateValidationCallback =
            delegate { return true; };
    }
}
"@
                [TrustAll]::Enable()
            } catch { }
        }
    } elseif ($CACert) {
        if (-not (Test-Path $CACert)) {
            Write-Log "CA certificate file not found: $CACert" -Level "Error"
            exit 2
        }
        Write-Log "Using custom CA certificate: $CACert"
        try {
            $CACertObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CACert)
            # Use compiled C# delegate for CACert validation:
            # - Scriptblock closures don't reliably capture $CACertObj in PS 2.0
            # - RemoteCertificateValidationCallback receives X509Certificate, but
            #   X509Chain.Build() requires X509Certificate2 — must cast explicitly
            $CACertBase64 = [Convert]::ToBase64String($CACertObj.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
            Add-Type @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class CACertValidator {
    private static X509Certificate2 _caCert;
    public static void Install(string base64Cert) {
        _caCert = new X509Certificate2(Convert.FromBase64String(base64Cert));
        ServicePointManager.ServerCertificateValidationCallback = Validate;
    }
    private static bool Validate(object sender, X509Certificate certificate,
            X509Chain chain, SslPolicyErrors sslPolicyErrors) {
        if (sslPolicyErrors == SslPolicyErrors.None) return true;
        chain.ChainPolicy.ExtraStore.Add(_caCert);
        return chain.Build(new X509Certificate2(certificate));
    }
}
"@
            [CACertValidator]::Install($CACertBase64)
        } catch {
            Write-Log "Failed to load CA certificate: $($_.Exception.Message)" -Level "Error"
            exit 2
        }
    }
}

# URL Creation
$SourceParam = ""
if ( $Source -ne "" ) {
    Write-Log "Using Source: $($Source)"
    # URL-encode the source parameter
    $EncodedSource = [uri]::EscapeDataString($Source)
    $SourceParam = "?source=$EncodedSource"
}
$BaseUrl = "$($Protocol)://$($ThunderstormServer):$($ThunderstormPort)"
$Url = "$BaseUrl/api/checkAsync$($SourceParam)"
Write-Log "Sending to URI: $($Url)" -Level "Debug"
$ScanId = ""

# PS2-compatible JSON escape: escape backslash, double quote, and all control characters
function ConvertTo-JsonString {
    param([string]$Value)
    $s = $Value -replace '\\', '\\'
    $s = $s -replace '"', '\"'
    $s = $s -replace "`r", '\r'
    $s = $s -replace "`n", '\n'
    $s = $s -replace "`t", '\t'
    # Escape remaining control characters (U+0000 to U+001F)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $s.ToCharArray()) {
        $code = [int]$c
        if ($code -lt 0x20) {
            [void]$sb.Append(('\u{0:x4}' -f $code))
        } else {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString()
}

function Send-CollectionMarker {
    param(
        [string]$MarkerType,
        [string]$ScanId = "",
        [hashtable]$Stats = $null,
        [string]$Reason = ""
    )
    $MarkerUrl = "$BaseUrl/api/collection"
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    # Build JSON manually (ConvertTo-Json not available in PS 2.0)
    $JsonBody = '{"type":"' + (ConvertTo-JsonString $MarkerType) + '",' +
        '"source":"' + (ConvertTo-JsonString $Source) + '",' +
        '"collector":"powershell2/1.0",' +
        '"timestamp":"' + $ts + '"'
    if ($ScanId) {
        $JsonBody += ',"scan_id":"' + (ConvertTo-JsonString $ScanId) + '"'
    }
    if ($Stats) {
        # Build stats object manually — all values are integers
        $statParts = @()
        foreach ($key in $Stats.Keys) {
            $statParts += '"' + $key + '":' + $Stats[$key]
        }
        $JsonBody += ',"stats":{' + ($statParts -join ',') + '}'
    }
    if ($Reason) {
        $JsonBody += ',"reason":"' + (ConvertTo-JsonString $Reason) + '"'
    }
    $JsonBody += '}'

    try {
        $JsonBytes = [System.Text.Encoding]::UTF8.GetBytes($JsonBody)
        $Req = [System.Net.HttpWebRequest]::Create($MarkerUrl)
        $Req.Method = "POST"
        $Req.ContentType = "application/json"
        $Req.ContentLength = $JsonBytes.Length
        $Req.Timeout = 10000
        $Stream = $Req.GetRequestStream()
        $Stream.Write($JsonBytes, 0, $JsonBytes.Length)
        $Stream.Close()
        $Resp = $Req.GetResponse()
        $Reader = New-Object System.IO.StreamReader($Resp.GetResponseStream())
        $RespBody = $Reader.ReadToEnd()
        $Reader.Close()
        $Resp.Close()

        # Parse scan_id from response manually (no ConvertFrom-Json in PS 2.0)
        if ($RespBody -match '"scan_id"\s*:\s*"([^"]+)"') {
            return $matches[1]
        }
        return ""
    } catch {
        Write-Log "Collection marker ($MarkerType) failed: $($_.Exception.Message)" -Level "Debug"
        return ""
    }
}

# ---------------------------------------------------------------------
# Run THOR Thunderstorm Collector -------------------------------------
# ---------------------------------------------------------------------

$SubmittedCount = 0
$ErrorCount = 0
$ScannedCount = 0
$SkippedCount = 0
$FilesTotal = 0

# Resolve progress reporting mode
$ShowProgress = $false
if ($Progress) {
    $ShowProgress = $true
} elseif (-not $NoProgress) {
    try { $ShowProgress = -not [Console]::IsOutputRedirected } catch { $ShowProgress = $false }
}
$ProgressInterval = 100
$ProgressLastTime = [DateTime]::MinValue

# Send collection begin marker (retry once on failure)
$ScanId = Send-CollectionMarker -MarkerType "begin"
if (-not $ScanId) {
    Write-Log "Begin marker failed, retrying in 2s..." -Level "Warning"
    Start-Sleep -Seconds 2
    $ScanId = Send-CollectionMarker -MarkerType "begin"
}
if ($ScanId) {
    Write-Log "Collection scan_id: $ScanId"
    $separator = "&"
    if (-not $Url.Contains("?")) { $separator = "?" }
    $Url = "$Url${separator}scan_id=$([uri]::EscapeDataString($ScanId))"
}

# Signal handling: detect Ctrl-C and send interrupted marker
$script:Interrupted = $false
$cancelHandler = $null
try {
    $cancelHandler = [ConsoleCancelEventHandler]{
        param($sender, $e)
        $e.Cancel = $true
        $script:Interrupted = $true
    }
    [Console]::add_CancelKeyPress($cancelHandler)
} catch {
    # PS 2.0 on older .NET may not support this — graceful degradation
}

# PS 2 compatible file enumeration (Get-ChildItem -File not available in PS 2)
$files = Get-ChildItem -Path $Folder -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer }

# Count files for progress reporting
if ($ShowProgress) {
    $FilesTotal = @($files).Count
    Write-Log "[INFO] Found $FilesTotal files to process"
}

foreach ( $file in $files ) {
    if ($script:Interrupted) { break }
    # -----------------------------------------------------------------
    # Filter ----------------------------------------------------------

    $ScannedCount++
    # Progress reporting
    if ($ShowProgress -and $FilesTotal -gt 0) {
        $doReport = ($ScannedCount % $ProgressInterval -eq 0)
        if (-not $doReport) {
            $now = Get-Date
            if (($now - $ProgressLastTime).TotalSeconds -ge 10) { $doReport = $true }
        }
        if ($doReport) {
            $ProgressLastTime = Get-Date
            $pct = [int](($ScannedCount * 100) / $FilesTotal)
            Write-Host "[$ScannedCount/$FilesTotal] $pct% processed"
        }
    }
    # Size Check
    if ( ( $file.Length / 1MB ) -gt $MaxSize ) {
        Write-Log "$($file.Name) skipped due to size filter" -Level "Debug"
        $SkippedCount++
        continue
    }

    # Age Check
    if ( $MaxAge -gt 0 ) {
        if ( $file.LastWriteTime -lt (Get-Date).AddDays(-$MaxAge) ) {
            Write-Log "$($file.Name) skipped due to age filter" -Level "Debug"
            $SkippedCount++
            continue
        }
    }

    # Extensions Check
    if ( $ActiveExtensions.Length -gt 0 ) {
        $match = $false
        foreach ( $ext in $ActiveExtensions ) {
            if ( $file.Extension -eq $ext ) { $match = $true; break }
        }
        if ( -not $match ) {
            Write-Log "$($file.Name) skipped due to extension filter" -Level "Debug"
            $SkippedCount++
            continue
        }
    }

    # -----------------------------------------------------------------
    # Submission ------------------------------------------------------

    Write-Log "Processing $($file.FullName) ..." -Level "Debug"

    # Read file as raw bytes
    try {
        $fileBytes = [System.IO.File]::ReadAllBytes($file.FullName)
    } catch {
        Write-Log "Read Error: $_" -Level "Error"
        $ErrorCount++
        continue
    }

    # Submit with retry logic
    $StatusCode = 0
    $Retries = 0
    $MaxRetries = 3
    $Max503Retries = 10
    $Retries503 = 0
    $script:LastRetryAfter = $null

    while ( $StatusCode -lt 200 -or $StatusCode -ge 300 ) {

        Write-Log "Submitting to Thunderstorm server: $($file.FullName) ..." -Level "Info"
        $StatusCode = Submit-File -Url $Url -FilePath $file.FullName -FileBytes $fileBytes

        if ( $StatusCode -ge 200 -and $StatusCode -lt 300 ) {
            $SubmittedCount++
            break
        }
        elseif ( $StatusCode -eq 503 ) {
            $Retries503++
            if ( $Retries503 -ge $Max503Retries ) {
                Write-Log "503: Server still busy after $Max503Retries retries - giving up on $($file.FullName)" -Level "Warning"
                break
            }
            $WaitSecs = 3
            if ( $script:LastRetryAfter -ne $null ) {
                try { $WaitSecs = [int]$script:LastRetryAfter } catch { $WaitSecs = 3 }
            }
            Write-Log "503: Server seems busy - retrying in $WaitSecs seconds ($Retries503/$Max503Retries)"
            Start-Sleep -Seconds $WaitSecs
        }
        elseif ( $StatusCode -eq 0 ) {
            # Connection failure
            $Retries++
            if ( $Retries -ge $MaxRetries ) {
                Write-Log "Connection failed after $MaxRetries retries - giving up on $($file.FullName)" -Level "Error"
                $ErrorCount++
                break
            }
            $SleepTime = 2 * [Math]::Pow(2, $Retries)
            Write-Log "Connection failed - retrying in $SleepTime seconds ($Retries/$MaxRetries)"
            Start-Sleep -Seconds $SleepTime
        }
        else {
            $Retries++
            if ( $Retries -ge $MaxRetries ) {
                Write-Log "$($StatusCode): Server error after $MaxRetries retries - giving up on $($file.FullName)" -Level "Error"
                $ErrorCount++
                break
            }
            $SleepTime = 2 * [Math]::Pow(2, $Retries)
            Write-Log "$($StatusCode): Server has problems - retrying in $SleepTime seconds ($Retries/$MaxRetries)"
            Start-Sleep -Seconds $SleepTime
        }
    }
}

# Clean up signal handler
if ($cancelHandler) {
    try { [Console]::remove_CancelKeyPress($cancelHandler) } catch { }
}

# ---------------------------------------------------------------------
# End -----------------------------------------------------------------
# ---------------------------------------------------------------------
$ElapsedTime = (Get-Date) - $StartTime
$TotalTime = "{0:HH:mm:ss}" -f ([datetime]$ElapsedTime.Ticks)
Write-Log "Submitted $SubmittedCount files ($ErrorCount errors) in $TotalTime" -Level "Info"
Write-Log "Results: scanned=$ScannedCount submitted=$SubmittedCount skipped=$SkippedCount failed=$ErrorCount"

if ($script:Interrupted) {
    Write-Log "Collection interrupted by signal" -Level "Warning"
    Send-CollectionMarker -MarkerType "interrupted" -ScanId $ScanId -Reason "signal" -Stats @{
        scanned         = $ScannedCount
        submitted       = $SubmittedCount
        skipped         = $SkippedCount
        failed          = $ErrorCount
        elapsed_seconds = [int]$ElapsedTime.TotalSeconds
    } | Out-Null
    exit 130
}

# Send collection end marker with stats
Send-CollectionMarker -MarkerType "end" -ScanId $ScanId -Stats @{
    scanned         = $ScannedCount
    submitted       = $SubmittedCount
    skipped         = $SkippedCount
    failed          = $ErrorCount
    elapsed_seconds = [int]$ElapsedTime.TotalSeconds
} | Out-Null

# Exit codes: 0=clean, 1=partial failure, 2=fatal
if ($ErrorCount -gt 0) {
    exit 1
}
