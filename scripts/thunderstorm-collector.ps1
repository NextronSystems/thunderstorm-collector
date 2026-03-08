##################################################
# Script Title: THOR Thunderstorm Collector
# Script File Name: thunderstorm-collector.ps1  
# Author: Florian Roth 
# Version: 0.2.0
# Date Created: 07.10.2020  
# Last Modified: 22.09.2025
################################################## 

#Requires -Version 3

<#   
    .SYNOPSIS   
        The Thunderstorm Collector collects and submits files to THOR Thunderstorm servers for analysis
    .DESCRIPTION 
        The Thunderstorm collector processes a local directory (C:\ by default) and selects files for submission. 
        This selection is based in various filters. The filters include file size, age, extension and location. 
    .PARAMETER ThunderstormServer 
        Server name (FQDN) or IP address of your Thunderstorm instance
    .PARAMETER ThunderstormPort 
        Port number on which the Thunderstorm service is listening (default: 8080)
    .PARAMETER Source
        Source of the submission (default: hostname of the system)
    .PARAMETER Folder 
        Folder to process (default: C:\)
    .PARAMETER MaxAge 
        Select files based on the number of days in which the file has been create or modified (default: 0 = no age selection)
    .PARAMETER MaxSize
        Extensions to select for submission (default: all of them)    
    .PARAMETER Extensions
        Extensions to select for submission (default: all of them)
    .PARAMETER Debugging 
        Do not remove temporary files and show some debug outputs for debugging purposes. 
    .EXAMPLE
        Submit a suspicious folder to THOR Thunderstorm
        
        thunderstorm-collector.ps1 -ThunderstormServer thunderstorm.intranet.local -Folder C:\Users\max.bauer\AppData\Micro\
   .EXAMPLE
        Submit all files on partition C: that yre younger than 1 day to THOR Thunderstorm
        
        thunderstorm-collector.ps1 -ThunderstormServer thunderstorm.intranet.local -MaxAge 1
    .NOTES
        You can set some of the parameters in this script file and don't have to use them all the time. 
        (e.g. -ThunderstormServer shouldn't change in your ENV, so set it in the script)
#>

# #####################################################################
# Parameters ----------------------------------------------------------
# #####################################################################

param
(
    [Parameter(
        HelpMessage='Server name (FQDN) or IP address of your Thunderstorm instance')]
        [ValidateNotNullOrEmpty()]
        [Alias('TS')]
        [string]$ThunderstormServer,

    [Parameter(HelpMessage="Port number on which the Thunderstorm service is listening (default: 8080)")]
        [ValidateNotNullOrEmpty()]
        [Alias('TP')]
        [int]$ThunderstormPort = 8080,

    [Parameter(HelpMessage="Source of the submission (default: hostname of the system)")]
    [Alias('S')]
        [string]$Source,

    [Parameter(HelpMessage="Folder to process (default: C:\)")]
        [ValidateNotNullOrEmpty()]
        [Alias('F')]
        [string]$Folder = "C:\",

    [Parameter(
        HelpMessage='Select files based on the number of days in which the file has been create or modified (default: 0 = no age selection)')]
        [ValidateNotNullOrEmpty()]
        [Alias('MA')]
        [int]$MaxAge,

    [Parameter(
        HelpMessage='Select only files smaller than the given number in MegaBytes (default: 20MB) ')]
        [ValidateNotNullOrEmpty()]
        [Alias('MS')]
        [int]$MaxSize = 20,

    [Parameter(HelpMessage='Extensions to select for submission (default: recommended preset)')]
        [ValidateNotNullOrEmpty()]
        [Alias('E')]
        [string[]]$Extensions,

    [Parameter(HelpMessage='Submit all file extensions (overrides -Extensions)')]
        [switch]$AllExtensions = $False,

    [Parameter(HelpMessage='Use HTTPS instead of HTTP for Thunderstorm communication')]
        [Alias('SSL')]
        [switch]$UseSSL = $False,

    [Parameter(HelpMessage='Skip TLS certificate verification')]
        [Alias('k')]
        [switch]$Insecure = $False,

    [Parameter(HelpMessage='Custom CA certificate bundle for TLS verification (PEM file)')]
        [string]$CACert = "",

    [Parameter(HelpMessage='Log file path (append mode)')]
        [string]$LogFile = "",

    [Parameter(HelpMessage='Enables debug output and skips cleanup at the end of the scan')]
        [ValidateNotNullOrEmpty()]
        [Alias('D')]
        [switch]$Debugging = $False,

    [Parameter(HelpMessage='Force progress reporting on')]
        [switch]$Progress = $False,

    [Parameter(HelpMessage='Force progress reporting off')]
        [switch]$NoProgress = $False
)

# Default source to hostname (cross-platform)
if (-not $Source) {
    $Source = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
}

# Fixing Certain Platform Environments --------------------------------
$AutoDetectPlatform = ""
$OutputPath = $PSScriptRoot

# Microsoft Defender ATP - Live Response
# $PSScriptRoot is empty or contains path to Windows Defender
if ( $OutputPath -eq "" -or $OutputPath.Contains("Advanced Threat Protection") ) {
    $AutoDetectPlatform = "MDATP"
    # Setting output path to easily accessible system root, e.g. C:
    if ( $OutputPath -eq "" ) { 
        $OutputPath = "$($env:ProgramData)\thor"
    }
}

# #####################################################################
# Presets -------------------------------------------------------------
# #####################################################################

# Thunderstorm Server (IP or FQDN)
#[string]$ThunderstormServer = "ygdrasil.nextron"

# Thunderstorm Port
#[int]$ThunderstormPort = 8080

# Folder to scan
#[string]$Folder = C:\myfolder

# Maximum Age
#[int]$MaxAge = 99

# Maximum Size
# Apply default only when no -MaxSize parameter was explicitly passed
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
# No Thunderstorm server 
if ( $Args.Count -eq 0 -and (-not $ThunderstormServer) ) {
    Get-Help $MyInvocation.MyCommand.Definition -Detailed
    Write-Host -ForegroundColor Yellow 'Note: You must at least define an Thunderstorm server (-ThunderstormServer)'
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
        Write-Warning -Message "$($Indicator) $($Entry)"
    } elseif ( $Level -eq "Error" ) {
        [Console]::Error.WriteLine("$($Indicator) $($Entry)")
    } elseif ( $Level -eq "Debug" -and $Debug -eq $False ) {
        return
    } else {
        Write-Host "$($Indicator) $($Entry)"
    }

    # Log File (uses script-level -LogFile parameter)
    if ( $script:LogFile -and ($script:LogFile -ne "") ) {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $($env:COMPUTERNAME): $Entry" | Out-File -FilePath $script:LogFile -Append
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
Write-Host "                                                              "
Write-Host "=============================================================="

# Measure time
$DateStamp = Get-Date -f yyyy-MM-dd
$StartTime = $(Get-Date)

Write-Log "Started Thunderstorm Collector with PowerShell v$($PSVersionTable.PSVersion)"

# ---------------------------------------------------------------------
# Evaluation ----------------------------------------------------------
# ---------------------------------------------------------------------
# Hostname
$Hostname = $env:COMPUTERNAME

# Output Info on Auto-Detection 
if ( $AutoDetectPlatform -ne "" ) {
    Write-Log "Auto Detect Platform: $($AutoDetectPlatform)"
    Write-Log "Note: Some automatic changes have been applied"
}

# URL Creation
$SourceParam = ""
if ( $Source -ne "" ) {
    Write-Log "Using Source: $($Source)"
    $EncodedSource = [uri]::EscapeDataString($Source)
    $SourceParam = "?source=$EncodedSource"
}
$Protocol = "http"
if ( $UseSSL ) {
    $Protocol = "https"
    # Enforce TLS 1.2+ (required on older .NET / PS versions that default to SSL3/TLS1.0)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    } catch {
        # TLS 1.3 not available on older .NET; fall back to TLS 1.2 only
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    Write-Log "HTTPS mode enabled (TLS 1.2+)"

    if ($Insecure) {
        # Skip certificate validation
        Write-Log "WARNING: TLS certificate verification disabled (-Insecure)" -Level "Warning"
        # PS 5+ / .NET 4.5+
        try {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        } catch { }
        # PS 7+ / HttpClient
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $env:DOTNET_SYSTEM_NET_HTTP_USESOCKETSHTTPHANDLER = "0"
        }
    } elseif ($CACert) {
        if (-not (Test-Path $CACert)) {
            Write-Log "CA certificate file not found: $CACert" -Level "Error"
            exit 2
        }
        Write-Log "Using custom CA certificate: $CACert"
        # Load the CA cert and add to the trusted store for this session
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
$BaseUrl = "$($Protocol)://$($ThunderstormServer):$($ThunderstormPort)"
$Url = "$BaseUrl/api/checkAsync$($SourceParam)"
Write-Log "Sending to URI: $($Url)" -Level "Debug"
$ScanId = ""

function Send-CollectionMarker {
    param(
        [string]$MarkerType,
        [string]$ScanId = "",
        [hashtable]$Stats = $null,
        [string]$Reason = ""
    )
    $MarkerUrl = "$BaseUrl/api/collection"
    $Body = @{
        type      = $MarkerType
        source    = $Source
        collector = "powershell3/1.0"
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    if ($ScanId) { $Body["scan_id"] = $ScanId }
    if ($Stats)  { $Body["stats"]   = $Stats  }
    if ($Reason) { $Body["reason"]  = $Reason }

    try {
        $JsonBody = $Body | ConvertTo-Json -Compress
        $Response = Invoke-WebRequest -Uri $MarkerUrl -Method Post `
            -ContentType "application/json" -Body $JsonBody `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $ResponseData = $Response.Content | ConvertFrom-Json
        return $ResponseData.scan_id
    } catch {
        # Silently ignore — server may not support this endpoint yet
        return ""
    }
}

# ---------------------------------------------------------------------
# Run THOR Thunderstorm Collector -------------------------------------
# ---------------------------------------------------------------------
$ProgressPreference = "SilentlyContinue"
$FilesScanned = 0
$FilesSubmitted = 0
$FilesSkipped = 0
$FilesFailed = 0
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
    $separator = if ($Url.Contains("?")) { "&" } else { "?" }
    $Url = "$Url${separator}scan_id=$([uri]::EscapeDataString($ScanId))"
}

# Signal handling: detect Ctrl-C and send interrupted marker
$script:Interrupted = $false
$script:PreviousCancelHandler = $null
try {
    $script:PreviousCancelHandler = [Console]::CancelKeyPress
} catch { }

$cancelHandler = [ConsoleCancelEventHandler]{
    param($sender, $e)
    $e.Cancel = $true  # Prevent immediate termination
    $script:Interrupted = $true
}
[Console]::add_CancelKeyPress($cancelHandler)

# Count files for progress reporting
if ($ShowProgress) {
    $FilesTotal = @(Get-ChildItem -Path $Folder -File -Recurse -ErrorAction SilentlyContinue).Count
    Write-Log "[INFO] Found $FilesTotal files to process"
}

try {
    Get-ChildItem -Path $Folder -File -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object {
        # Check for interruption at each file
        if ($script:Interrupted) { break }
        # -------------------------------------------------------------
        # Filter ------------------------------------------------------
        $FilesScanned++
        # Progress reporting
        if ($ShowProgress -and $FilesTotal -gt 0) {
            $doReport = ($FilesScanned % $ProgressInterval -eq 0)
            if (-not $doReport) {
                $now = Get-Date
                if (($now - $ProgressLastTime).TotalSeconds -ge 10) { $doReport = $true }
            }
            if ($doReport) {
                $ProgressLastTime = Get-Date
                $pct = [int](($FilesScanned * 100) / $FilesTotal)
                Write-Host "[$FilesScanned/$FilesTotal] $pct% processed"
            }
        }
        # Size Check
        if ( ( $_.Length / 1MB ) -gt $($MaxSize) ) {
            Write-Log "$_ skipped due to size filter" -Level "Debug"
            $FilesSkipped++
            return
        }
        # Age Check
        if ( $($MaxAge) -gt 0 ) {
            if ( $_.LastWriteTime -lt (Get-Date).AddDays(-$($MaxAge)) ) {
                Write-Log "$_ skipped due to age filter" -Level "Debug"
                $FilesSkipped++
                return
            }
        }
        # Extensions Check
        if ( $ActiveExtensions.Length -gt 0 ) {
            if ( $ActiveExtensions -contains $_.extension ) { } else {
                Write-Log "$_ skipped due to extension filter" -Level "Debug"
                $FilesSkipped++
                return
            }
        }

        # -------------------------------------------------------------
        # Submission --------------------------------------------------

        Write-Log "Processing $($_.FullName) ..." -Level "Debug"
        # Reading the file data & preparing the request
        try {
            $fileBytes = [System.IO.File]::ReadAllBytes("$($_.FullName)");
        } catch {
            Write-Log "Read Error: $_" -Level "Error"
            $FilesFailed++
            return
        }
        $boundary = [System.Guid]::NewGuid().ToString()
        $LF = "`r`n"
        # Sanitize filename for Content-Disposition header (escape quotes and strip control chars)
        $safeFilename = $_.FullName -replace '["\r\n]', '_'
        $headerText = "--$boundary$LF" +
            "Content-Disposition: form-data; name=`"file`"; filename=`"$safeFilename`"$LF" +
            "Content-Type: application/octet-stream$LF$LF"
        $footerText = "$LF--$boundary--$LF"

        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($headerText)
        $footerBytes = [System.Text.Encoding]::ASCII.GetBytes($footerText)
        $bodyStream = New-Object System.IO.MemoryStream
        $bodyStream.Write($headerBytes, 0, $headerBytes.Length)
        $bodyStream.Write($fileBytes, 0, $fileBytes.Length)
        $bodyStream.Write($footerBytes, 0, $footerBytes.Length)
        $bodyBytes = $bodyStream.ToArray()
        $bodyStream.Dispose()

        # Submitting the request
        $StatusCode = 0
        $Retries = 0
        $MaxRetries = 3
        $Max503Retries = 10
        $Retries503 = 0
        while ( $StatusCode -lt 200 -or $StatusCode -ge 300 ) {
            try {
                Write-Log "Submitting to Thunderstorm server: $($_.FullName) ..." -Level "Info"
                $Response = Invoke-WebRequest -uri $($Url) -Method Post -ContentType "multipart/form-data; boundary=$boundary" -Body $bodyBytes -UseBasicParsing -TimeoutSec 30
                $StatusCode = [int]$Response.StatusCode
                $FilesSubmitted++
            }
            # Catch all non 200 status codes
            catch {
                if ( $_.Exception.Response ) {
                    $StatusCode = $_.Exception.Response.StatusCode.value__
                } else {
                    # Network-level error (DNS, TCP refused, timeout) — no HTTP response
                    $StatusCode = 0
                    Write-Log "Network error submitting $($_.FullName): $($_.Exception.Message)" -Level "Error"
                }
                if ( $StatusCode -eq 503 ) {
                    $Retries503 = $Retries503 + 1
                    if ( $Retries503 -ge $Max503Retries ) {
                        $FilesFailed++
                        Write-Log "503: Server still busy after $Max503Retries retries - giving up on $($_.FullName)" -Level "Warning"
                        break
                    }
                    $WaitSecs = 3
                    if ( $_.Exception.Response.Headers['Retry-After'] ) {
                        $WaitSecs = [int]$_.Exception.Response.Headers['Retry-After']
                    }
                    Write-Log "503: Server seems busy - retrying in $($WaitSecs) seconds ($Retries503/$Max503Retries)"
                    Start-Sleep -Seconds $($WaitSecs)
                } else {
                    $Retries = $Retries + 1
                    if ( $Retries -ge $MaxRetries ) {
                        $FilesFailed++
                        Write-Log "$($StatusCode): Server still has problems after $MaxRetries retries - giving up on $($_.FullName)" -Level "Error"
                        break
                    }
                    $SleepTime = 2 * [Math]::Pow(2, $Retries)
                    Write-Log "$($StatusCode): Server has problems - retrying in $SleepTime seconds"
                    Start-Sleep -Seconds $($SleepTime)
                }
            }
        }
     }
} catch {
    Write-Log "Unknown error during Thunderstorm Collection $_" -Level "Error"
} finally {
    [Console]::remove_CancelKeyPress($cancelHandler)
    # Restore default TLS validation (undo -Insecure side effect)
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
}

# ---------------------------------------------------------------------
# End -----------------------------------------------------------------
# ---------------------------------------------------------------------
$ElapsedTime = $(get-date) - $StartTime
$TotalTime = "{0:HH:mm:ss}" -f ([datetime]$elapsedTime.Ticks)
Write-Log "Scan took $($TotalTime) to complete" -Level "Info"
Write-Log "Results: scanned=$FilesScanned submitted=$FilesSubmitted skipped=$FilesSkipped failed=$FilesFailed"

if ($script:Interrupted) {
    # Send interrupted marker instead of end marker
    Write-Log "Collection interrupted by signal" -Level "Warning"
    Send-CollectionMarker -MarkerType "interrupted" -ScanId $ScanId -Reason "signal" -Stats @{
        scanned          = $FilesScanned
        submitted        = $FilesSubmitted
        skipped          = $FilesSkipped
        failed           = $FilesFailed
        elapsed_seconds  = [int]$ElapsedTime.TotalSeconds
    } | Out-Null
    exit 130
}

# Send collection end marker with stats
Send-CollectionMarker -MarkerType "end" -ScanId $ScanId -Stats @{
    scanned          = $FilesScanned
    submitted        = $FilesSubmitted
    skipped          = $FilesSkipped
    failed           = $FilesFailed
    elapsed_seconds  = [int]$ElapsedTime.TotalSeconds
} | Out-Null

# Exit codes: 0=clean, 1=partial failure, 2=fatal
if ($FilesFailed -gt 0) {
    exit 1
}
