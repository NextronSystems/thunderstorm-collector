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
::
:: Known Limitations (cmd.exe platform constraints):
:: - No collection markers: begin/end markers and scan_id tracking require
::   JSON parsing which is impractical in pure batch. Use the PowerShell
::   collector (.ps1 or .ps2.ps1) for collection marker support.
:: - No --ca-cert / --insecure support: Use CURL_CA_BUNDLE env var or
::   URL_SCHEME=http as workarounds.
:: - No progress reporting: cmd.exe cannot detect interactive terminals.
:: - No signal handling: Ctrl+C terminates without cleanup.
:: - MAX_AGE filtering: FORFILES /D -N has inverted semantics (files ≥N days
::   OLD, not files from last N days). This script applies age filtering
::   per-file in PROCESSFILE as a workaround.
:: - FINDSTR regex: Windows 7 has limited regex support ($ anchors and
::   negated character classes [^...] are broken). Hostname validation
::   provides defense-in-depth; server-side validation is authoritative.
:: ----------------------------------------------------------------

:: CONFIGURATION -------------------------------------------------

:: THUNDERSTORM SERVER
SET _TS=%THUNDERSTORM_SERVER%
SET _TP=%THUNDERSTORM_PORT%
SET _SCHEME=%URL_SCHEME%
IF "%_TS%"=="" SET _TS=ygdrasil.nextron
IF "%_TP%"=="" SET _TP=8080
IF "%_SCHEME%"=="" SET _SCHEME=http
IF /I NOT "%_SCHEME%"=="http" IF /I NOT "%_SCHEME%"=="https" (
    ECHO [ERROR] Invalid URL_SCHEME: %_SCHEME%. Must be http or https. 1>&2
    EXIT /b 2
)

:: SELECTION
SET _DIRS=%COLLECT_DIRS%
SET _EXTS=%RELEVANT_EXTENSIONS%
SET _MAXSZ=%COLLECT_MAX_SIZE%
SET _MAXAGE=%MAX_AGE%
IF "%_DIRS%"=="" SET "_DIRS=C:\Users;C:\Temp;C:\Windows"
IF "%_EXTS%"=="" SET _EXTS=.vbs .ps1 .rar .tmp .bat .chm .dll .exe .hta .js .lnk .sct .war .jsp .jspx .php .asp .aspx .log .dmp .txt .jar .job
IF "%_MAXSZ%"=="" SET _MAXSZ=3000000
IF "%_MAXAGE%"=="" SET _MAXAGE=30

:: DEBUG & SOURCE
SET _DBG=%DEBUG%
SET _SRC=%SOURCE%
IF "%_DBG%"=="" SET _DBG=0

:: Basic server hostname validation: reject empty and values containing characters
:: outside the allowed set (alphanumeric, hyphens, dots, colons, brackets for IPv6).
:: Full URL validation is delegated to curl.
IF "!_TS!"=="" (
    ECHO [ERROR] Server hostname is empty. Set THUNDERSTORM_SERVER. 1>&2
    EXIT /b 2
)
ECHO !_TS!| FINDSTR /R "[^a-zA-Z0-9.\-\[\]:]" >nul 2>&1
IF NOT ERRORLEVEL 1 (
    ECHO [ERROR] Server hostname contains invalid characters: !_TS! 1>&2
    EXIT /b 2
)

:: Validate numeric parameters
SET /A _TP=%_TP% 2>nul
SET /A _MAXSZ=%_MAXSZ% 2>nul
SET /A _MAXAGE=%_MAXAGE% 2>nul
IF !_TP! LEQ 0 SET _TP=8080
IF !_TP! GTR 65535 SET _TP=8080
IF !_MAXSZ! LEQ 0 SET _MAXSZ=3000000
IF !_MAXAGE! LSS 0 SET _MAXAGE=30

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
ECHO [ERROR] Cannot find curl in PATH or the script directory. 1>&2
ECHO     Download from https://curl.se/windows/ and place curl.exe next to this script. 1>&2
EXIT /b 2
:CURLOK
ECHO [+] Curl found: %_CURL%

:: SOURCE --------------------------------------------------------
IF "%_SRC%"=="" (
    FOR /F "tokens=*" %%i IN ('hostname') DO SET _SRC=%%i
    ECHO [+] Source: !_SRC!
)

:: Create temp files for file listing and curl responses
SET "_FILELIST=%TEMP%\ts-collector-%RANDOM%%RANDOM%.tmp"
SET "_RESPTMP=%TEMP%\ts-collector-resp-%RANDOM%%RANDOM%.tmp"
IF EXIST "!_FILELIST!" DEL "!_FILELIST!" 2>nul
IF EXIST "!_RESPTMP!" DEL "!_RESPTMP!" 2>nul

:: URL-encode the source for use in query strings
:: Only encode characters problematic in URLs
SET "_SRCURL=!_SRC!"
SET "_SRCURL=!_SRCURL:%%=%%25!"
SET "_SRCURL=!_SRCURL: =%%20!"
SET "_SRCURL=!_SRCURL:&=%%26!"
SET "_SRCURL=!_SRCURL:+=%%2B!"
SET "_SRCURL=!_SRCURL:#=%%23!"
SET "_SRCURL=!_SRCURL:==%%3D!"

:: NOTE: Collection markers (begin/end) and scan_id tracking are not
:: supported in the batch collector. Use the PowerShell collector
:: (.ps1 or .ps2.ps1) for collection marker support.
SET _IDPARAM=

:: BUILD FILE LIST -----------------------------------------------
:: Phase 1: Use FORFILES to generate a filtered file list.
:: FORFILES does NOT follow junctions/reparse points, solving the infinite loop issue.

:: NOTE: Age filtering is NOT performed in the FORFILES phase because
:: FORFILES /D -N has INVERTED semantics: it means "files modified ON OR BEFORE
:: N days ago" (old files), not "files from the last N days". Age filtering
:: is handled during file iteration in PROCESSFILE instead.
:: See: https://ss64.com/nt/forfiles.html - "/D -dd selects files with a
:: last modified date less than or equal to the current date minus dd days."

ECHO [+] Scanning !_DIRS! ...
ECHO [+] Filters: MAX_SIZE=%_MAXSZ% bytes, MAX_AGE=%_MAXAGE% days, EXTENSIONS=%_EXTS%
:: NOTE: MAX_AGE is applied per file in PROCESSFILE (not in FORFILES /D).

:: Iterate directories using semicolon delimiter (supports paths with spaces)
:: COLLECT_DIRS can be semicolon-separated, e.g. "C:\Program Files;C:\Temp"
:: Write directory list to a temp file, then iterate with delayed expansion off
:: to protect paths containing '!' characters.
SET "_DIRLIST=!_FILELIST!.dirs"
:: Split semicolon-separated directory list into lines
FOR %%T IN ("!_DIRS:;=" "!") DO (
    IF NOT "%%~T"=="" ECHO %%~T>>"!_DIRLIST!"
)
FOR /F "usebackq delims=" %%T IN ("!_DIRLIST!") DO (
    CALL :SCANDIR "%%T"
)
DEL "!_DIRLIST!" 2>nul
GOTO :SCANDONE

:SCANDIR
SETLOCAL DisableDelayedExpansion
SET "_TDIR=%~1"
IF "%_TDIR%"=="" (
    ENDLOCAL
    GOTO :EOF
)
IF NOT EXIST "%_TDIR%" (
    ECHO [ERROR] Warning: %_TDIR% does not exist, skipping. 1>&2
    ENDLOCAL
    GOTO :EOF
)
IF %_DBG% == 1 ECHO [D] Scanning %_TDIR% ...
:: FORFILES /S = recurse (skips junctions), /C = command per file
:: @path outputs quoted full path, @isdir filters out directories
:: Note: Age filtering via /D has inverted semantics and is not used here.
:: Age is checked during iteration in PROCESSFILE.
FORFILES /P "%_TDIR%" /S /C "cmd /c if @isdir==FALSE echo @path" >>"%_FILELIST%" 2>nul
ENDLOCAL
GOTO :EOF

:SCANDONE

:: Count total files found
SET /A _TOTAL=0
IF EXIST "!_FILELIST!" (
    FOR /F "usebackq" %%C IN (`type "!_FILELIST!" ^| find /c /v ""`) DO SET /A _TOTAL=%%C
)
ECHO [+] Found !_TOTAL! files.

:: PHASE 2: FILTER AND UPLOAD ------------------------------------
IF !_TOTAL! == 0 GOTO :DONE

:: Disable delayed expansion for the file-processing loop so paths
:: containing '!' characters are not corrupted during %%F expansion.
SET "_FILELIST_SAVED=!_FILELIST!"
SETLOCAL DisableDelayedExpansion
FOR /F "usebackq delims=" %%F IN ("%_FILELIST_SAVED%") DO (
    CALL :PROCESSFILE "%%~F"
)
ENDLOCAL
GOTO :DONE

:: ---------------------------------------------------------------
:: Subroutine: PROCESSFILE
:: Processes a single file path passed as %1.
:: Uses SETLOCAL/ENDLOCAL to toggle delayed expansion, protecting
:: file paths that contain '!' characters from being corrupted.
:: ---------------------------------------------------------------
:PROCESSFILE
:: First, capture the raw path with delayed expansion OFF so '!' is preserved
SETLOCAL DisableDelayedExpansion
SET "_FILE=%~1"
SET _SZ=
SET "_FEXT="
SET "_AGEDIR="
SET "_AGENAME="
FOR %%S IN ("%_FILE%") DO (
    SET "_SZ=%%~zS"
    SET "_FEXT=%%~xS"
    SET "_AGEDIR=%%~dpS"
    SET "_AGENAME=%%~nxS"
)
:: Now re-enable delayed expansion for counter logic and comparisons
SETLOCAL EnableDelayedExpansion

:: Extension check
SET _EXTMATCH=0
FOR %%E IN (%_EXTS%) DO (
    IF /I "!_FEXT!"=="%%E" SET _EXTMATCH=1
)
IF !_EXTMATCH! == 0 (
    IF !_DBG! == 1 ECHO [D] Skip current file ^(extension^)
    SET /A _SKIPPED+=1
    :: Propagate all counters back to parent scope
    FOR /F "tokens=1-4" %%A IN ("!_SCANNED! !_SUBMITTED! !_SKIPPED! !_FAILED!") DO (
        ENDLOCAL & ENDLOCAL
        SET /A _SCANNED=%%A
        SET /A _SUBMITTED=%%B
        SET /A _SKIPPED=%%C
        SET /A _FAILED=%%D
    )
    GOTO :EOF
)
:: Size check (file may have been deleted since listing)
IF "!_SZ!"=="" (
    IF !_DBG! == 1 ECHO [D] Skip current file ^(file not found^)
    SET /A _SKIPPED+=1
    FOR /F "tokens=1-4" %%A IN ("!_SCANNED! !_SUBMITTED! !_SKIPPED! !_FAILED!") DO (
        ENDLOCAL & ENDLOCAL
        SET /A _SCANNED=%%A
        SET /A _SUBMITTED=%%B
        SET /A _SKIPPED=%%C
        SET /A _FAILED=%%D
    )
    GOTO :EOF
)
IF !_SZ! GTR !_MAXSZ! (
    IF !_DBG! == 1 ECHO [D] Skip current file ^(size: !_SZ!^)
    SET /A _SKIPPED+=1
    FOR /F "tokens=1-4" %%A IN ("!_SCANNED! !_SUBMITTED! !_SKIPPED! !_FAILED!") DO (
        ENDLOCAL & ENDLOCAL
        SET /A _SCANNED=%%A
        SET /A _SUBMITTED=%%B
        SET /A _SKIPPED=%%C
        SET /A _FAILED=%%D
    )
    GOTO :EOF
)
:: Age check — FORFILES /D -N matches old files (<= today-N), so we check per-file
:: and skip those that are too old.
IF !_MAXAGE! GTR 0 (
    SET "_ISOLD=0"
    CALL :ISFILEOLD_RAW
    IF "!_ISOLD!"=="1" (
        IF !_DBG! == 1 ECHO [D] Skip current file ^(age: older than !_MAXAGE! days^)
        SET /A _SKIPPED+=1
        FOR /F "tokens=1-4" %%A IN ("!_SCANNED! !_SUBMITTED! !_SKIPPED! !_FAILED!") DO (
            ENDLOCAL & ENDLOCAL
            SET /A _SCANNED=%%A
            SET /A _SUBMITTED=%%B
            SET /A _SKIPPED=%%C
            SET /A _FAILED=%%D
        )
        GOTO :EOF
    )
)
:: Upload — increment _SCANNED only for files that pass filters
SET /A _SCANNED+=1
ECHO [+] Uploading: %_FILE%
SET _HTTPCODE=
CALL :RUNUPLOAD_RAW
IF !_CURLRC! == 0 (
    SET /P _HTTPCODE=<"!_RESPTMP!"
    DEL "!_RESPTMP!" 2>nul
    IF "!_HTTPCODE!"=="" (
        ECHO [ERROR] Failed current file ^(empty response^) 1>&2
        SET /A _FAILED+=1
    ) ELSE IF "!_HTTPCODE!"=="503" (
        :: Respect Retry-After header, capped at 60s, default 5s
        SET _RETRYWAIT=5
        IF EXIST "!_RESPTMP!.hdr" (
            FOR /F "tokens=2 delims=: " %%H IN ('FINDSTR /I "^Retry-After:" "!_RESPTMP!.hdr"') DO (
                SET /A _RETRYWAIT=%%H 2>nul
                IF !_RETRYWAIT! LEQ 0 SET _RETRYWAIT=5
                IF !_RETRYWAIT! GTR 60 SET _RETRYWAIT=60
            )
        )
        DEL "!_RESPTMP!.hdr" 2>nul
        ECHO [!] Server busy ^(503^), waiting !_RETRYWAIT!s before retry... 1>&2
        SET /A _PINGCOUNT=!_RETRYWAIT!+1
        PING -n !_PINGCOUNT! 127.0.0.1 >nul 2>&1
        SET _HTTPCODE2=
        CALL :RUNUPLOAD_RAW
        SET "_CURLRC2=!_CURLRC!"
        IF !_CURLRC2! == 0 (
            SET /P _HTTPCODE2=<"!_RESPTMP!"
            DEL "!_RESPTMP!" 2>nul
            DEL "!_RESPTMP!.hdr" 2>nul
            IF "!_HTTPCODE2!"=="503" (
                ECHO [ERROR] Failed current file ^(server still busy^) 1>&2
                SET /A _FAILED+=1
            ) ELSE IF "!_HTTPCODE2:~0,1!"=="2" (
                SET /A _SUBMITTED+=1
            ) ELSE (
                ECHO [ERROR] Failed current file ^(HTTP !_HTTPCODE2! on retry^) 1>&2
                SET /A _FAILED+=1
            )
        ) ELSE (
            DEL "!_RESPTMP!" 2>nul
            DEL "!_RESPTMP!.hdr" 2>nul
            ECHO [ERROR] Failed current file ^(curl exit: !_CURLRC2!^) 1>&2
            SET /A _FAILED+=1
        )
    ) ELSE IF "!_HTTPCODE:~0,1!"=="2" (
        DEL "!_RESPTMP!.hdr" 2>nul
        SET /A _SUBMITTED+=1
    ) ELSE (
        DEL "!_RESPTMP!.hdr" 2>nul
        ECHO [ERROR] Failed current file ^(HTTP !_HTTPCODE!^) 1>&2
        SET /A _FAILED+=1
    )
) ELSE (
    DEL "!_RESPTMP!" 2>nul
    DEL "!_RESPTMP!.hdr" 2>nul
    ECHO [ERROR] Failed current file ^(curl exit: !_CURLRC!^) 1>&2
    SET /A _FAILED+=1
)
:: Clean up any leftover temp files from this iteration
IF EXIST "!_RESPTMP!" DEL "!_RESPTMP!" 2>nul
IF EXIST "!_RESPTMP!.hdr" DEL "!_RESPTMP!.hdr" 2>nul
:: Propagate all counters back to parent scope
FOR /F "tokens=1-4" %%A IN ("!_SCANNED! !_SUBMITTED! !_SKIPPED! !_FAILED!") DO (
    ENDLOCAL & ENDLOCAL
    SET /A _SCANNED=%%A
    SET /A _SUBMITTED=%%B
    SET /A _SKIPPED=%%C
    SET /A _FAILED=%%D
)
GOTO :EOF

:: ---------------------------------------------------------------
:: Subroutine: RUNUPLOAD_RAW
:: Runs curl with delayed expansion disabled so paths containing '!'
:: are preserved in both the file lookup and multipart filename metadata.
:: ---------------------------------------------------------------
:RUNUPLOAD_RAW
SETLOCAL DisableDelayedExpansion
"%_CURL%" -s -o nul -D "%_RESPTMP%.hdr" -w "%%{http_code}" -F "file=@%_FILE%;filename=%_FILE%" "%_SCHEME%://%_TS%:%_TP%/api/checkAsync?source=%_SRCURL%%_IDPARAM%" >"%_RESPTMP%" 2>nul
SET "_CURLRC=%ERRORLEVEL%"
ENDLOCAL & SET "_CURLRC=%_CURLRC%"
GOTO :EOF

:: ---------------------------------------------------------------
:: Subroutine: ISFILEOLD_RAW
:: Sets _ISOLD=1 if the current file is older than/equal to MAX_AGE days,
:: else 0, while delayed expansion is disabled.
:: ---------------------------------------------------------------
:ISFILEOLD_RAW
SETLOCAL DisableDelayedExpansion
SET "_ISOLD=0"
IF "%_AGEDIR%"=="" GOTO :ISFILEOLDRETURN
IF "%_AGENAME%"=="" GOTO :ISFILEOLDRETURN

FORFILES /P "%_AGEDIR%" /M "%_AGENAME%" /D -%_MAXAGE% /C "cmd /c if @isdir==FALSE exit /b 0" >nul 2>nul
IF NOT ERRORLEVEL 1 SET "_ISOLD=1"

:ISFILEOLDRETURN
ENDLOCAL & SET "_ISOLD=%_ISOLD%"
GOTO :EOF

:DONE

:: CLEANUP -------------------------------------------------------
IF EXIST "!_FILELIST!" DEL "!_FILELIST!" 2>nul
IF EXIST "!_RESPTMP!" DEL "!_RESPTMP!" 2>nul
IF EXIST "!_RESPTMP!.hdr" DEL "!_RESPTMP!.hdr" 2>nul
IF EXIST "!_RESPTMP!.code" DEL "!_RESPTMP!.code" 2>nul

:: SUMMARY -------------------------------------------------------
ECHO.
ECHO [+] Done. scanned=!_SCANNED! submitted=!_SUBMITTED! skipped=!_SKIPPED! failed=!_FAILED!

:: EXIT CODE: 1 if any uploads failed, 0 otherwise
IF !_FAILED! GTR 0 (
    ENDLOCAL
    EXIT /b 1
)
ENDLOCAL
EXIT /b 0
