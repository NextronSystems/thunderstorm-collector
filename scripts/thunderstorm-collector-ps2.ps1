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
        Select files based on the number of days in which the file has been created or modified (default: 14 days)
    .PARAMETER MaxSize
        Maximum file size in MegaBytes for submission (default: 2MB / 2048KB)
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
        [string]$Source=$env:COMPUTERNAME,

    [Parameter(HelpMessage='Folder to process (default: C:\)')]
        [ValidateNotNullOrEmpty()]
        [Alias('F')]
        [string]$Folder = "C:\",

    [Parameter(HelpMessage='Select files based on days since last modification (default: 14 days)')]
        [ValidateNotNullOrEmpty()]
        [Alias('MA')]
        [int]$MaxAge = 14,

    [Parameter(HelpMessage='Maximum file size in MegaBytes (default: 2MB / 2048KB)')]
        [ValidateNotNullOrEmpty()]
        [Alias('MS')]
        [int]$MaxSize = 2,

    [Parameter(HelpMessage='Extensions to select for submission')]
        [ValidateNotNullOrEmpty()]
        [Alias('E')]
        [string[]]$Extensions,

    [Parameter(HelpMessage='Submit all file extensions (overrides -Extensions)')]
        [switch]$AllExtensions = $False,

    [Parameter(HelpMessage='Use HTTPS instead of HTTP')]
        [Alias('SSL')]
        [switch]$UseSSL,

    [Parameter(HelpMessage='Path to custom CA certificate bundle for TLS verification')]
        [string]$CACert,

    [Parameter(HelpMessage='Skip TLS certificate verification')]
        [Alias('k')]
        [switch]$Insecure,

    [Parameter(HelpMessage='Force enable progress reporting')]
        [switch]$Progress,

    [Parameter(HelpMessage='Force disable progress reporting')]
        [switch]$NoProgress,

    [Parameter(HelpMessage='Enable debug output')]
        [Alias('D')]
        [switch]$Debugging
)

# Fixing Certain Platform Environments --------------------------------
$AutoDetectPlatform = ""
$OutputPath = $PSScriptRoot
# When run via 'powershell -Command', $PSScriptRoot is empty; fall back to TEMP
if ( -not $OutputPath -or $OutputPath -eq "" ) {
    $OutputPath = $env:TEMP
}
$global:NoLog = $false

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
    [int]$MaxSize = 2
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

# Progress reporting: auto-detect TTY unless overridden
$ShowProgress = $false
if ($Progress) {
    $ShowProgress = $true
} elseif ($NoProgress) {
    $ShowProgress = $false
} else {
    # Auto-detect: check if stdout is interactive (TTY)
    try {
        # First check if the environment is interactive at all
        if (-not [Environment]::UserInteractive) {
            $ShowProgress = $false
        } else {
            # Check if output is redirected (.NET 4.5+ only)
            $isRedirected = $false
            try {
                $isRedirected = [Console]::IsOutputRedirected
            } catch {
                # Property not available in older .NET; fall back to host check
                $isRedirected = $false
            }
            if ($isRedirected) {
                $ShowProgress = $false
            } else {
                # Verify we have a real console window (not a non-interactive host)
                $hostName = $Host.Name
                if ($hostName -eq 'ConsoleHost') {
                    $ShowProgress = [Console]::WindowWidth -gt 0
                } else {
                    # ISE, remoting, custom hosts -- no carriage-return progress
                    $ShowProgress = $false
                }
            }
        }
    } catch {
        $ShowProgress = $false
    }
}

# Show Help -----------------------------------------------------------
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
            [string]$LogFile = "thunderstorm-collector.log",

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
        Write-Warning "$($Indicator) $($Entry)"
    } elseif ( $Level -eq "Error" ) {
        [Console]::Error.WriteLine("$($Indicator) $($Entry)")
    } elseif ( $Level -eq "Debug" -and $Debug -eq $False ) {
        return
    } else {
        Write-Host "$($Indicator) $($Entry)"
    }

    # Log File
    if ( $global:NoLog -eq $False ) {
        try {
            $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
            $LogFilePath = $LogFile
            if ($OutputPath -and (Test-Path $OutputPath -PathType Container)) {
                $LogFilePath = Join-Path $OutputPath $LogFile
            }
            "$ts $($env:COMPUTERNAME): $Entry" | Out-File -FilePath $LogFilePath -Append
        } catch {
            # Logging failure should not affect collection
        }
    }
}

# Submit-File: uploads a file using System.Net.HttpWebRequest (PS 2.0 compatible)
# Streams file content directly from disk to avoid loading entire file into memory.
# Returns the HTTP status code (int) or 0 on connection failure.
function Submit-File {
    param(
        [Parameter(Mandatory=$True)][string]$Url,
        [Parameter(Mandatory=$True)][string]$FilePath,
        [Parameter(Mandatory=$True)][long]$FileSize
    )

    $boundary = [System.Guid]::NewGuid().ToString()
    $CRLF = "`r`n"

    # Build multipart metadata fields for hostname, source, and filename
    # Keep full client path in multipart filename for parity with other collectors.
    $FileName = $FilePath
    $EncodedFilename = [uri]::EscapeDataString($FileName)

    # File part header and footer
    # Use RFC 5987 encoding for filename to safely handle special characters
    # Build ASCII-safe fallback filename: replace non-ASCII and control chars with underscores
    $SafeAsciiFilename = ""
    foreach ($ch in $FileName.ToCharArray()) {
        $code = [int]$ch
        if ($code -ge 0x20 -and $code -le 0x7E -and $ch -ne '"' -and $ch -ne '\') {
            $SafeAsciiFilename += $ch
        } else {
            $SafeAsciiFilename += '_'
        }
    }
    if ($SafeAsciiFilename -eq '') { $SafeAsciiFilename = 'upload' }
    $fileHeaderText = "--$boundary$CRLF" +
        "Content-Disposition: form-data; name=`"file`"; filename=`"$SafeAsciiFilename`"; filename*=UTF-8''$EncodedFilename$CRLF" +
        "Content-Type: application/octet-stream$CRLF$CRLF"
    $footerText = "$CRLF--$boundary--$CRLF"

    $fileHeaderBytes = [System.Text.Encoding]::UTF8.GetBytes($fileHeaderText)
    $footerBytes = [System.Text.Encoding]::UTF8.GetBytes($footerText)

    try {
        # Open the file first to get authoritative size and fail fast if locked/missing
        $fileStream = $null
        try {
            $fileStream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        } catch {
            Write-Log "Cannot open file: $FilePath - $($_.Exception.Message)" -Level "Error"
            return -1
        }

        $actualFileSize = $fileStream.Length
        $contentLength = $fileHeaderBytes.Length + $actualFileSize + $footerBytes.Length

        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = "POST"
        $request.ContentType = "multipart/form-data; boundary=$boundary"
        $request.ContentLength = $contentLength
        $request.Timeout = 120000  # 120 seconds
        $request.AllowAutoRedirect = $true
        $request.AllowWriteStreamBuffering = $false
        $request.Headers.Add("X-Hostname", $env:COMPUTERNAME)

        # Stream metadata and file content directly into the request stream
        $stream = $null
        try {
            $stream = $request.GetRequestStream()
            
            $stream.Write($fileHeaderBytes, 0, $fileHeaderBytes.Length)

            try {
                $buffer = New-Object byte[] 65536
                $totalBytesWritten = [long]0
                $bytesRead = 0
                do {
                    $bytesRead = $fileStream.Read($buffer, 0, $buffer.Length)
                    if ($bytesRead -gt 0) {
                        # Clamp to declared size to prevent writing more than ContentLength
                        $remaining = $actualFileSize - $totalBytesWritten
                        if ($bytesRead -gt $remaining) { $bytesRead = [int]$remaining }
                        if ($bytesRead -le 0) { break }
                        $stream.Write($buffer, 0, $bytesRead)
                        $totalBytesWritten += $bytesRead
                    }
                } while ($bytesRead -gt 0 -and $totalBytesWritten -lt $actualFileSize)
            } finally {
                if ($fileStream -ne $null) { $fileStream.Close() }
            }

            $stream.Write($footerBytes, 0, $footerBytes.Length)
        } finally {
            if ($stream -ne $null) { $stream.Close() }
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
$global:StartTime = Get-Date

Write-Log "Started Thunderstorm Collector (PS2) with PowerShell v$($PSVersionTable.PSVersion)"

# ---------------------------------------------------------------------
# Evaluation ----------------------------------------------------------
# ---------------------------------------------------------------------

# Output Info on Auto-Detection
if ( $AutoDetectPlatform -ne "" ) {
    Write-Log "Auto Detect Platform: $($AutoDetectPlatform)"
    Write-Log "Note: Some automatic changes have been applied"
}

# Validate folder exists
if (-not (Test-Path -Path $Folder -PathType Container)) {
    Write-Log "Folder not found: $Folder" -Level "Error"
    exit 2
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
    # Reject conflicting TLS options
    if ( $Insecure -and $CACert ) {
        Write-Log "Cannot use both -Insecure and -CACert at the same time" -Level "Error"
        exit 2
    }
    # Handle --insecure: skip certificate validation
    if ( $Insecure ) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        Write-Log "TLS certificate verification DISABLED (insecure mode)" -Level "Warning"
    }
    # Handle --ca-cert: custom CA bundle (single cert or PEM bundle)
    if ( $CACert ) {
        if ( -not (Test-Path $CACert) ) {
            Write-Log "CA certificate file not found: $CACert" -Level "Error"
            exit 2
        }
        try {
            # Try to load as a PEM bundle containing multiple certificates
            $caCerts = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
            $pemContent = [System.IO.File]::ReadAllText($CACert)
            $pemPattern = '-----BEGIN CERTIFICATE-----[^-]+-----END CERTIFICATE-----'
            $pemMatches = [regex]::Matches($pemContent, $pemPattern)
            if ($pemMatches.Count -gt 0) {
                foreach ($pemMatch in $pemMatches) {
                    $certText = $pemMatch.Value -replace '-----BEGIN CERTIFICATE-----', '' -replace '-----END CERTIFICATE-----', ''
                    $certText = $certText.Trim()
                    $certBytes = [Convert]::FromBase64String($certText)
                    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,$certBytes)
                    $caCerts.Add($cert) | Out-Null
                }
                Write-Log "Loaded $($caCerts.Count) certificate(s) from CA bundle: $CACert"
            } else {
                # Try loading as a single DER/PFX certificate file
                $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CACert)
                $caCerts.Add($cert) | Out-Null
                Write-Log "Loaded single CA certificate: $CACert"
            }
            if ($caCerts.Count -eq 0) {
                Write-Log "No certificates found in CA file: $CACert" -Level "Error"
                exit 2
            }
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
                param($sender, $certificate, $chain, $sslPolicyErrors)
                # Build a chain using the provided CA certificates
                $chainObj = New-Object System.Security.Cryptography.X509Certificates.X509Chain
                foreach ($ca in $caCerts) {
                    $chainObj.ChainPolicy.ExtraStore.Add($ca) | Out-Null
                }
                $chainObj.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
                $chainObj.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
                $valid = $chainObj.Build($certificate)
                if (-not $valid) { return $false }
                # Verify that the chain root is one of the supplied CA certificates
                $chainRoot = $chainObj.ChainElements[$chainObj.ChainElements.Count - 1].Certificate
                $rootThumbprint = $chainRoot.Thumbprint
                $anchored = $false
                foreach ($ca in $caCerts) {
                    if ($ca.Thumbprint -eq $rootThumbprint) {
                        $anchored = $true
                        break
                    }
                }
                return $anchored
            }
        } catch {
            Write-Log "Failed to load CA certificate: $_" -Level "Error"
            exit 2
        }
    }
    Write-Log "HTTPS mode enabled"
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

# PS 2.0 compatible JSON escape helper -- single-pass over original string
function Escape-JsonString {
    param([string]$s)
    if ($s -eq $null) { return "" }
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $s.ToCharArray()) {
        $code = [int]$c
        switch ($c) {
            '"'  { $sb.Append('\"') | Out-Null }
            '\'  { $sb.Append('\\') | Out-Null }
            "`r" { $sb.Append('\r') | Out-Null }
            "`n" { $sb.Append('\n') | Out-Null }
            "`t" { $sb.Append('\t') | Out-Null }
            default {
                if ($code -eq 0x08) {
                    $sb.Append('\b') | Out-Null
                } elseif ($code -eq 0x0C) {
                    $sb.Append('\f') | Out-Null
                } elseif ($code -lt 0x20) {
                    $sb.Append(('\u{0:X4}' -f $code)) | Out-Null
                } else {
                    $sb.Append($c) | Out-Null
                }
            }
        }
    }
    return $sb.ToString()
}

# PS 2.0 compatible: extract a JSON string value by key (handles escaped characters)
function Get-JsonValue {
    param([string]$Json, [string]$Key)
    $pattern = '"' + [regex]::Escape($Key) + '"\s*:\s*"((?:\\.|[^"\\])*)"'
    if ($Json -match $pattern) {
        # Unescape JSON string escapes
        # Order matters: \\ must be replaced last to avoid corrupting sequences like \\n
        # We use a placeholder to avoid double-replacement issues
        $val = $matches[1]
        $val = $val.Replace('\\', "`0BACKSLASH`0")
        $val = $val.Replace('\"', '"')
        $val = $val.Replace('\/', '/')
        $val = $val.Replace('\n', "`n")
        $val = $val.Replace('\r', "`r")
        $val = $val.Replace('\t', "`t")
        $val = $val.Replace('\b', "`b")
        $val = $val.Replace('\f', [string][char]0x0C)
        $val = $val.Replace("`0BACKSLASH`0", '\')
        # Unescape \uXXXX sequences (including surrogate pairs)
        $val = [regex]::Replace($val, '\\u([0-9a-fA-F]{4})(?:\\u([0-9a-fA-F]{4}))?', {
            param($m)
            $cp1 = [int]('0x' + $m.Groups[1].Value)
            if ($m.Groups[2].Success) {
                $cp2 = [int]('0x' + $m.Groups[2].Value)
                # Check if this is a surrogate pair (high surrogate + low surrogate)
                if ($cp1 -ge 0xD800 -and $cp1 -le 0xDBFF -and $cp2 -ge 0xDC00 -and $cp2 -le 0xDFFF) {
                    return [char]::ConvertFromUtf32((($cp1 - 0xD800) * 0x400) + ($cp2 - 0xDC00) + 0x10000)
                } else {
                    # Not a surrogate pair, decode independently (second \uXXXX will be re-matched)
                    return [char]$cp1 + [char]$cp2
                }
            } else {
                # Single code unit - reject lone surrogates, decode normally
                if ($cp1 -ge 0xD800 -and $cp1 -le 0xDFFF) {
                    return $m.Value  # Leave lone surrogate escaped
                }
                return [char]$cp1
            }
        })
        return $val
    }
    return ""
}

function Send-CollectionMarker {
    param(
        [string]$MarkerType,
        [string]$ScanId = "",
        [hashtable]$Stats = $null
    )
    $MarkerUrl = "$BaseUrl/api/collection"
    $SourceVal = $Source
    if (-not $SourceVal) { $SourceVal = $env:COMPUTERNAME }
    $Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    # Build JSON manually for PS 2.0 compatibility
    $JsonParts = New-Object System.Collections.ArrayList
    $JsonParts.Add(('"type":"{0}"' -f (Escape-JsonString $MarkerType))) | Out-Null
    $JsonParts.Add(('"source":"{0}"' -f (Escape-JsonString $SourceVal))) | Out-Null
    $JsonParts.Add('"collector":"powershell2/1.0"') | Out-Null
    $JsonParts.Add(('"timestamp":"{0}"' -f (Escape-JsonString $Timestamp))) | Out-Null
    if ($ScanId) {
        $JsonParts.Add(('"scan_id":"{0}"' -f (Escape-JsonString $ScanId))) | Out-Null
    }
    if ($Stats) {
        $StatParts = New-Object System.Collections.ArrayList
        foreach ($key in $Stats.Keys) {
            $val = $Stats[$key]
            if ($val -is [int] -or $val -is [long] -or $val -is [double]) {
                $StatParts.Add(('"' + (Escape-JsonString $key) + '":' + $val.ToString())) | Out-Null
            } else {
                $StatParts.Add(('"' + (Escape-JsonString $key) + '":"' + (Escape-JsonString ([string]$val)) + '"')) | Out-Null
            }
        }
        $JsonParts.Add(('"stats":{{{0}}}' -f ($StatParts -join ','))) | Out-Null
    }
    $JsonBody = '{' + ($JsonParts -join ',') + '}'

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
        $httpStatus = [int]$Resp.StatusCode
        $Reader = New-Object System.IO.StreamReader($Resp.GetResponseStream())
        $RespBody = $Reader.ReadToEnd()
        $Reader.Close()
        $Resp.Close()

        # Validate HTTP success first, then attempt scan_id extraction
        if ($httpStatus -lt 200 -or $httpStatus -ge 300) {
            Write-Log "Collection marker '$MarkerType' returned unexpected HTTP $httpStatus" -Level "Error"
            Write-Log "Response body: $RespBody" -Level "Debug"
            return ""
        }

        $scanIdResult = Get-JsonValue -Json $RespBody -Key "scan_id"
        if (-not $scanIdResult) {
            Write-Log "Collection marker '$MarkerType' HTTP $httpStatus OK but no scan_id found in response" -Level "Warning"
            Write-Log "Response body: $RespBody" -Level "Debug"
            # Return a sentinel value to distinguish "HTTP success but no scan_id" from total failure
            # This allows the caller to know the server was reached successfully
            return "__NO_SCAN_ID__"
        }
        return $scanIdResult
    } catch [System.Net.WebException] {
        $ex = $_.Exception
        if ($ex.Response -ne $null) {
            $errCode = [int]$ex.Response.StatusCode
            # 404 or 501 means the server doesn't support collection markers -- continue without scan_id
            if ($errCode -eq 404 -or $errCode -eq 501) {
                Write-Log "Collection marker '$MarkerType' not supported (HTTP $errCode) -- server does not implement /api/collection" -Level "Debug"
                return "__MARKER_UNSUPPORTED__"
            }
            Write-Log "Collection marker '$MarkerType' failed with HTTP $errCode" -Level "Error"
            try {
                $errReader = New-Object System.IO.StreamReader($ex.Response.GetResponseStream())
                $errBody = $errReader.ReadToEnd()
                $errReader.Close()
                Write-Log "Error response body: $errBody" -Level "Debug"
            } catch {}
            $ex.Response.Close()
        } else {
            Write-Log "Collection marker '$MarkerType' failed: $($ex.Message)" -Level "Error"
        }
        return ""
    } catch {
        Write-Log "Collection marker '$MarkerType' failed: $_" -Level "Error"
        return ""
    }
}

# ---------------------------------------------------------------------
# Run THOR Thunderstorm Collector -------------------------------------
# ---------------------------------------------------------------------

$global:SubmittedCount = 0
$global:ErrorCount = 0
$global:ScannedCount = 0
$global:SkippedCount = 0
$global:MarkersSupported = $true

# Send collection begin marker with single retry on failure
$global:ScanId = Send-CollectionMarker -MarkerType "begin"
if ($global:ScanId -eq "__MARKER_UNSUPPORTED__") {
    $global:MarkersSupported = $false
    $global:ScanId = ""
} elseif (-not $global:ScanId) {
    Write-Log "Begin marker failed - retrying in 2 seconds..." -Level "Warning"
    Start-Sleep -Seconds 2
    $global:ScanId = Send-CollectionMarker -MarkerType "begin"
    if ($global:ScanId -eq "__MARKER_UNSUPPORTED__") {
        $global:MarkersSupported = $false
        $global:ScanId = ""
    }
}
if (-not $global:MarkersSupported) {
    Write-Log "Collection marker endpoint unavailable -- continuing without markers" -Level "Debug"
} elseif (-not $global:ScanId) {
    Write-Log "Could not connect to Thunderstorm server at $BaseUrl - exiting" -Level "Error"
    exit 2
}
# Handle case where server responded OK but did not return a scan_id
if ($global:ScanId -eq "__NO_SCAN_ID__") {
    Write-Log "Begin marker succeeded but server did not return a scan_id -- continuing without scan_id" -Level "Warning"
    $global:ScanId = ""
}
if ($global:ScanId) {
    Write-Log "Collection scan_id: $($global:ScanId)"
    # First parameter uses '?' so subsequent ones use '&'
    if ($SourceParam -ne "") {
        $Url = "$Url&scan_id=$([uri]::EscapeDataString($global:ScanId))"
    } else {
        $Url = "$Url`?scan_id=$([uri]::EscapeDataString($global:ScanId))"
    }
}

# Signal handling: register handler to send interrupted marker on Ctrl+C / SIGTERM
$global:Interrupted = $false
$global:InterruptedMarkerSent = $false

# Function to send interrupted marker exactly once
function Send-InterruptedMarkerOnce {
    if (-not $global:MarkersSupported) { return }
    if ($global:InterruptedMarkerSent) { return }
    $global:InterruptedMarkerSent = $true
    $global:Interrupted = $true
    try {
        Write-Log "Sending interrupted collection marker" -Level "Warning"
        Send-CollectionMarker -MarkerType "interrupted" -ScanId $global:ScanId -Stats @{
            scanned         = $global:ScannedCount
            submitted       = $global:SubmittedCount
            skipped         = $global:SkippedCount
            failed          = $global:ErrorCount
            elapsed_seconds = [int]((Get-Date) - $global:StartTime).TotalSeconds
        } | Out-Null
    } catch {
        # Best-effort: don't let marker send failure prevent shutdown
    }
}


# PS 2.0 compatible Ctrl+C handling via Register-ObjectEvent on [Console]::CancelKeyPress
try {
    [Console]::TreatControlCAsInput = $false
    Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress -Action {
        $Event.SourceEventArgs.Cancel = $true
        $global:Interrupted = $true
        Send-InterruptedMarkerOnce
    } | Out-Null
    Write-Log "Registered Ctrl+C handler via Register-ObjectEvent" -Level "Debug"
} catch {
    # Fallback: try direct .NET event subscription
    try {
        $handler = [System.ConsoleCancelEventHandler]{
            param($sender, $e)
            $e.Cancel = $true
            $global:Interrupted = $true
            Send-InterruptedMarkerOnce
        }
        [Console]::add_CancelKeyPress($handler)
        Write-Log "Registered Ctrl+C handler via add_CancelKeyPress" -Level "Debug"
    } catch {
        Write-Log "Could not register Ctrl+C handler - interrupted markers on SIGINT not available" -Level "Debug"
    }
}

# Note: PowerShell.Exiting fires on ALL exits (including normal completion),
# so we do NOT register it -- it would incorrectly send an "interrupted" marker
# on clean runs. SIGTERM handling in PS 2.0 is a known limitation.

# trap statement for catchable terminating errors within the script scope
trap {
    Send-InterruptedMarkerOnce
    break
}

# PS 2 compatible file enumeration (Get-ChildItem -File not available in PS 2)
# Use incremental enumeration to avoid loading entire file tree into memory.
# When progress is enabled, do a lightweight count pass first; otherwise process incrementally.
Write-Log "Scanning files in $Folder ..."
$TotalFiles = 0
if ($ShowProgress) {
    Write-Log "Counting files for progress reporting ..."
    # Count pass: use Measure-Object to avoid storing all FileInfo objects
    $countResult = Get-ChildItem -Path $Folder -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | Measure-Object
    $TotalFiles = $countResult.Count
    Write-Log "Found $TotalFiles files to evaluate in $Folder"
}

# Use GetEnumerator on the pipeline output to allow 'break' without materializing all results
$fileEnumerator = $null
try {
    $fileEnumerator = (Get-ChildItem -Path $Folder -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer }).GetEnumerator()
} catch {
    # GetEnumerator may fail if result is $null (empty folder) or a single item
    $singleResult = Get-ChildItem -Path $Folder -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer }
    if ($singleResult -eq $null) {
        $fileEnumerator = @().GetEnumerator()
    } else {
        $fileEnumerator = @($singleResult).GetEnumerator()
    }
}

while ($fileEnumerator.MoveNext()) {
    $file = $fileEnumerator.Current

    # Check for interruption
    if ($global:Interrupted) {
        Write-Log "Interrupted by user signal" -Level "Warning"
        break
    }

    # -----------------------------------------------------------------
    # Filter ----------------------------------------------------------

    $global:ScannedCount++

    # -----------------------------------------------------------------
    # Progress --------------------------------------------------------
    if ($ShowProgress -and $TotalFiles -gt 0) {
        $Pct = [int](($global:ScannedCount / $TotalFiles) * 100)
        if ($Pct -gt 100) { $Pct = 100 }
        Write-Host -NoNewline ("`r[{0}/{1}] {2}%  " -f $global:ScannedCount, $TotalFiles, $Pct)
    } elseif ($ShowProgress) {
        # No total count available; show scanned count only
        Write-Host -NoNewline ("`r[{0}] scanning...  " -f $global:ScannedCount)
    }

    # Size Check
    if ( ( $file.Length / 1MB ) -gt $MaxSize ) {
        Write-Log "$($file.Name) skipped due to size filter" -Level "Debug"
        $global:SkippedCount++
        continue
    }

    # Age Check
    if ( $MaxAge -gt 0 ) {
        if ( $file.LastWriteTime -lt (Get-Date).AddDays(-$MaxAge) ) {
            Write-Log "$($file.Name) skipped due to age filter" -Level "Debug"
            $global:SkippedCount++
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
            $global:SkippedCount++
            continue
        }
    }

    # -----------------------------------------------------------------
    # Submission ------------------------------------------------------

    Write-Log "Processing $($file.FullName) ..." -Level "Debug"

    # Submit with retry logic (file is streamed from disk, not loaded into memory)
    $StatusCode = 0
    $Retries = 0
    $MaxRetries = 3
    $Max503Retries = 10
    $Retries503 = 0
    $script:LastRetryAfter = $null
    $FileSubmitted = $false
    $FileRetryStart = Get-Date
    $MaxRetrySeconds = 300  # Cap total retry time per file at 5 minutes

    while ( $StatusCode -lt 200 -or $StatusCode -ge 300 ) {
        if ($global:Interrupted) { break }
        # Check total elapsed retry time for this file
        if (((Get-Date) - $FileRetryStart).TotalSeconds -gt $MaxRetrySeconds) {
            Write-Log "Total retry time exceeded ${MaxRetrySeconds}s - giving up on $($file.FullName)" -Level "Error"
            $global:ErrorCount++
            break
        }

        Write-Log "Submitting to Thunderstorm server: $($file.FullName) ..." -Level "Info"
        $StatusCode = Submit-File -Url $Url -FilePath $file.FullName -FileSize $file.Length

        if ( $StatusCode -ge 200 -and $StatusCode -lt 300 ) {
            $global:SubmittedCount++
            $FileSubmitted = $true
            break
        }
        elseif ( $StatusCode -eq -1 ) {
            # File could not be opened (missing, locked, permission denied) -- no retry
            Write-Log "Skipping file due to open failure: $($file.FullName)" -Level "Error"
            $global:ErrorCount++
            break
        }
        elseif ( $StatusCode -eq 503 ) {
            $Retries503++
            if ( $Retries503 -ge $Max503Retries ) {
                Write-Log "503: Server still busy after $Max503Retries retries - giving up on $($file.FullName)" -Level "Warning"
                $global:ErrorCount++
                break
            }
            $WaitSecs = 3
            if ( $script:LastRetryAfter -ne $null ) {
                try {
                    $WaitSecs = [int]$script:LastRetryAfter
                    if ($WaitSecs -lt 1) { $WaitSecs = 3 }
                    if ($WaitSecs -gt 60) { $WaitSecs = 60 }
                } catch { $WaitSecs = 3 }
            }
            Write-Log "503: Server seems busy - retrying in $WaitSecs seconds ($Retries503/$Max503Retries)" -Level "Warning"
            Start-Sleep -Seconds $WaitSecs
        }
        elseif ( $StatusCode -eq 0 ) {
            # Connection failure
            $Retries++
            if ( $Retries -ge $MaxRetries ) {
                Write-Log "Connection failed after $MaxRetries retries - giving up on $($file.FullName)" -Level "Error"
                $global:ErrorCount++
                break
            }
            $SleepTime = [int](2 * [Math]::Pow(2, $Retries - 1))
            Write-Log "Connection failed - retrying in $SleepTime seconds ($Retries/$MaxRetries)" -Level "Warning"
            Start-Sleep -Seconds $SleepTime
        }
        else {
            $Retries++
            if ( $Retries -ge $MaxRetries ) {
                Write-Log "$($StatusCode): Server error after $MaxRetries retries - giving up on $($file.FullName)" -Level "Error"
                $global:ErrorCount++
                break
            }
            $SleepTime = [int](2 * [Math]::Pow(2, $Retries - 1))
            Write-Log "$($StatusCode): Server has problems - retrying in $SleepTime seconds ($Retries/$MaxRetries)" -Level "Warning"
            Start-Sleep -Seconds $SleepTime
        }
    }
}

# Clear progress line if it was shown
if ($ShowProgress -and $TotalFiles -gt 0) {
    Write-Host ("`r" + (" " * 60) + "`r") -NoNewline
}

# ---------------------------------------------------------------------
# End -----------------------------------------------------------------
# ---------------------------------------------------------------------
$ElapsedTime = (Get-Date) - $global:StartTime
$TotalTime = "{0:HH:mm:ss}" -f ([datetime]$ElapsedTime.Ticks)
Write-Log "Submitted $($global:SubmittedCount) files ($($global:ErrorCount) errors) in $TotalTime" -Level "Info"
Write-Log "Results: scanned=$($global:ScannedCount) submitted=$($global:SubmittedCount) skipped=$($global:SkippedCount) failed=$($global:ErrorCount)"

# Send collection end or interrupted marker with stats
# If interrupted marker was already sent by signal handler, skip duplicate
if (-not $global:MarkersSupported) {
    Write-Log "Collection marker endpoint unavailable - skipping end/interrupted marker" -Level "Debug"
} elseif ($global:InterruptedMarkerSent) {
    Write-Log "Interrupted marker already sent by signal handler - skipping end marker"
} else {
    $EndMarkerType = "end"
    if ($global:Interrupted) {
        $EndMarkerType = "interrupted"
        Write-Log "Sending interrupted collection marker" -Level "Warning"
    }
    Send-CollectionMarker -MarkerType $EndMarkerType -ScanId $global:ScanId -Stats @{
        scanned         = $global:ScannedCount
        submitted       = $global:SubmittedCount
        skipped         = $global:SkippedCount
        failed          = $global:ErrorCount
        elapsed_seconds = [int]$ElapsedTime.TotalSeconds
    } | Out-Null
}

# Exit codes: 0 = success, 1 = partial failure, 2 = fatal error
if ($global:ErrorCount -gt 0) {
    exit 1
} else {
    exit 0
}
