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
        Select files based on the number of days in which the file has been create or modified (default: 14 days)
    .PARAMETER MaxSize
        Maximum file size in MegaBytes for submission (default: 2MB / 2048KB)
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
        [string]$Source=$env:COMPUTERNAME,

    [Parameter(HelpMessage="Folder to process (default: C:\)")]
        [ValidateNotNullOrEmpty()]
        [Alias('F')]
        [string]$Folder = "C:\",

    [Parameter(
        HelpMessage='Select files based on the number of days in which the file has been create or modified (default: 14 days)')]
        [ValidateNotNullOrEmpty()]
        [Alias('MA')]
        [int]$MaxAge = 14,

    [Parameter(
        HelpMessage='Select only files smaller than the given number in MegaBytes (default: 2MB / 2048KB) ')]
        [ValidateNotNullOrEmpty()]
        [Alias('MS')]
        [int]$MaxSize = 2,

    [Parameter(HelpMessage='Extensions to select for submission (default: recommended preset)')]
        [ValidateNotNullOrEmpty()]
        [Alias('E')]
        [string[]]$Extensions,

    [Parameter(HelpMessage='Submit all file extensions (overrides -Extensions)')]
        [switch]$AllExtensions = $False,

    [Parameter(HelpMessage='Use HTTPS instead of HTTP for Thunderstorm communication')]
        [Alias('SSL')]
        [switch]$UseSSL = $False,

    [Parameter(HelpMessage='Path to custom CA certificate bundle for TLS verification')]
        [string]$CACert = "",

    [Parameter(HelpMessage='Skip TLS certificate verification (insecure)')]
        [Alias('k')]
        [switch]$Insecure = $False,

    [Parameter(HelpMessage='Enables debug output and skips cleanup at the end of the scan')]

        [ValidateNotNullOrEmpty()]
        [Alias('D')]
        [switch]$Debugging = $False,

    [Parameter(HelpMessage='Force enable progress reporting')]
        [switch]$Progress = $False,

    [Parameter(HelpMessage='Force disable progress reporting')]
        [switch]$NoProgress = $False
)


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
    [int]$MaxSize = 2
}
# Enforce hard upper bound on MaxSize to prevent out-of-memory conditions
if ($MaxSize -gt 200) {
    Write-Host "[!] MaxSize capped to 200 MB to prevent excessive memory usage"
    $MaxSize = 200
}

# Extensions
# -AllExtensions overrides any -Extensions value
# Note: PS 2.0 permanently binds parameter validation to $Extensions,
# so we use a separate $ActiveExtensions variable for the working copy.
if ($AllExtensions) {
    [string[]]$ActiveExtensions = @()
} elseif ($PSBoundParameters.ContainsKey('Extensions')) {
    # Normalize user-supplied extensions: lowercase and ensure leading dot
    [string[]]$ActiveExtensions = $Extensions | ForEach-Object {
        $ext = $_.ToLowerInvariant().Trim()
        if ($ext -ne '' -and -not $ext.StartsWith('.')) { $ext = '.' + $ext }
        $ext
    }
} else {
    # Apply recommended preset only when no -Extensions parameter was explicitly passed
    [string[]]$ActiveExtensions = @('.asp','.vbs','.ps','.ps1','.rar','.tmp','.bas','.bat','.chm','.cmd','.com','.cpl','.crt','.dll','.exe','.hta','.js','.lnk','.msc','.ocx','.pcd','.pif','.pot','.reg','.scr','.sct','.sys','.url','.vb','.vbe','.vbs','.wsc','.wsf','.wsh','.ct','.t','.input','.war','.jsp','.php','.asp','.aspx','.doc','.docx','.pdf','.xls','.xlsx','.ppt','.pptx','.tmp','.log','.dump','.pwd','.w','.txt','.conf','.cfg','.conf','.config','.psd1','.psm1','.ps1xml','.clixml','.psc1','.pssc','.pl','.www','.rdp','.jar','.docm','.ace','.job','.temp','.plg','.asm')
}

# Debug
$Debug = $Debugging

# Show Help -----------------------------------------------------------
# No Thunderstorm server 
if ( $ThunderstormServer -eq "" ) {
    Get-Help $MyInvocation.MyCommand.Definition -Detailed
    Write-Host -ForegroundColor Yellow 'Note: You must at least define a Thunderstorm server (-ThunderstormServer)'
    exit 2
}


# #####################################################################
# Functions -----------------------------------------------------------
# #####################################################################

function Write-Log {
    param (
        [Parameter(Mandatory=$True, Position=0, HelpMessage="Log entry")]
            [ValidateNotNullOrEmpty()]
            [String]$Entry,

        [Parameter(Position=1, HelpMessage="Log file to write into")]
            [ValidateNotNullOrEmpty()]
            [Alias('SS')]
            [IO.FileInfo]$LogFile = (Join-Path $OutputPath "thunderstorm-collector.log"),


        [Parameter(Position=3, HelpMessage="Level")]
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

    # Log File
    if ( -not $global:NoLog ) {

        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $($env:COMPUTERNAME): $Entry" | Out-File -FilePath $LogFile -Append
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
Write-Host "   Florian Roth, Nextron Systems GmbH, 2020                   "
Write-Host "                                                              "
Write-Host "=============================================================="

# Measure time
$DateStamp = Get-Date -f yyyy-MM-dd
$StartTime = $(Get-Date)

# Validate folder exists
if (-not (Test-Path -Path $Folder -PathType Container)) {
    Write-Log "Folder not found: $Folder" -Level "Error"
    exit 2
}


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
        Write-Log "TLS certificate verification DISABLED (insecure mode)" -Level "Warning"
        # Use ServerCertificateValidationCallback (works on .NET 4.5+ / PS 3+)
        try {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [System.Net.Security.RemoteCertificateValidationCallback]{
                param($sender, $certificate, $chain, $sslPolicyErrors)
                return $true
            }
        } catch {
            # Fallback: try legacy ICertificatePolicy for older .NET
            try {
                if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
                    Add-Type @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) { return true; }
}
"@
                }
                [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
            } catch {
                Write-Log "Failed to set insecure certificate policy: $_" -Level "Warning"
            }
        }
    } elseif ($CACert -ne "") {
        if (-not (Test-Path $CACert)) {
            Write-Log "CA certificate file not found: $CACert" -Level "Error"
            exit 2
        }
        Write-Log "Using custom CA certificate: $CACert"
        try {
            # Load custom CA and set up validation callback with hostname verification
            $script:CustomCACert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CACert)
            $script:ExpectedHost = $ThunderstormServer
            if (-not ([System.Management.Automation.PSTypeName]'CustomCACertValidator').Type) {
                Add-Type @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;

public static class CustomCACertValidator {
    private static X509Certificate2 _ca;
    private static string _expectedHost;

    public static void Configure(X509Certificate2 ca, string expectedHost) {
        _ca = ca;
        _expectedHost = expectedHost;
    }

    public static bool ValidateCallback(
        object sender, X509Certificate certificate,
        X509Chain chain, SslPolicyErrors sslPolicyErrors) {
        // If the platform says everything is fine, accept
        if (sslPolicyErrors == SslPolicyErrors.None) return true;

        X509Certificate2 cert2 = new X509Certificate2(certificate);

        // Build chain with our custom CA
        X509Chain customChain = new X509Chain();
        customChain.ChainPolicy.ExtraStore.Add(_ca);
        customChain.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
        customChain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        bool chainValid = customChain.Build(cert2);
        if (!chainValid) return false;

        // Verify the chain actually roots at our CA
        bool rootedAtCA = false;
        foreach (var element in customChain.ChainElements) {
            if (element.Certificate.Thumbprint == _ca.Thumbprint) {
                rootedAtCA = true;
                break;
            }
        }
        if (!rootedAtCA) return false;

        // Hostname verification: check SAN and CN
        if (!MatchesHost(cert2, _expectedHost)) return false;

        return true;
    }

    private static bool MatchesHost(X509Certificate2 cert, string host) {
        // Check Subject Alternative Names (OID 2.5.29.17)
        foreach (var ext in cert.Extensions) {
            if (ext.Oid.Value == "2.5.29.17") {
                string san = ext.Format(true);
                // Parse DNS Name entries
                foreach (string line in san.Split(new char[]{'\r','\n'}, StringSplitOptions.RemoveEmptyEntries)) {
                    string trimmed = line.Trim();
                    if (trimmed.StartsWith("DNS Name=", StringComparison.OrdinalIgnoreCase)) {
                        string dnsName = trimmed.Substring(9).Trim();
                        if (HostMatchesPattern(host, dnsName)) return true;
                    }
                    // Also handle "DNS:" format
                    if (trimmed.StartsWith("DNS:", StringComparison.OrdinalIgnoreCase)) {
                        string dnsName = trimmed.Substring(4).Trim();
                        if (HostMatchesPattern(host, dnsName)) return true;
                    }
                }
            }
        }
        // Fallback to CN in Subject
        string subject = cert.Subject;
        var match = Regex.Match(subject, @"CN\s*=\s*([^,]+)");
        if (match.Success) {
            string cn = match.Groups[1].Value.Trim();
            if (HostMatchesPattern(host, cn)) return true;
        }
        return false;
    }

    private static bool HostMatchesPattern(string host, string pattern) {
        if (string.Equals(host, pattern, StringComparison.OrdinalIgnoreCase))
            return true;
        // Wildcard matching: *.example.com matches foo.example.com
        if (pattern.StartsWith("*.")) {
            string suffix = pattern.Substring(1); // .example.com
            int dotIndex = host.IndexOf('.');
            if (dotIndex > 0) {
                string hostSuffix = host.Substring(dotIndex);
                if (string.Equals(hostSuffix, suffix, StringComparison.OrdinalIgnoreCase))
                    return true;
            }
        }
        return false;
    }
}
"@
            }
            [CustomCACertValidator]::Configure($script:CustomCACert, $script:ExpectedHost)
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [System.Net.Security.RemoteCertificateValidationCallback]([CustomCACertValidator].GetMethod('ValidateCallback'))
        } catch {
            Write-Log "Failed to configure custom CA certificate: $_" -Level "Error"
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
        [switch]$Fatal = $False
    )
    $MarkerUrl = "$BaseUrl/api/collection"
    # Let ConvertTo-Json handle proper JSON escaping of all characters including control chars
    $Body = @{
        type      = $MarkerType
        source    = $Source
        collector = "powershell3/1.0"
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    if ($ScanId) { $Body["scan_id"] = $ScanId }
    if ($Stats)  { $Body["stats"]   = $Stats  }

    try {
        $JsonBody = $Body | ConvertTo-Json -Compress
        $Response = Invoke-WebRequest -Uri $MarkerUrl -Method Post `
            -ContentType "application/json" -Body $JsonBody `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $ResponseData = $Response.Content | ConvertFrom-Json
        return $ResponseData.scan_id
    } catch {
        $HttpStatus = $null
        if ($_.Exception.Response) {
            $HttpStatus = $_.Exception.Response.StatusCode.value__
        }
        # 404 or 501 means the server doesn't support collection markers -- not fatal
        if ($HttpStatus -eq 404 -or $HttpStatus -eq 501) {
            Write-Log "Collection marker endpoint not supported by server (HTTP $HttpStatus)" -Level "Debug"
            return ""
        }
        # For other errors, log and optionally treat as fatal
        Write-Log "Collection marker '$MarkerType' failed: $_" -Level "Warning"
        if ($Fatal) {
            throw $_
        }
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
# Use a reference object for cross-runspace signal communication
$script:InterruptSignal = New-Object PSObject -Property @{ Value = $False }
$global:Interrupted = $False

# Progress reporting: auto-detect TTY unless overridden
$ShowProgress = $False
if ($Progress) {
    $ShowProgress = $True
} elseif ($NoProgress) {
    $ShowProgress = $False
} else {
    try {
        # Auto-detect: show progress if stdout is a terminal
        if ([Environment]::UserInteractive -and [Console]::WindowWidth -gt 0) {
            $ShowProgress = $True
        }
    } catch {
        $ShowProgress = $False
    }
}
$TotalFiles = 0
if ($ShowProgress) {
    # Pre-count files for progress percentage (best effort)
    # Skip pre-count for root/large directories to avoid long startup delay
    $SkipPreCount = $False
    try {
        $FolderNormalized = (Resolve-Path $Folder -ErrorAction SilentlyContinue).Path
        # Skip pre-count for drive roots (e.g. C:\, D:\)
        if ($FolderNormalized -match '^[A-Za-z]:\\?$') {
            $SkipPreCount = $True
        }
    } catch {
        $SkipPreCount = $True
    }
    if (-not $SkipPreCount) {
        try {
            $PreCountErrors = @()
            $TotalFiles = @(Get-ChildItem -Path $Folder -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable PreCountErrors | Where-Object { -not $_.PSIsContainer }).Count
        } catch {
            $TotalFiles = 0
        }
    }
}


# Register handler for Ctrl+C (SIGINT) using a C# helper for static event subscription
[Console]::TreatControlCAsInput = $False
try {
    if (-not ([System.Management.Automation.PSTypeName]'SigIntHandler').Type) {
        Add-Type @"
using System;
public static class SigIntHandler {
    public static volatile bool Interrupted = false;
    private static bool _registered = false;
    public static void Register() {
        if (_registered) return;
        _registered = true;
        Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e) {
            e.Cancel = true;
            Interrupted = true;
        };
    }
}
"@
    }
    [SigIntHandler]::Register()
} catch {
    # CancelKeyPress registration not available on all platforms (e.g. non-interactive)
    Write-Log "SIGINT handler registration not available: $_" -Level "Debug"
}


# Send collection begin marker (with single retry after 2s on connection failure)
$ScanId = ""
$BeginMarkerSuccess = $False
try {
    $ScanId = Send-CollectionMarker -MarkerType "begin" -Fatal
    $BeginMarkerSuccess = $True
} catch {
    # Check if this is a connection error (no HTTP response) vs an HTTP error from a reachable server
    $BeginHttpStatus = $null
    $BeginWebException = $null
    # Unwrap to find the WebException
    if ($_.Exception -is [System.Net.WebException]) {
        $BeginWebException = $_.Exception
    } elseif ($_.Exception.InnerException -is [System.Net.WebException]) {
        $BeginWebException = $_.Exception.InnerException
    }
    if ($BeginWebException -and $BeginWebException.Response) {
        $BeginHttpStatus = [int]$BeginWebException.Response.StatusCode
    }
    # Treat as connection failure if no HTTP status was obtained
    $IsConnectionFailure = ($null -eq $BeginHttpStatus -or $BeginHttpStatus -eq 0)
    # Also treat WebException transport-level statuses as connection failures
    if (-not $IsConnectionFailure -and $BeginWebException) {
        $WeStatus = $BeginWebException.Status
        if ($WeStatus -eq [System.Net.WebExceptionStatus]::ConnectFailure -or
            $WeStatus -eq [System.Net.WebExceptionStatus]::NameResolutionFailure -or
            $WeStatus -eq [System.Net.WebExceptionStatus]::Timeout -or
            $WeStatus -eq [System.Net.WebExceptionStatus]::ConnectionClosed -or
            $WeStatus -eq [System.Net.WebExceptionStatus]::SendFailure) {
            $IsConnectionFailure = $True
        }
    }
    if ($IsConnectionFailure) {
        # Connection failure -- retry once after 2s
        Write-Log "Begin marker failed (connection error), retrying in 2 seconds..." -Level "Warning"
        Start-Sleep -Seconds 2
        try {
            $ScanId = Send-CollectionMarker -MarkerType "begin" -Fatal
            $BeginMarkerSuccess = $True
        } catch {
            Write-Log "Cannot connect to Thunderstorm server at $BaseUrl : $_" -Level "Error"
            exit 2
        }
    } else {
        # Server is reachable but returned an HTTP error -- log warning and continue without scan_id
        Write-Log "Begin marker returned HTTP $BeginHttpStatus -- continuing without scan_id" -Level "Warning"
    }
}
if ($ScanId) {
    Write-Log "Collection scan_id: $ScanId"
    if ($Url.Contains("?")) {
        $Url = "$Url&scan_id=$([uri]::EscapeDataString($ScanId))"
    } else {
        $Url = "$Url`?scan_id=$([uri]::EscapeDataString($ScanId))"
    }
}



$EnumErrors = @()
try {
    $FileList = @(Get-ChildItem -Path $Folder -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable EnumErrors | Where-Object { -not $_.PSIsContainer })
    # Set total file count from actual enumeration for accurate progress reporting
    if ($ShowProgress) {
        $TotalFiles = $FileList.Count
    }
    if ($EnumErrors.Count -gt 0) {
        foreach ($enumErr in $EnumErrors) {
            Write-Log "Traversal error: $($enumErr.Exception.Message)" -Level "Warning"
        }
        Write-Log "Directory traversal encountered $($EnumErrors.Count) error(s) - some paths may not have been scanned" -Level "Warning"
        $FilesFailed += $EnumErrors.Count
    }

    foreach ($CurrentFile in $FileList) {
        # Check for interruption (from C# SIGINT handler or direct flag)
        $SigIntFired = $False
        try { $SigIntFired = [SigIntHandler]::Interrupted } catch {}
        if ($SigIntFired -or $global:Interrupted) {
            $global:Interrupted = $True
            Write-Log "Interrupted by user signal" -Level "Warning"
            break
        }

        # -------------------------------------------------------------
        # Filter ------------------------------------------------------
        $FilesScanned++
        # Progress reporting
        if ($ShowProgress -and $TotalFiles -gt 0) {
            $Pct = [math]::Round(($FilesScanned / $TotalFiles) * 100, 0)
            Write-Host -NoNewline "`r[${FilesScanned}/${TotalFiles}] ${Pct}%   "
        }


        # Size Check
        if ( ( $CurrentFile.Length / 1MB ) -gt $($MaxSize) ) {
            Write-Log "$CurrentFile skipped due to size filter" -Level "Debug"
            $FilesSkipped++
            continue
        }
        # Age Check (file passes if either created or modified within MaxAge days)
        if ( $MaxAge -gt 0 ) {
            $AgeThreshold = (Get-Date).AddDays(-$MaxAge)
            $NewestTime = if ($CurrentFile.CreationTime -gt $CurrentFile.LastWriteTime) { $CurrentFile.CreationTime } else { $CurrentFile.LastWriteTime }
            if ( $NewestTime -lt $AgeThreshold ) {
                Write-Log "$CurrentFile skipped due to age filter" -Level "Debug"
                $FilesSkipped++
                continue
            }
        }

        # Extensions Check (case-insensitive)
        if ( $ActiveExtensions.Length -gt 0 ) {
            $FileExt = $CurrentFile.Extension.ToLowerInvariant()
            if ( -not ($ActiveExtensions -contains $FileExt) ) {
                Write-Log "$CurrentFile skipped due to extension filter" -Level "Debug"
                $FilesSkipped++
                continue
            }
        }


        # -------------------------------------------------------------
        # Submission --------------------------------------------------

        Write-Log "Processing $($CurrentFile.FullName) ..." -Level "Debug"
        $boundary = "----ThunderstormBoundary" + [System.Guid]::NewGuid().ToString("N")

        $CRLF = "`r`n"
        $SafeFileName = $CurrentFile.FullName -replace '[\r\n]','' -replace '"','\"'
        $SafeSourcePath = $CurrentFile.FullName -replace '[\r\n]','' -replace '"','\"'
        $SafeHostname = $Hostname -replace '[\r\n]','' -replace '"','\"'
        $SafeSource = $Source -replace '[\r\n]','' -replace '"','\"'

        # Metadata parts: hostname and source_path
        $metadataText = "--$boundary$CRLF" +
            "Content-Disposition: form-data; name=`"hostname`"$CRLF$CRLF$SafeHostname$CRLF" +
            "--$boundary$CRLF" +
            "Content-Disposition: form-data; name=`"source`"$CRLF$CRLF$SafeSource$CRLF" +
            "--$boundary$CRLF" +
            "Content-Disposition: form-data; name=`"source_path`"$CRLF$CRLF$SafeSourcePath$CRLF"

        # File part
        $headerText = "--$boundary$CRLF" +
            "Content-Disposition: form-data; name=`"file`"; filename=`"$SafeFileName`"$CRLF" +
            "Content-Type: application/octet-stream$CRLF$CRLF"

        $footerText = "$CRLF--$boundary--$CRLF"

        $metadataBytes = [System.Text.Encoding]::UTF8.GetBytes($metadataText)
        $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($headerText)
        $footerBytes = [System.Text.Encoding]::UTF8.GetBytes($footerText)

        # Pre-check file readability before attempting upload
        $fileLength = 0
        try {
            $fileLength = $CurrentFile.Length
            # Quick open/close to verify readability
            $testStream = [System.IO.File]::OpenRead($CurrentFile.FullName)
            $testStream.Dispose()
        } catch {
            Write-Log "Read Error: $_" -Level "Error"
            $FilesFailed++
            continue
        }

        # Submitting the request
        $StatusCode = 0
        $Retries = 0
        $MaxRetries = 3
        $Max503Retries = 10
        $Retries503 = 0

        while ( $StatusCode -lt 200 -or $StatusCode -ge 300 ) {
            $fileStream = $null
            $requestStream = $null
            try {
                Write-Log "Submitting to Thunderstorm server: $($CurrentFile.FullName) ..." -Level "Info"

                # Stream the multipart body directly to the request to avoid double-buffering
                $ContentLength = $metadataBytes.Length + $headerBytes.Length + $fileLength + $footerBytes.Length
                $WebRequest = [System.Net.HttpWebRequest]::Create($Url)
                $WebRequest.Method = "POST"
                $WebRequest.ContentType = "multipart/form-data; boundary=$boundary"
                $WebRequest.ContentLength = $ContentLength
                $WebRequest.Timeout = 300000
                $WebRequest.AllowWriteStreamBuffering = $False

                $requestStream = $WebRequest.GetRequestStream()
                $requestStream.Write($metadataBytes, 0, $metadataBytes.Length)
                $requestStream.Write($headerBytes, 0, $headerBytes.Length)

                # Stream file content directly to request stream
                $fileStream = [System.IO.File]::OpenRead($CurrentFile.FullName)
                $copyBuffer = New-Object byte[] 81920
                $bytesRead = 0
                while (($bytesRead = $fileStream.Read($copyBuffer, 0, $copyBuffer.Length)) -gt 0) {
                    $requestStream.Write($copyBuffer, 0, $bytesRead)
                }
                $fileStream.Dispose()
                $fileStream = $null

                $requestStream.Write($footerBytes, 0, $footerBytes.Length)
                $requestStream.Dispose()
                $requestStream = $null

                $WebResponse = $WebRequest.GetResponse()
                $StatusCode = [int]$WebResponse.StatusCode
                $WebResponse.Close()
                $FilesSubmitted++
            }
            catch {
                if ($fileStream) { try { $fileStream.Dispose() } catch {} }
                if ($requestStream) { try { $requestStream.Dispose() } catch {} }

                $ErrorResponse = $null
                $StatusCode = 0
                if ($_.Exception -is [System.Net.WebException]) {
                    $ErrorResponse = $_.Exception.Response
                    if ($ErrorResponse) {
                        $StatusCode = [int]$ErrorResponse.StatusCode
                    }
                } elseif ($_.Exception.InnerException -is [System.Net.WebException]) {
                    $ErrorResponse = $_.Exception.InnerException.Response
                    if ($ErrorResponse) {
                        $StatusCode = [int]$ErrorResponse.StatusCode
                    }
                }

                if ( $StatusCode -eq 503 ) {
                    $Retries503 = $Retries503 + 1
                    # Reset non-503 retry counter since server is reachable (just busy)
                    $Retries = 0
                    if ( $Retries503 -ge $Max503Retries ) {
                        $FilesFailed++
                        Write-Log "503: Server still busy after $Max503Retries retries - giving up on $($CurrentFile.FullName)" -Level "Warning"
                        break
                    }
                    $WaitSecs = 3
                    try {
                        $RetryAfterVal = $null
                        if ($ErrorResponse) {
                            $RetryAfterVal = $ErrorResponse.Headers['Retry-After']
                        }
                        if ($RetryAfterVal) {
                            $WaitSecs = [int]$RetryAfterVal
                            if ($WaitSecs -lt 1) { $WaitSecs = 3 }
                            if ($WaitSecs -gt 300) { $WaitSecs = 300 }
                        }
                    } catch {
                        $WaitSecs = 3
                    }

                    Write-Log "503: Server seems busy - retrying in $($WaitSecs) seconds ($Retries503/$Max503Retries)"
                    Start-Sleep -Seconds $($WaitSecs)
                } elseif ( $StatusCode -eq 0 ) {
                    # Connection/transport error (no HTTP response)
                    $Retries = $Retries + 1
                    if ( $Retries -gt $MaxRetries ) {
                        $FilesFailed++
                        Write-Log "Connection error: giving up on $($CurrentFile.FullName) after $MaxRetries retries - $_" -Level "Warning"
                        break
                    }
                    $SleepTime = [Math]::Pow(2, $Retries)
                    Write-Log "Connection error - retrying in $SleepTime seconds ($Retries/$MaxRetries): $_"
                    Start-Sleep -Seconds $($SleepTime)
                } else {
                    $Retries = $Retries + 1
                    if ( $Retries -gt $MaxRetries ) {
                        $FilesFailed++
                        Write-Log "$($StatusCode): Server still has problems - giving up on $($CurrentFile.FullName)" -Level "Warning"
                        break
                    }

                    $SleepTime = [Math]::Pow(2, $Retries)

                    Write-Log "$($StatusCode): Server has problems - retrying in $SleepTime seconds"
                    Start-Sleep -Seconds $($SleepTime)
                }
            }
        }
     }
} catch {
    Write-Log "Fatal error during Thunderstorm Collection: $_" -Level "Error"
    # Send interrupted marker on fatal error
    try {
        Send-CollectionMarker -MarkerType "interrupted" -ScanId $ScanId -Stats @{
            scanned   = $FilesScanned
            submitted = $FilesSubmitted
            skipped   = $FilesSkipped
            failed    = $FilesFailed
        } | Out-Null
    } catch {
        Write-Log "Failed to send interrupted marker: $_" -Level "Warning"
    }
    exit 2
}



# ---------------------------------------------------------------------
# End -----------------------------------------------------------------
# ---------------------------------------------------------------------
# Clear progress line if active
if ($ShowProgress -and $TotalFiles -gt 0) {
    Write-Host "`r$(' ' * 40)`r" -NoNewline
}
$ElapsedTime = $(get-date) - $StartTime

$TotalTime = "{0:HH:mm:ss}" -f ([datetime]$elapsedTime.Ticks)
Write-Log "Scan took $($TotalTime) to complete" -Level "Info"
Write-Log "Results: scanned=$FilesScanned submitted=$FilesSubmitted skipped=$FilesSkipped failed=$FilesFailed"

# Send collection marker with stats
$EndStats = @{
    scanned          = $FilesScanned
    submitted        = $FilesSubmitted
    skipped          = $FilesSkipped
    failed           = $FilesFailed
    elapsed_seconds  = [int]$ElapsedTime.TotalSeconds
}

$SigIntFired = $False
try { $SigIntFired = [SigIntHandler]::Interrupted } catch {}
if ($SigIntFired -or $global:Interrupted) {
    $global:Interrupted = $True
    Send-CollectionMarker -MarkerType "interrupted" -ScanId $ScanId -Stats $EndStats | Out-Null
    Write-Log "Collection was interrupted by user" -Level "Warning"
    exit 1
} else {

    Send-CollectionMarker -MarkerType "end" -ScanId $ScanId -Stats $EndStats | Out-Null
}

# Exit with appropriate code
if ($FilesFailed -gt 0) {
    exit 1
} else {
    exit 0
}
