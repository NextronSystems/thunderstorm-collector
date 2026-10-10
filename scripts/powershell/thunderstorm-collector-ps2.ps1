#requires -Version 2.0
# THOR Thunderstorm Collector - Florian Roth / Nextron Systems
# USER CONFIGURATION -----------------------------------------------------------
# Edit the parameter defaults below or pass named parameters (higher priority).
# Example: .\thunderstorm-collector.ps1 -ThunderstormServer 192.0.2.10 -Folder C:\Samples -DryRun
# For PowerShell 2, use thunderstorm-collector-ps2.ps1 with the same parameters.
# DryRun makes no HTTP requests. Boolean defaults use $true / $false.
# To override an enabled switch, pass e.g. -DryRun:$false or -UseSSL:$false.
[CmdletBinding()]
param(
    # Required hostname/IP, e.g. "192.0.2.10"; no http://, port or API path.
    [Alias("TS")][string]$ThunderstormServer = "",
    # TCP port, 1..65535; independent of UseSSL.
    [Alias("TP")][int]$ThunderstormPort = 8080,
    # Recursive roots; broad default C:\. Example: @("C:\Samples", "D:\Evidence").
    # -Folder replaces the entire list. Links/junctions and cloud paths stay excluded.
    [Alias("F")][string[]]$Folder = @("C:\"),
    # Attribution label sent to the service; defaults to this computer's name.
    [Alias("S")][string]$Source = [Environment]::MachineName,
    # Days since last modification, 0..36500; 0 disables the age filter.
    [Alias("MA")][int]$MaxAge = 30,
    # MiB (1048576 bytes), 1..200; 2 = 2048 KiB. Exact limit included.
    [Alias("MS")][int]$MaxSize = 2,
    # Empty = DefaultExtensions below. Example: @(".exe", ".ps1").
    # A nonempty list REPLACES the defaults; AllExtensions disables suffix filtering.
    [string[]]$Extensions = @(),
    [switch]$AllExtensions = $false,
    # False = HTTP; True = HTTPS with certificate and hostname verification.
    [Alias("SSL")][switch]$UseSSL = $false,
    # Empty = system trust; otherwise CA certificate file for HTTPS.
    # Custom CA / Insecure need .NET 4.5+; unsupported runtimes fail explicitly.
    [string]$CACert = "",
    [Alias("k")][switch]$Insecure = $false, # Keep false; explicit TLS testing only.
    [switch]$DryRun = $false,             # True = preview only; False = real uploads.
    [switch]$Sync = $false,               # False = async submission; True = wait for analysis.
    # TOTAL upload attempts including the first, 1..10.
    [int]$Retries = 3,
    [Alias("D")][switch]$Debugging = $false, # Additional marker diagnostics.
    # Progress is off by default; -Progress enables counts. NoProgress wins.
    [switch]$Progress,
    [switch]$NoProgress
)
# Default suffix allowlist (case-insensitive). Files without these suffixes are skipped.
$DefaultExtensions = @(".asp",".vbs",".ps",".ps1",".rar",".tmp",".bas",".bat",".chm",".cmd",".com",".cpl",".crt",
        ".dll",".exe",".hta",".js",".lnk",".msc",".ocx",".pcd",".pif",".pot",".reg",".scr",".sct",".sys",".url",
        ".vb",".vbe",".wsc",".wsf",".wsh",".ct",".t",".input",".war",".jsp",".php",".aspx",".doc",".docx",
        ".pdf",".xls",".xlsx",".ppt",".pptx",".log",".dump",".pwd",".w",".txt",".conf",".cfg",".config",
        ".psd1",".psm1",".ps1xml",".clixml",".psc1",".pssc",".pl",".www",".rdp",".jar",".docm",".ace",
        ".job",".temp",".plg",".asm")
# Console logs include roots and limits. Use Start-Transcript before running the
# collector to retain a log on legacy PowerShell too; store it OUTSIDE scan roots.

# INTERNAL IMPLEMENTATION - no user settings below this line -------------------
$collectorId = "powershell2/0.3"
$ErrorActionPreference = "Stop"
$exitCode = 0
$started = $false
$scanId = ""
$stats = @{ scanned = 0; submitted = 0; failed = 0; skipped = 0; scan_errors = 0 }
$startTime = [DateTime]::UtcNow
$oldProtocol = [Net.ServicePointManager]::SecurityProtocol

# C# delegates do not depend on a PowerShell runspace on the HTTP/console threads.
$transportSource = @'
// Legacy APIs are intentional: the standalone files also target old .NET.
#pragma warning disable
using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
using System.Reflection;

namespace ThunderstormCollector {
    public class Reply {
        public int Code;
        public string Body = "";
        public string RetryAfter = "";
        public string Error = "";
    }
    public static class Transport {
        public static volatile bool Interrupted;
        private static HttpWebRequest active;
        private static X509Certificate2 ca;
        private static bool insecure;
        private static string tlsError = "";
        private static ConsoleCancelEventHandler handler;
        public static void Start() {
            Interrupted = false;
            handler = new ConsoleCancelEventHandler(Cancel);
            Console.CancelKeyPress += handler;
        }
        public static void Stop() {
            if (handler != null) Console.CancelKeyPress -= handler;
            handler = null;
            if (ca != null) ca.Reset();
            ca = null;
            insecure = false;
            active = null;
        }
        private static void Cancel(object sender, ConsoleCancelEventArgs args) {
            args.Cancel = true;
            Interrupted = true;
            HttpWebRequest request = active;
            if (request != null) request.Abort();
        }
        private static void Expire(object state) { ((HttpWebRequest)state).Abort(); }
        public static void Configure(string certificate, bool skipVerification) {
            ca = null;
            insecure = skipVerification;
            if (certificate.Length > 0 || skipVerification) {
                if (typeof(HttpWebRequest).GetProperty("ServerCertificateValidationCallback") == null)
                    throw new InvalidOperationException("Custom CA / Insecure require per-request TLS validation (.NET 4.5+). Use OS trust on older .NET.");
            }
            if (certificate.Length > 0) {
                byte[] bytes = File.ReadAllBytes(certificate);
                string text = Encoding.ASCII.GetString(bytes);
                Match match = Regex.Match(text, "-----BEGIN CERTIFICATE-----([^-]+)-----END CERTIFICATE-----");
                if (match.Success) bytes = Convert.FromBase64String(match.Groups[1].Value);
                ca = new X509Certificate2(bytes);
                if (ca.HasPrivateKey) throw new InvalidOperationException("Use a public CA certificate, not a private-key container.");
            }
        }
        private static bool Validate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors) {
            if (insecure) return true;
            // Keep the platform's hostname validation; never parse localized SAN text.
            if ((errors & (SslPolicyErrors.RemoteCertificateNameMismatch | SslPolicyErrors.RemoteCertificateNotAvailable)) != 0) {
                tlsError = "TLS policy error: " + errors;
                return false;
            }
            if (ca == null) return errors == SslPolicyErrors.None;
            X509Certificate2 leaf = new X509Certificate2(certificate);
            X509Chain custom = new X509Chain();
            try {
                custom.ChainPolicy.ExtraStore.Add(ca);
                custom.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
                custom.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
                custom.ChainPolicy.ApplicationPolicy.Add(new System.Security.Cryptography.Oid("1.3.6.1.5.5.7.3.1"));
                if (!custom.Build(leaf) || custom.ChainElements.Count == 0) {
                    tlsError = "TLS custom chain rejected.";
                    return false;
                }
                X509Certificate2 root = custom.ChainElements[custom.ChainElements.Count - 1].Certificate;
                if (root.Thumbprint != ca.Thumbprint) { tlsError = "TLS root differs from supplied CA."; return false; }
                foreach (X509ChainStatus status in custom.ChainStatus)
                    if (status.Status != X509ChainStatusFlags.NoError && status.Status != X509ChainStatusFlags.UntrustedRoot)
                        { tlsError = "TLS chain status: " + status.Status; return false; }
                return true;
            } catch (Exception error) { tlsError = "TLS chain validation: " + error.Message; return false; }
            finally { leaf.Reset(); custom.Reset(); }
        }
        public static byte[] Snapshot(string path, long limit, DateTime cutoff) {
            FileAttributes attributes = File.GetAttributes(path);
            if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
                throw new IOException("File became a link or directory.");
            DateTime stamp = File.GetLastWriteTimeUtc(path);
            if (stamp < cutoff) return null;
            using (FileStream file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                long length = file.Length;
                if (length > limit) return null;
                using (MemoryStream data = new MemoryStream()) {
                    byte[] buffer = new byte[65536];
                    int count;
                    while ((count = file.Read(buffer, 0, (int)Math.Min(buffer.Length, limit + 1 - data.Length))) > 0) {
                        data.Write(buffer, 0, count);
                        if (data.Length > limit || Interrupted) throw new IOException("File grew or collection was interrupted.");
                    }
                    if (data.Length != length || file.Length != length || File.GetLastWriteTimeUtc(path) != stamp ||
                        (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                        throw new IOException("File changed while being read.");
                    return data.ToArray();
                }
            }
        }
        public static byte[] Multipart(string path, string boundary, byte[] data) {
            string name = Regex.Replace(path, "[\\\\\";\\r\\n\\t\\x00-\\x1f\\x7f]", "_");
            byte[] head = Encoding.UTF8.GetBytes("--" + boundary + "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"" +
                name + "\"\r\nContent-Type: application/octet-stream\r\n\r\n");
            byte[] tail = Encoding.ASCII.GetBytes("\r\n--" + boundary + "--\r\n");
            using (MemoryStream body = new MemoryStream()) {
                body.Write(head, 0, head.Length);
                body.Write(data, 0, data.Length);
                body.Write(tail, 0, tail.Length);
                return body.ToArray();
            }
        }
        public static Reply Send(string url, string contentType, byte[] data, int timeout) {
            Reply result = new Reply();
            HttpWebRequest request = null;
            HttpWebResponse response = null;
            System.Threading.Timer deadline = null;
            try {
                tlsError = "";
                request = (HttpWebRequest)WebRequest.Create(url);
                request.Method = "POST";
                request.Proxy = null;
                request.AllowAutoRedirect = false;
                request.Timeout = timeout;
                request.ReadWriteTimeout = timeout;
                request.ContentType = contentType;
                request.ContentLength = data.Length;
                request.AllowWriteStreamBuffering = true;
                if (ca != null || insecure) {
                    PropertyInfo callback = typeof(HttpWebRequest).GetProperty("ServerCertificateValidationCallback");
                    callback.SetValue(request, new RemoteCertificateValidationCallback(Validate), null);
                }
                active = request;
                deadline = new System.Threading.Timer(new System.Threading.TimerCallback(Expire), request, timeout, System.Threading.Timeout.Infinite);
                using (Stream output = request.GetRequestStream()) output.Write(data, 0, data.Length);
                try { response = (HttpWebResponse)request.GetResponse(); }
                catch (WebException error) {
                    response = error.Response as HttpWebResponse;
                    if (response == null) throw;
                }
                result.Code = (int)response.StatusCode;
                result.RetryAfter = response.Headers["Retry-After"] ?? "";
                using (Stream input = response.GetResponseStream())
                using (MemoryStream body = new MemoryStream()) {
                    byte[] buffer = new byte[8192];
                    int count;
                    while ((count = input.Read(buffer, 0, buffer.Length)) > 0) {
                        body.Write(buffer, 0, count);
                        if (body.Length > 1048576) throw new IOException("Response exceeds 1 MiB.");
                    }
                    if (response.ContentLength >= 0 && body.Length != response.ContentLength)
                        throw new IOException("Incomplete HTTP response.");
                    result.Body = Encoding.UTF8.GetString(body.ToArray());
                }
            } catch (Exception error) {
                result.Error = error.Message + (tlsError.Length > 0 ? " " + tlsError : "");
            } finally {
                if (deadline != null) deadline.Dispose();
                active = null;
                if (response != null) response.Close();
            }
            return result;
        }
    }
}
'@

function Escape-Json([string]$text) {
    $result = New-Object Text.StringBuilder
    foreach ($character in $text.ToCharArray()) {
        $number = [int]$character
        if ($character -eq '"') { [void]$result.Append('\"') }
        elseif ($character -eq '\') { [void]$result.Append('\\') }
        elseif ($number -lt 32) { [void]$result.Append(('\u{0:x4}' -f $number)) }
        else { [void]$result.Append($character) }
    }
    return $result.ToString()
}
function Read-ScanId([string]$body) {
    # ConvertFrom-Json can unwrap a one-element array into a single object.
    # Check the root shape before parsing, not after pipeline enumeration.
    if ($body -notmatch '^\s*\{') { return "" }
    try {
        if (Get-Command ConvertFrom-Json -ErrorAction SilentlyContinue) {
            $object = ConvertFrom-Json -InputObject $body
            if ($object -isnot [Array] -and $object.scan_id -is [string]) { return $object.scan_id }
        } elseif ($script:jsonParser) {
            $object = $script:jsonParser.DeserializeObject($body)
            if ($object -is [Collections.IDictionary] -and $object["scan_id"] -is [string]) { return $object["scan_id"] }
        }
    } catch { Write-Host "[WARN] No usable scan_id in collection response." }
    return ""
}
function Send-Marker([string]$kind) {
    if ($DryRun -or -not $script:markersEnabled) { return $true }
    $fields = '"type":"' + (Escape-Json $kind) + '","source":"' + (Escape-Json $Source) +
        '","hostname":"' + (Escape-Json ([Environment]::MachineName)) + '","collector":"' +
        $collectorId + '","timestamp":"' + [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") + '"'
    if ($scanId) { $fields += ',"scan_id":"' + (Escape-Json $scanId) + '"' }
    if ($kind -ne "begin") {
        $fields += ',"stats":{'
        $parts = @()
        foreach ($key in $stats.Keys) { $parts += '"' + $key + '":' + $stats[$key] }
        $fields += ($parts -join ",") + ',"elapsed_seconds":' + [int]([DateTime]::UtcNow - $startTime).TotalSeconds + '}'
    }
    $body = [Text.Encoding]::UTF8.GetBytes('{' + $fields + '}')
    $attempts = 1
    if ($kind -eq "begin") { $attempts = 2 }
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        if ($Debugging) { Write-Host "[DEBUG] Marker $kind attempt $attempt" }
        $reply = [ThunderstormCollector.Transport]::Send($baseUrl + "/api/collection", "application/json", $body, 10000)
        if ($Debugging) { Write-Host "[DEBUG] Marker returned HTTP $($reply.Code) $($reply.Error)" }
        if (-not $reply.Error -and ($reply.Code -eq 404 -or $reply.Code -eq 501)) {
            Write-Host "[WARN] Collection markers unsupported (HTTP $($reply.Code))."
            $script:markersEnabled = $false
            return $true
        }
        if (-not $reply.Error -and $reply.Code -ge 200 -and $reply.Code -lt 300) {
            if ($kind -eq "begin") { $script:scanId = Read-ScanId $reply.Body }
            return $true
        }
        Write-Host "[ERROR] Collection $kind failed: HTTP $($reply.Code) $($reply.Error)"
        if ($attempt -lt $attempts -and -not [ThunderstormCollector.Transport]::Interrupted) { Start-Sleep -Seconds 2 }
    }
    return $false
}
function Is-Excluded([string]$path) {
    return $path -match '(?i)(^|[\\/])(OneDrive([ -][^\\/]*)?|Dropbox|Google Drive|GoogleDrive|iCloud Drive|Nextcloud|Owncloud|Mega|Syncthing)([\\/]|$)'
}
function Submit-File($file) {
    $stats.scanned++
    if ($file.Length -gt $limit -or ($MaxAge -gt 0 -and $file.LastWriteTimeUtc -lt $cutoff) -or
        (-not $AllExtensions -and $extensionSet -notcontains $file.Extension.ToLowerInvariant())) {
        $stats.skipped++
        return
    }
    if ($DryRun) { Write-Host "[DRY-RUN] Would submit $($file.FullName)"; return }
    try {
        $data = [ThunderstormCollector.Transport]::Snapshot($file.FullName, $limit, $cutoff)
        if ($null -eq $data) { $stats.skipped++; return }
        $boundary = "thunderstorm-" + [Guid]::NewGuid().ToString("N")
        $body = [ThunderstormCollector.Transport]::Multipart($file.FullName, $boundary, $data)
        for ($attempt = 1; $attempt -le $Retries; $attempt++) {
            if ([ThunderstormCollector.Transport]::Interrupted) { break }
            $reply = [ThunderstormCollector.Transport]::Send($uploadUrl, "multipart/form-data; boundary=$boundary", $body, 30000)
            if (-not $reply.Error -and $reply.Code -ge 200 -and $reply.Code -lt 300) {
                $stats.submitted++
                if ($Progress -and -not $NoProgress) { Write-Host "Submitted: $($stats.submitted)" }
                return
            }
            Write-Host "[ERROR] Upload $($file.FullName): HTTP $($reply.Code) $($reply.Error)"
            $delay = [Math]::Min(60, [Math]::Pow(2, $attempt - 1))
            if ($reply.Code -eq 503) {
                $delay = 2
                if ($reply.RetryAfter -match '^\d+$') { $delay = [Math]::Min(120, [double]$reply.RetryAfter) }
            }
            if ($attempt -lt $Retries -and -not [ThunderstormCollector.Transport]::Interrupted) { Start-Sleep -Seconds $delay }
        }
        $stats.failed++
    } catch { $stats.failed++; Write-Host "[ERROR] Cannot read/submit $($file.FullName): $($_.Exception.Message)" }
}
function Walk([string]$root) {
    $stack = New-Object 'Collections.Generic.Stack[string]'
    $stack.Push($root)
    while ($stack.Count -gt 0 -and -not [ThunderstormCollector.Transport]::Interrupted) {
        $directory = $stack.Pop()
        if (Is-Excluded $directory) { continue }
        try {
            $entry = Get-Item -LiteralPath $directory -Force
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $children = @(Get-ChildItem -LiteralPath $directory -Force)
        } catch { $stats.scan_errors++; Write-Host "[ERROR] Cannot traverse $directory"; continue }
        foreach ($file in $children) {
            if ([ThunderstormCollector.Transport]::Interrupted) { break }
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $stats.skipped++; continue }
            if ($file.PSIsContainer) { if (-not (Is-Excluded $file.FullName)) { $stack.Push($file.FullName) } }
            else { Submit-File $file }
        }
    }
}

try {
    if (-not $ThunderstormServer) {
        throw "Thunderstorm server is not configured. Set ThunderstormServer in USER CONFIGURATION or pass -ThunderstormServer HOST."
    }
    if ($ThunderstormServer -notmatch '^([A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9a-fA-F:]+\])$' -or
        $ThunderstormPort -lt 1 -or $ThunderstormPort -gt 65535 -or $MaxAge -lt 0 -or $MaxAge -gt 36500 -or
        $MaxSize -lt 1 -or $MaxSize -gt 200 -or $Retries -lt 1 -or $Retries -gt 10) {
        throw "Invalid server/port, MaxAge (0..36500), MaxSize (1..200 MiB) or Retries (1..10 total attempts)."
    }
    if (($CACert -or $Insecure) -and -not $UseSSL) { throw "CACert/Insecure require UseSSL." }
    if ($CACert -and $Insecure) { throw "CACert and Insecure are mutually exclusive." }
    if (-not ("ThunderstormCollector.Transport" -as [type])) { Add-Type -TypeDefinition $transportSource }
    [ThunderstormCollector.Transport]::Start()
    [ThunderstormCollector.Transport]::Configure($CACert, $Insecure.IsPresent)
    if ($UseSSL) {
        # Enable TLS 1.2 where supported without installing trust or enabling SSL 3.
        try { [Net.ServicePointManager]::SecurityProtocol = $oldProtocol -bor 3072 }
        catch { Write-Host "[WARN] TLS 1.2 unavailable; HTTPS depends on this OS/.NET. Verification remains enabled." }
        if ($Insecure) { Write-Host "[WARN] TLS verification explicitly disabled for this run." }
    }
    $scheme = "http"
    if ($UseSSL) { $scheme = "https" }
    $baseUrl = $scheme + "://" + $ThunderstormServer + ":" + $ThunderstormPort
    $endpoint = "/api/checkAsync"
    if ($Sync) { $endpoint = "/api/check" }
    $limit = [long]$MaxSize * 1048576
    $cutoff = [DateTime]::MinValue
    if ($MaxAge -gt 0) { $cutoff = $startTime.AddDays(-$MaxAge) }
    $extensionSet = @()
    $selectedExtensions = $DefaultExtensions
    if ($Extensions.Count -gt 0) {
        $selectedExtensions = $Extensions
    }
    foreach ($extension in $selectedExtensions) {
        if ($extension -notmatch '^\.[A-Za-z0-9_-]+$') { throw "Extensions require literal dot-prefixed suffixes." }
        $extensionSet += $extension.ToLowerInvariant()
    }
    $roots = @()
    foreach ($path in $Folder) {
        try {
            $item = Get-Item -LiteralPath $path -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Not a regular directory."
            }
            $roots += $item.FullName
        } catch { $stats.scan_errors++; Write-Host "[ERROR] Missing/unsafe directory: $path" }
    }
    if ($roots.Count -eq 0) { throw "No usable input directories." }
    Write-Host "[INFO] Scan roots (recursive; exclusions apply):"
    foreach ($root in $roots) { Write-Host "[INFO]   Scan root: $root" }
    Write-Host "[INFO] Limits: max-age=$MaxAge days (0=disabled); max-size=$MaxSize MiB; dry-run=$DryRun"
    if ($AllExtensions) { Write-Host "[INFO] Extensions: all" }
    else { Write-Host ("[INFO] Extensions: " + ($extensionSet -join ", ")) }
    $script:jsonParser = $null
    $script:markersEnabled = $true
    if (-not (Get-Command ConvertFrom-Json -ErrorAction SilentlyContinue)) {
        try {
            Add-Type -AssemblyName System.Web.Extensions
            $script:jsonParser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        } catch {
            $script:markersEnabled = $false
            Write-Host "[WARN] JSON parser unavailable (.NET 3.5 System.Web.Extensions required on PS2); no collection markers."
        }
    }
    if (-not (Send-Marker "begin")) { throw "Cannot begin collection." }
    $started = -not $DryRun
    $uploadUrl = $baseUrl + $endpoint + "?source=" + [Uri]::EscapeDataString($Source)
    if ($scanId) { $uploadUrl += "&scan_id=" + [Uri]::EscapeDataString($scanId) }
    foreach ($root in $roots) { Walk $root }
    if ([ThunderstormCollector.Transport]::Interrupted) {
        $exitCode = 1
    } elseif (-not (Send-Marker "end")) { $exitCode = 1 }
    if ($stats.failed -gt 0 -or $stats.scan_errors -gt 0) { $exitCode = 1 }
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    $exitCode = 2
} finally {
    if ("ThunderstormCollector.Transport" -as [type]) {
        if ([ThunderstormCollector.Transport]::Interrupted) {
            $exitCode = 1
            if ($started) { [void](Send-Marker "interrupted") }
            Write-Host "Thunderstorm Collector Run interrupted"
        }
        [ThunderstormCollector.Transport]::Stop()
    }
    [Net.ServicePointManager]::SecurityProtocol = $oldProtocol
}
Write-Host "Thunderstorm Collector Run finished (Checked: $($stats.scanned) Submitted: $($stats.submitted) Failed: $($stats.failed) Skipped: $($stats.skipped) Scan errors: $($stats.scan_errors))"
exit $exitCode
