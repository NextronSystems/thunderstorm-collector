@ECHO OFF
SETLOCAL EnableDelayedExpansion

:: ----------------------------------------------------------------
:: THOR Thunderstorm Collector
:: Windows Batch
:: Florian Roth, Nextron Systems GmbH
:: v0.5
::
:: A Windows Batch script that uses Curl for Windows
:: to upload files to a THOR Thunderstorm server
::
:: Requirements:
:: Curl for Windows (place curl.exe into the script folder or PATH)
:: https://curl.se/windows/
::
:: Note on Windows 10+
:: Windows 10 already includes curl since build 17063 (version 1709+)
::
:: Note on Windows 7 / Server 2008 R2:
:: Curl 8.x requires the Universal C Runtime (KB2999226 or KB3118401).
:: Install the Visual C++ 2015 Redistributable or the UCRT update,
:: then place the curl.exe + libcurl DLL in the script folder.
:: ----------------------------------------------------------------

:: CONFIGURATION -------------------------------------------------

:: THUNDERSTORM SERVER
SET _TS=%THUNDERSTORM_SERVER%
SET _TP=%THUNDERSTORM_PORT%
SET _SCHEME=%URL_SCHEME%
IF "%_TS%"=="" SET _TS=ygdrasil.nextron
IF "%_TP%"=="" SET _TP=8080
IF "%_SCHEME%"=="" SET _SCHEME=http

:: SELECTION
SET _DIRS=%COLLECT_DIRS%
SET _EXTS=%RELEVANT_EXTENSIONS%
SET _MAXSZ=%COLLECT_MAX_SIZE%
SET _MAXAGE=%MAX_AGE%
IF "%_DIRS%"=="" SET _DIRS=C:\Users;C:\Temp;C:\Windows
IF "%_EXTS%"=="" SET _EXTS=.vbs .ps .ps1 .rar .tmp .bat .chm .dll .exe .hta .js .lnk .sct .war .jsp .jspx .php .asp .aspx .log .dmp .txt .jar .job
IF "%_MAXSZ%"=="" SET _MAXSZ=3000000
IF "%_MAXAGE%"=="" SET _MAXAGE=30

:: DEBUG & SOURCE
SET _DBG=%DEBUG%
SET _SRC=%SOURCE%
IF "%_DBG%"=="" SET _DBG=0

:: Counters
SET /A _SUBMITTED=0
SET /A _SKIPPED=0
SET /A _FAILED=0
SET /A _SCANNED=0

:: WELCOME -------------------------------------------------------

ECHO =============================================================
ECHO    ________                __            __
ECHO   /_  __/ /  __ _____  ___/ /__ _______ / /____  ______ _
ECHO    / / / _ \/ // / _ \/ _  / -_) __(_--/ __/ _ \/ __/  ' \
ECHO   /_/ /_//_/\_,_/_//_/\_,_/\__/_/ /___/\__/\___/_/ /_/_/_/
ECHO.
ECHO   Windows Batch Collector v0.5
ECHO   Florian Roth, Nextron Systems GmbH, 2020-2026
ECHO.
ECHO =============================================================
ECHO.

:: REQUIREMENTS --------------------------------------------------
:: Prefer curl next to the script (bundled with UCRT DLLs), then current dir, then PATH
SET _CURL=
IF EXIST "%~dp0curl.exe" (
    SET "_CURL=%~dp0curl.exe"
    GOTO :CURLOK
)
IF EXIST "%CD%\curl.exe" (
    SET "_CURL=%CD%\curl.exe"
    GOTO :CURLOK
)
where /q curl.exe
IF NOT ERRORLEVEL 1 (
    FOR /F "tokens=*" %%C IN ('where curl.exe') DO (
        IF NOT DEFINED _CURL SET "_CURL=%%C"
    )
    GOTO :CURLOK
)
ECHO [!] Cannot find curl in PATH or the script directory.
ECHO     Download from https://curl.se/windows/ and place curl.exe next to this script.
EXIT /b 2
:CURLOK
ECHO [+] Curl found: %_CURL%

:: SOURCE --------------------------------------------------------
IF "%_SRC%"=="" (
    FOR /F "tokens=*" %%i IN ('hostname') DO SET _SRC=%%i
    ECHO [+] Source: !_SRC!
)
:: URL-encode the source for query string use
:: Note: batch SET substitution can't replace = (it's the delimiter), so we use PowerShell
FOR /F "usebackq tokens=*" %%U IN (`powershell -NoProfile -Command "[uri]::EscapeDataString('!_SRC!')"`) DO SET "_SRC_URL=%%U"
:: JSON-escape the source for collection markers (escape backslash and double-quote)
SET "_SRC_JSON=!_SRC!"
SET "_SRC_JSON=!_SRC_JSON:\=\\!"
SET "_SRC_JSON=!_SRC_JSON:"=\"!"

:: COLLECTION MARKERS --------------------------------------------
:: Generate ISO 8601 timestamp (locale-independent via PowerShell)
SET _TIMESTAMP=
FOR /F "usebackq tokens=*" %%T IN (`powershell -NoProfile -Command "(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')"`) DO SET "_TIMESTAMP=%%T"
IF "%_TIMESTAMP%"=="" SET "_TIMESTAMP=%date%"

:: POST begin marker to /api/collection (forward-compatible: 404 = continue)
SET _SCANID=
"%_CURL%" -s -X POST -H "Content-Type: application/json" -d "{\"type\":\"begin\",\"source\":\"!_SRC_JSON!\",\"collector\":\"batch/0.5\",\"timestamp\":\"!_TIMESTAMP!\"}" "!_SCHEME!://!_TS!:!_TP!/api/collection" -o "%TEMP%\ts_marker.tmp" 2>nul
IF NOT EXIST "%TEMP%\ts_marker.tmp" GOTO :NOSCANID
:: Extract scan_id using PowerShell for reliable JSON parsing
:: (done outside IF block to avoid batch parser issues with PS syntax)
powershell -NoProfile -Command "$c=Get-Content '%TEMP%\ts_marker.tmp'; if($c -match 'scan_id.+?:.*?\"(.+?)\"'){$matches[1]}" > "%TEMP%\ts_scanid.tmp" 2>nul
SET /P _SCANID=<"%TEMP%\ts_scanid.tmp"
DEL "%TEMP%\ts_marker.tmp" 2>nul
DEL "%TEMP%\ts_scanid.tmp" 2>nul
:NOSCANID
IF DEFINED _SCANID (
    ECHO [+] Collection started, scan_id: !_SCANID!
    SET "_IDPARAM=&scan_id=!_SCANID!"
) ELSE (
    SET _IDPARAM=
)

:: BUILD FILE LIST -----------------------------------------------
:: Phase 1: Use FORFILES to generate a filtered file list.
:: FORFILES does NOT follow junctions/reparse points, solving the infinite loop issue.

SET _FILELIST=%TEMP%\thunderstorm_files_%RANDOM%%RANDOM%.txt
IF EXIST "%_FILELIST%" DEL "%_FILELIST%" 2>nul

:: Calculate cutoff date for age filter (today minus _MAXAGE days)
:: FORFILES /D +MM/DD/YYYY selects files modified on or after that date
SET _DATEFILTER=
IF %_MAXAGE% GTR 0 (
    :: Use PowerShell to compute the date (available on Vista+)
    FOR /F "usebackq tokens=*" %%D IN (`powershell -NoProfile -Command "(Get-Date).AddDays(-%_MAXAGE%).ToString('MM/dd/yyyy')"`) DO SET _DATEFILTER=/D +%%D
)

ECHO [+] Scanning %_DIRS% ...
ECHO [+] Filters: MAX_SIZE=%_MAXSZ% bytes, MAX_AGE=%_MAXAGE% days, EXTENSIONS=%_EXTS%

FOR %%T IN ("%_DIRS:;=" "%") DO (
    SET "_TDIR=%%~T"
    IF NOT EXIST "!_TDIR!" (
        ECHO [!] Warning: !_TDIR! does not exist, skipping.
    ) ELSE (
        IF "%_DBG%"=="1" ECHO [D] Scanning !_TDIR! ...
        :: FORFILES /S = recurse (skips junctions), /C = command per file
        :: @path outputs quoted full path, @isdir filters out directories
        IF DEFINED _DATEFILTER (
            FORFILES /P "!_TDIR!" /S !_DATEFILTER! /C "cmd /c if @isdir==FALSE echo @path" >>"%_FILELIST%" 2>nul
        ) ELSE (
            FORFILES /P "!_TDIR!" /S /C "cmd /c if @isdir==FALSE echo @path" >>"%_FILELIST%" 2>nul
        )
    )
)

:: Count total files found
SET /A _TOTAL=0
IF EXIST "%_FILELIST%" (
    FOR /F "usebackq" %%C IN (`type "%_FILELIST%" ^| find /c /v ""`) DO SET /A _TOTAL=%%C
)
ECHO [+] Found %_TOTAL% files within age limit.

:: PHASE 2: FILTER AND UPLOAD ------------------------------------
IF "%_TOTAL%"=="0" GOTO :DONE

:: Build the upload URL once (quoted to protect & in _IDPARAM)
SET "_UPLOAD_URL=!_SCHEME!://!_TS!:!_TP!/api/checkAsync?source=!_SRC_URL!!_IDPARAM!"

:: Process each file from the list.
:: The FORFILES output has quoted paths ("C:\path\file.ext").
:: %%~F strips quotes. We use %%F (with quotes) for passing to subroutines
:: to preserve ! characters, and %%~xF / %%~zF for extension/size checks.
FOR /F "usebackq delims=" %%F IN ("%_FILELIST%") DO (
    SET /A _SCANNED+=1

    :: Extension check (%%~xF is safe — extensions don't contain !)
    SET _EXTMATCH=0
    FOR %%E IN (%_EXTS%) DO (
        IF /I "%%~xF"=="%%E" SET _EXTMATCH=1
    )
    IF !_EXTMATCH! == 0 (
        IF "%_DBG%"=="1" ECHO [D] Skip: %%~F ^(extension^)
        SET /A _SKIPPED+=1
    ) ELSE (
        :: Size check (%%~zF is safe — sizes are numeric)
        SET "_SZ=%%~zF"
        IF !_SZ! GTR %_MAXSZ% (
            IF "%_DBG%"=="1" ECHO [D] Skip: %%~F ^(size: !_SZ!^)
            SET /A _SKIPPED+=1
        ) ELSE (
            :: Upload via subroutine. Pass %%F (still quoted from FORFILES)
            :: to protect ! characters through the CALL boundary.
            CALL :UPLOADFILE %%F
        )
    )
)

GOTO :DONE

:: ---------------------------------------------------------------
:: UPLOADFILE subroutine — uploads a single file with retry logic
:: Called as: CALL :UPLOADFILE "filepath"
:: Using CALL isolates the subroutine, allowing GOTO for retries
:: and protecting ! in filenames when delayed expansion is toggled.
:: ---------------------------------------------------------------
:UPLOADFILE
:: Capture path with delayed expansion OFF to protect ! in filenames
:: (delayed expansion would interpret !var! patterns in the path)
SETLOCAL DisableDelayedExpansion
SET "_UF_PATH=%~1"
ENDLOCAL & SET "_UF_PATH=%_UF_PATH%"
SET /A _UF_RETRY=0
SET /A _UF_MAXRETRY=3
SET /A _UF_503RETRY=0
SET /A _UF_MAX503=10
ECHO [+] Uploading: %_UF_PATH%

:UPLOADRETRY
:: Temporarily disable delayed expansion for curl to protect ! in path
SETLOCAL DisableDelayedExpansion
"%_CURL%" -s -o nul -w "%%{http_code}" -F "file=@%_UF_PATH%" "%_UPLOAD_URL%" > "%TEMP%\ts_http_rc.tmp" 2>nul
SET _UF_CURL_RC=%ERRORLEVEL%
ENDLOCAL & SET _UF_CURL_RC=%_UF_CURL_RC%

:: Read HTTP status code from curl output
SET _UF_HTTP=0
IF %_UF_CURL_RC% == 0 (
    IF EXIST "%TEMP%\ts_http_rc.tmp" (
        SET /P _UF_HTTP=<"%TEMP%\ts_http_rc.tmp"
    )
)
DEL "%TEMP%\ts_http_rc.tmp" 2>nul

:: HTTP 200 = success
IF "%_UF_HTTP%"=="200" (
    SET /A _SUBMITTED+=1
    GOTO :UPLOADEND
)

:: HTTP 503 = server busy, use separate retry counter (no exponential backoff)
IF "%_UF_HTTP%"=="503" (
    SET /A _UF_503RETRY+=1
    IF %_UF_503RETRY% GEQ %_UF_MAX503% (
        ECHO [-] Failed: %_UF_PATH% ^(503 after %_UF_503RETRY% retries^)
        SET /A _FAILED+=1
        GOTO :UPLOADEND
    )
    ECHO [.] Server busy ^(503^), retry %_UF_503RETRY%/%_UF_MAX503% in 3s ...
    timeout /t 3 /nobreak >nul 2>nul
    GOTO :UPLOADRETRY
)

:: Connection failure (curl exit != 0) or HTTP error (4xx, 5xx)
SET /A _UF_RETRY+=1
IF %_UF_RETRY% GEQ %_UF_MAXRETRY% (
    IF %_UF_CURL_RC% NEQ 0 (
        ECHO [-] Failed: %_UF_PATH% ^(curl exit: %_UF_CURL_RC% after %_UF_RETRY% retries^)
    ) ELSE (
        ECHO [-] Failed: %_UF_PATH% ^(HTTP %_UF_HTTP% after %_UF_RETRY% retries^)
    )
    SET /A _FAILED+=1
    GOTO :UPLOADEND
)

:: Exponential backoff: 2, 4, 8 seconds
SET /A _UF_WAIT=1
SET /A _UF_I=0
:EXPLOOP
IF %_UF_I% LSS %_UF_RETRY% (
    SET /A _UF_WAIT=_UF_WAIT*2
    SET /A _UF_I+=1
    GOTO :EXPLOOP
)
SET /A _UF_WAIT=_UF_WAIT*2
ECHO [.] Retry %_UF_RETRY%/%_UF_MAXRETRY% in %_UF_WAIT%s ...
timeout /t %_UF_WAIT% /nobreak >nul 2>nul
GOTO :UPLOADRETRY

:UPLOADEND
GOTO :EOF

:DONE
:: COLLECTION END MARKER -----------------------------------------
:: Generate fresh timestamp for end marker
SET _END_TIMESTAMP=
FOR /F "usebackq tokens=*" %%T IN (`powershell -NoProfile -Command "(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')"`) DO SET "_END_TIMESTAMP=%%T"
IF "%_END_TIMESTAMP%"=="" SET "_END_TIMESTAMP=%date%"

:: Always send end marker (even without scan_id — stats should not be lost)
SET "_SCANID_JSON="
IF DEFINED _SCANID SET "_SCANID_JSON=,\"scan_id\":\"!_SCANID!\""
"%_CURL%" -s -o nul -X POST -H "Content-Type: application/json" -d "{\"type\":\"end\",\"source\":\"!_SRC_JSON!\",\"collector\":\"batch/0.5\",\"timestamp\":\"!_END_TIMESTAMP!\"!_SCANID_JSON!,\"stats\":{\"scanned\":%_SCANNED%,\"submitted\":%_SUBMITTED%,\"skipped\":%_SKIPPED%,\"failed\":%_FAILED%}}" "!_SCHEME!://!_TS!:!_TP!/api/collection" 2>nul

:: CLEANUP -------------------------------------------------------
IF EXIST "%_FILELIST%" DEL "%_FILELIST%" 2>nul

:: SUMMARY -------------------------------------------------------
ECHO.
ECHO [+] Done. scanned=%_SCANNED% submitted=%_SUBMITTED% skipped=%_SKIPPED% failed=%_FAILED%

:: Exit codes: 0=clean, 1=partial failure, 2=fatal
IF %_FAILED% GTR 0 (
    ENDLOCAL
    EXIT /b 1
)
ENDLOCAL
EXIT /b 0
