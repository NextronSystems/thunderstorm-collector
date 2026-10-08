@if (@a)==(@b) @end /*
@echo off
setlocal DisableDelayedExpansion
"%SystemRoot%\System32\cscript.exe" //E:JScript //Nologo "%~f0"
exit /b %errorlevel%
*/
// THOR Thunderstorm Collector - Florian Roth / Nextron Systems
// Single release asset. WSH handles data; cmd never evaluates discovered paths.
var fso, shell, environment, workspace = "", exitCode = 0;
var stats = {scanned: 0, submitted: 0, failed: 0, skipped: 0, scan_errors: 0};
function log(text) { WScript.Echo(text); }
function setting(name, fallback) {
    var value = environment(name);
    return value === "" ? fallback : value;
}
function number(name, fallback, minimum, maximum) {
    var text = setting(name, String(fallback));
    if (!/^\d+$/.test(text)) throw new Error(name + " must be an integer.");
    var value = Number(text);
    if (value < minimum || value > maximum) throw new Error(name + " outside permitted range.");
    return value;
}
function flag(name) {
    var value = setting(name, "0").toLowerCase();
    if (!/^(0|1|false|true)$/.test(value)) throw new Error(name + " must be 0 or 1.");
    return value === "1" || value === "true";
}
function quote(text) {
    if (/["%\r\n\x00]/.test(text)) throw new Error("Invalid process path (quotes, percent signs or controls).");
    return '"' + text + '"';
}
function execute(command) {
    var process = shell.Exec(command), deadline = new Date().getTime() + 40000;
    while (process.Status === 0) {
        if (new Date().getTime() > deadline) {
            process.Terminate();
            throw new Error("curl exceeded its 40-second watchdog.");
        }
        WScript.Sleep(50);
    }
    return {code: process.ExitCode, output: process.StdOut.ReadAll(), error: process.StdErr.ReadAll()};
}
function resolveCurl() {
    var configured = setting("CURL_PATH", "");
    var candidates = configured ? [configured] :
        [fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "curl.exe"),
         fso.BuildPath(shell.ExpandEnvironmentStrings("%SystemRoot%"), "System32\\curl.exe")];
    if (!configured) {
        var paths = setting("PATH", "").split(";");
        for (var i = 0; i < paths.length; i++)
            if (paths[i]) candidates.push(fso.BuildPath(paths[i].replace(/^"|"$/g, ""), "curl.exe"));
    }
    for (var i = 0; i < candidates.length; i++) {
        if (!fso.FileExists(candidates[i])) continue;
        var path = fso.GetAbsolutePathName(candidates[i]);
        var version = execute(quote(path) + " --disable --version");
        var match = /^curl (\d+)\.(\d+)\./.exec(version.output);
        if (version.code !== 0 || !match || Number(match[1]) < 8 ||
            (Number(match[1]) === 8 && Number(match[2]) < 4))
            throw new Error("curl 8.4+ required for bounded response downloads.");
        return path;
    }
    throw new Error("curl.exe not found. Set CURL_PATH to a trusted absolute path.");
}
function createWorkspace() {
    var temporary = fso.GetSpecialFolder(2);
    for (var attempt = 0; attempt < 20; attempt++) {
        var candidate = fso.BuildPath(temporary, "thunderstorm-" + fso.GetTempName());
        try { fso.CreateFolder(candidate); workspace = candidate; return; } catch (error) {}
    }
    throw new Error("Cannot create an exclusively owned temporary directory.");
}
function excluded(path) {
    if (workspace && path.toLowerCase() === workspace.toLowerCase()) return true;
    return /(^|[\\\/])(OneDrive([ -][^\\\/]*)?|Dropbox|Google Drive|GoogleDrive|iCloud Drive|Nextcloud|Owncloud|Mega|Syncthing)([\\\/]|$)/i.test(path);
}
function appendText(body, text) {
    var stream = new ActiveXObject("ADODB.Stream");
    try {
        stream.Type = 2;
        stream.Charset = "utf-8";
        stream.Open();
        stream.WriteText(text);
        stream.Position = 0;
        stream.Type = 1;
        stream.Position = 3; // Remove the UTF-8 BOM from each multipart header.
        stream.CopyTo(body);
    } finally { if (stream.State) stream.Close(); }
}
function snapshot(file, boundary) {
    var before = fso.GetFile(file.Path), length = Number(before.Size);
    var stamp = new Date(before.DateLastModified).getTime();
    if ((before.Attributes & 1024) !== 0) throw new Error("File became a link.");
    if (length > maxSize || (maxAge > 0 && stamp < cutoff)) return false;
    var data = new ActiveXObject("ADODB.Stream"), body = new ActiveXObject("ADODB.Stream");
    try {
        data.Type = 1; data.Open(); data.LoadFromFile(file.Path);
        var after = fso.GetFile(file.Path);
        if (Number(data.Size) !== length || Number(after.Size) !== length ||
            new Date(after.DateLastModified).getTime() !== stamp || (after.Attributes & 1024) !== 0)
            throw new Error("File changed while being read.");
        body.Type = 1; body.Open();
        var name = file.Path.replace(/[\\\";\x00-\x1f\x7f]/g, "_");
        appendText(body, "--" + boundary + "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"" +
            name + "\"\r\nContent-Type: application/octet-stream\r\n\r\n");
        data.Position = 0; data.CopyTo(body);
        appendText(body, "\r\n--" + boundary + "--\r\n");
        body.SaveToFile(fso.BuildPath(workspace, "body.bin"), 2);
        return true;
    } finally {
        if (data.State) data.Close();
        if (body.State) body.Close();
    }
}
function upload(file) {
    stats.scanned++;
    var extension = "." + fso.GetExtensionName(file.Name).toLowerCase();
    if (Number(file.Size) > maxSize || (maxAge > 0 && new Date(file.DateLastModified).getTime() < cutoff) ||
        (!allExtensions && !extensions[extension])) { stats.skipped++; return; }
    if (dryRun) { log("[DRY-RUN] Would submit " + file.Path); return; }
    try {
        var boundary = "thunderstorm-" + new Date().getTime() + "-" + Math.floor(Math.random() * 1000000000);
        if (!snapshot(file, boundary)) { stats.skipped++; return; }
        var response = fso.BuildPath(workspace, "response.txt"), headers = fso.BuildPath(workspace, "headers.txt");
        var config = fso.BuildPath(workspace, "request.cfg");
        var configFile = fso.CreateTextFile(config, true, false);
        try { configFile.WriteLine('url = "' + url + '"'); } finally { configFile.Close(); }
        var command = quote(curl) + ' --disable --silent --show-error --globoff --noproxy "*" --connect-timeout 10' +
            ' --max-time 30 --max-filesize 1048576 --proto "=http,https" --output ' + quote(response) +
            " --dump-header " + quote(headers) + ' --write-out "%{http_code}" --header ' +
            quote("Content-Type: multipart/form-data; boundary=" + boundary) +
            " --data-binary " + quote("@" + fso.BuildPath(workspace, "body.bin")) + " --config " + quote(config);
        if (caBundle) command += " --cacert " + quote(caBundle);
        for (var attempt = 1; attempt <= attempts; attempt++) {
            var result = execute(command), status = result.output.replace(/^\s+|\s+$/g, "");
            if (result.code === 0 && /^2\d\d$/.test(status) && fso.FileExists(response) &&
                Number(fso.GetFile(response).Size) <= 1048576) {
                stats.submitted++; return;
            }
            log("[ERROR] Upload " + file.Path + ": HTTP " + status + " curl " + result.code);
            var delay = Math.min(60, Math.pow(2, attempt - 1));
            if (status === "503") {
                delay = 2;
                if (fso.FileExists(headers) && Number(fso.GetFile(headers).Size) <= 65536) {
                    var stream = fso.OpenTextFile(headers, 1);
                    var text;
                    try { text = stream.ReadAll(); } finally { stream.Close(); }
                    var match = /^Retry-After:\s*(\d+)\s*$/im.exec(text);
                    if (match) delay = Math.min(120, Number(match[1]));
                }
            }
            if (attempt < attempts) WScript.Sleep(delay * 1000);
        }
        stats.failed++;
    } catch (error) { stats.failed++; log("[ERROR] Cannot read/upload " + file.Path + ": " + error.message); }
}
function walk(root) {
    var stack = [root];
    while (stack.length) {
        var path = stack.pop();
        if (excluded(path)) continue;
        try {
            var directory = fso.GetFolder(path);
            if ((directory.Attributes & 1024) !== 0) { stats.skipped++; continue; }
            var folders = new Enumerator(directory.SubFolders);
            for (; !folders.atEnd(); folders.moveNext()) {
                var child = folders.item();
                if ((child.Attributes & 1024) === 0 && !excluded(child.Path)) stack.push(child.Path);
            }
            var files = new Enumerator(directory.Files);
            for (; !files.atEnd(); files.moveNext()) {
                var file = files.item();
                if ((file.Attributes & 1024) !== 0) { stats.skipped++; continue; }
                upload(file);
            }
        } catch (error) { stats.scan_errors++; log("[ERROR] Cannot traverse " + path + ": " + error.message); }
    }
}
try {
    fso = new ActiveXObject("Scripting.FileSystemObject");
    shell = new ActiveXObject("WScript.Shell");
    environment = shell.Environment("PROCESS");
    var server = setting("THUNDERSTORM_SERVER", ""), port = number("THUNDERSTORM_PORT", 8080, 1, 65535);
    if (!/^([A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9a-fA-F:]+\])$/.test(server)) throw new Error("Invalid THUNDERSTORM_SERVER.");
    var scheme = setting("URL_SCHEME", "http").toLowerCase();
    if (scheme !== "http" && scheme !== "https") throw new Error("URL_SCHEME must be http or https.");
    var maxSize = number("COLLECT_MAX_SIZE", 3000000, 1, 209715200);
    var maxAge = number("MAX_AGE", 30, 0, 36500), attempts = number("UPLOAD_ATTEMPTS", 3, 1, 10);
    var dryRun = flag("DRY_RUN"), sync = flag("SYNC");
    var caBundle = scheme === "https" ? setting("CURL_CA_BUNDLE", "") : "";
    if (caBundle && !dryRun) {
        caBundle = fso.GetAbsolutePathName(caBundle);
        quote(caBundle);
        if (!fso.FileExists(caBundle)) throw new Error("CURL_CA_BUNDLE file not found.");
    }
    var cutoff = new Date().getTime() - maxAge * 86400000;
    var source = setting("SOURCE", shell.ExpandEnvironmentStrings("%COMPUTERNAME%"));
    var url = scheme + "://" + server + ":" + port + (sync ? "/api/check" : "/api/checkAsync") +
        "?source=" + encodeURIComponent(source);
    var selected = setting("RELEVANT_EXTENSIONS", ".exe;.dll;.ps1;.bat;.txt").split(";");
    var allExtensions = selected.length === 1 && selected[0] === "*", extensions = {};
    for (var i = 0; i < selected.length && !allExtensions; i++) {
        if (!/^\.[A-Za-z0-9_-]+$/.test(selected[i])) throw new Error("Invalid RELEVANT_EXTENSIONS suffix.");
        extensions[selected[i].toLowerCase()] = true;
    }
    var directories = setting("COLLECT_DIRS", "");
    if (!directories) throw new Error("Set explicit COLLECT_DIRS; there is no broad default scan.");
    var roots = [], values = directories.split(";");
    for (var i = 0; i < values.length; i++) {
        try {
            var directory = fso.GetFolder(values[i]);
            if ((directory.Attributes & 1024) !== 0) throw new Error("Root is a link.");
            roots.push(directory.Path);
        } catch (error) { stats.scan_errors++; log("[ERROR] Missing/unsafe directory: " + values[i]); }
    }
    if (!roots.length) throw new Error("No usable input directories.");
    if (!dryRun) { var curl = resolveCurl(); createWorkspace(); }
    for (var i = 0; i < roots.length; i++) walk(roots[i]);
    if (stats.failed || stats.scan_errors) exitCode = 1;
} catch (error) { log("[ERROR] " + error.message); exitCode = 2; }
finally {
    if (workspace) {
        try { fso.DeleteFolder(workspace, true); }
        catch (error) { log("[ERROR] Cannot remove owned temporary payloads: " + workspace); exitCode = 1; }
    }
}
log("Thunderstorm Collector Run finished (Checked: " + stats.scanned + " Submitted: " + stats.submitted +
    " Failed: " + stats.failed + " Skipped: " + stats.skipped + " Scan errors: " + stats.scan_errors + ")");
WScript.Quit(exitCode);
