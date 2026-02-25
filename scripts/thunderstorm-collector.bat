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
IF "%_DIRS%"=="" SET _DIRS=C:\Users C:\Temp C:\Windows
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
EXIT /b 1
:CURLOK
ECHO [+] Curl found: %_CURL%

:: SOURCE --------------------------------------------------------
IF "%_SRC%"=="" (
    FOR /F "tokens=*" %%i IN ('hostname') DO SET _SRC=%%i
    ECHO [+] Source: !_SRC!
)

:: COLLECTION MARKERS --------------------------------------------
:: POST begin marker to /api/collection (forward-compatible: 404 = continue)
SET _SCANID=
FOR /F "usebackq tokens=*" %%R IN (`"%_CURL%" -s -X POST -H "Content-Type: application/json" -d "{\"type\":\"begin\",\"source\":\"%_SRC%\",\"collector\":\"batch/0.5\"}" %_SCHEME%://%_TS%:%_TP%/api/collection 2^>nul`) DO (
    SET _RESP=%%R
)
IF DEFINED _RESP (
    :: Extract scan_id from JSON response (simple pattern match)
    FOR /F "tokens=2 delims=:}" %%A IN ('ECHO !_RESP! ^| FIND /I "scan_id"') DO (
        SET _SCANID=%%~A
        :: Remove surrounding quotes and spaces
        SET _SCANID=!_SCANID:"=!
        SET _SCANID=!_SCANID: =!
    )
)
IF DEFINED _SCANID (
    ECHO [+] Collection started, scan_id: !_SCANID!
    SET _IDPARAM=^&scan_id=!_SCANID!
) ELSE (
    SET _IDPARAM=
)

:: BUILD FILE LIST -----------------------------------------------
:: Phase 1: Use FORFILES to generate a filtered file list.
:: FORFILES does NOT follow junctions/reparse points, solving the infinite loop issue.

SET _FILELIST=%TEMP%\thunderstorm_files_%RANDOM%.txt
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

FOR %%T IN (%_DIRS%) DO (
    IF NOT EXIST "%%T" (
        ECHO [!] Warning: %%T does not exist, skipping.
    ) ELSE (
        IF %_DBG% == 1 ECHO [D] Scanning %%T ...
        :: FORFILES /S = recurse (skips junctions), /C = command per file
        :: @path outputs quoted full path, @isdir filters out directories
        IF DEFINED _DATEFILTER (
            FORFILES /P "%%T" /S !_DATEFILTER! /C "cmd /c if @isdir==FALSE echo @path" >>"%_FILELIST%" 2>nul
        ) ELSE (
            FORFILES /P "%%T" /S /C "cmd /c if @isdir==FALSE echo @path" >>"%_FILELIST%" 2>nul
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
IF %_TOTAL% == 0 GOTO :DONE

FOR /F "usebackq delims=" %%F IN ("%_FILELIST%") DO (
    SET /A _SCANNED+=1
    :: %%~F strips surrounding quotes from FORFILES output
    SET "_FILE=%%~F"

    :: Extension check
    SET _EXTMATCH=0
    FOR %%E IN (%_EXTS%) DO (
        IF /I "%%~xF"=="%%E" SET _EXTMATCH=1
    )
    IF !_EXTMATCH! == 0 (
        IF %_DBG% == 1 ECHO [D] Skip: !_FILE! ^(extension^)
        SET /A _SKIPPED+=1
    ) ELSE (
        :: Size check
        SET "_SZ=%%~zF"
        IF !_SZ! GTR %_MAXSZ% (
            IF %_DBG% == 1 ECHO [D] Skip: !_FILE! ^(size: !_SZ!^)
            SET /A _SKIPPED+=1
        ) ELSE (
            :: Upload
            ECHO [+] Uploading: !_FILE!
            "%_CURL%" -s -o nul -F "file=@!_FILE!" %_SCHEME%://%_TS%:%_TP%/api/checkAsync?source=%_SRC%%_IDPARAM%
            IF !ERRORLEVEL! == 0 (
                SET /A _SUBMITTED+=1
            ) ELSE (
                ECHO [-] Failed: !_FILE! ^(curl exit: !ERRORLEVEL!^)
                SET /A _FAILED+=1
            )
        )
    )
)

:DONE
:: COLLECTION END MARKER -----------------------------------------
IF DEFINED _SCANID (
    "%_CURL%" -s -o nul -X POST -H "Content-Type: application/json" -d "{\"type\":\"end\",\"source\":\"%_SRC%\",\"collector\":\"batch/0.5\",\"scan_id\":\"%_SCANID%\",\"stats\":{\"scanned\":%_SCANNED%,\"submitted\":%_SUBMITTED%,\"skipped\":%_SKIPPED%,\"failed\":%_FAILED%}}" %_SCHEME%://%_TS%:%_TP%/api/collection 2>nul
)

:: CLEANUP -------------------------------------------------------
IF EXIST "%_FILELIST%" DEL "%_FILELIST%" 2>nul

:: SUMMARY -------------------------------------------------------
ECHO.
ECHO [+] Done. scanned=%_SCANNED% submitted=%_SUBMITTED% skipped=%_SKIPPED% failed=%_FAILED%

ENDLOCAL
EXIT /b 0
