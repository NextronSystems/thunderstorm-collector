##################################################
# Script Title: THOR Thunderstorm Collector
# Script File Name: thunderstorm-collector.ps1  
# Author: Florian Roth 
# Version: 0.1.0
# Date Created: 07.10.2020  
# Last Modified: 07.10.2020
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

    [Parameter(HelpMessage="")]
        [Alias('S')]
        [string]$Source=$env:COMPUTERNAME,

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
        [int]$MaxSize, 

    [Parameter(HelpMessage='Extensions to select for submission (default: all of them)')] 
        [ValidateNotNullOrEmpty()] 
        [Alias('E')]    
        [string[]]$Extensions, 

    [Parameter(HelpMessage='Enables debug output and skips cleanup at the end of the scan')] 
        [ValidateNotNullOrEmpty()] 
        [Alias('D')]
        [switch]$Debugging = $False
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
[int]$MaxSize = 20

# Extensions
# Recommended Preset
[string[]]$Extensions = @('.asp','.vbs','.ps','.ps1','.rar','.tmp','.bas','.bat','.chm','.cmd','.com','.cpl','.crt','.dll','.exe','.hta','.js','.lnk','.msc','.ocx','.pcd','.pif','.pot','.reg','.scr','.sct','.sys','.url','.vb','.vbe','.vbs','.wsc','.wsf','.wsh','.ct','.t','.input','.war','.jsp','.php','.asp','.aspx','.doc','.docx','.pdf','.xls','.xlsx','.ppt','.pptx','.tmp','.log','.dump','.pwd','.w','.txt','.conf','.cfg','.conf','.config','.psd1','.psm1','.ps1xml','.clixml','.psc1','.pssc','.pl','.www','.rdp','.jar','.docm','.ace','.job','.temp','.plg','.asm')
# Collect Every Extension
#[string[]]$Extensions = @()

# Debug
$Debug = $False

# Show Help -----------------------------------------------------------
# No Thunderstorm server 
if ( $Args.Count -eq 0 -and $ThunderstormServer -eq "" ) {
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

        [Parameter(Position=1, HelpMessage="Log file to write into")] 
            [ValidateNotNullOrEmpty()] 
            [Alias('SS')]    
            [IO.FileInfo]$LogFile = "thunderstorm-collector.log",

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
        Write-Host "$($Indicator) $($Entry)" -ForegroundColor Red
    } elseif ( $Level -eq "Debug" -and $Debug -eq $False ) {
        return
    } else {
        Write-Host "$($Indicator) $($Entry)"
    }
    
    # Log File
    if ( $global:NoLog -eq $False ) {
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
$Url = "http://$($ThunderstormServer):$($ThunderstormPort)/api/checkAsync"
Write-Log "Sending to URI: $($Url)" -Level "Debug"

# ---------------------------------------------------------------------
# Run THOR Thunderstorm Collector -------------------------------------
# ---------------------------------------------------------------------
$ProgressPreference = "SilentlyContinue"
try {
    Get-ChildItem -Path $Folder -File -Recurse -ErrorAction SilentlyContinue | 
    ForEach-Object {
        # -------------------------------------------------------------
        # Filter ------------------------------------------------------        
        # Size Check
        if ( ( $_.Length / 1MB ) -gt $($MaxSize) ) {
            Write-Log "$_ skipped due to size filter" -Level "Debug" 
            return
        }
        # Age Check 
        if ( $($MaxAge) -gt 0 ) {
            if ( $_.LastWriteTime -lt (Get-Date).AddDays(-$($MaxAge)) ) {
                Write-Log "$_ skipped due to age filter" -Level "Debug" 
                return
            }
        }
        # Extensions Check
        if ( $Extensions.Length -gt 0 ) {
            if ( $Extensions -contains $_.extension ) { } else {
                Write-Log "$_ skipped due to extension filter" -Level "Debug"
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
        }
        $fileEnc = [System.Text.Encoding]::GetEncoding('UTF-8').GetString($fileBytes);
        $boundary = [System.Guid]::NewGuid().ToString();
        $LF = "`r`n";
        $bodyLines = ( 
            "--$boundary",
            "Content-Disposition: form-data; name=`"file`"; filename=`"$($_.FullName)`"",
            "Content-Type: application/octet-stream$LF",
            $fileEnc,
            "--$boundary--$LF" 
        ) -join $LF

        # Submitting the request
        $StatusCode = 0
        $Retries = 0
        while ( $($StatusCode) -ne 200 ) {
            try {
                Write-Log "Submitting to Thunderstorm server: $($_.FullName) ..." -Level "Info"
                $Response = Invoke-WebRequest -uri $($Url) -Method Post -ContentType "multipart/form-data; boundary=`"$boundary`"" -Body $bodyLines
                $StatusCode = [int]$Response.StatusCode
            } 
            # Catch all non 200 status codes
            catch {
                $StatusCode = $_.Exception.Response.StatusCode.value__
                if ( $StatusCode -eq 503 ) {
                    $WaitSecs = 3
                    if ( $_.Exception.Response.Headers['Retry-After'] ) {
                        $WaitSecs = [int]$_.Exception.Response.Headers['Retry-After']
                    }
                    Write-Log "503: Server seems busy - retrying in $($WaitSecs) seconds"
                    Start-Sleep -Seconds $($WaitSecs)
                } else {
                    if ( $Retries -eq 3) {
                        Write-Log "$($StatusCode): Server still has problems - giving up"
                        break
                    }
                    $Retries = $Retries + 1
                    $SleepTime = 2 * [Math]::Pow(2, $Retries)
                    Write-Log "$($StatusCode): Server has problems - retrying in $SleepTime seconds"
                    Start-Sleep -Seconds $($SleepTime)
                }
            }
        }
     }
} catch { 
    Write-Log "Unknown error during Thunderstorm Collection $_" -Level "Error"   
}

# ---------------------------------------------------------------------
# End -----------------------------------------------------------------
# ---------------------------------------------------------------------
$ElapsedTime = $(get-date) - $StartTime
$TotalTime = "{0:HH:mm:ss}" -f ([datetime]$elapsedTime.Ticks)
Write-Log "Scan took $($TotalTime) to complete" -Level "Information"
