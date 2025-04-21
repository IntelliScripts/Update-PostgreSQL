function Update-PostgreSQL {
    <#
    .SYNOPSIS
    Updates PostgreSQL to version 15.12, to address vulnerability CVE-2025-1094.

    .DESCRIPTION
    This script updates PostgreSQL on Veeam B&R machines to version 15.12.
    It checks if PostgreSQL is installed, verifies the version, and if necessary, downloads and installs the latest version.
    It also disables any enabled Veeam jobs before the update and re-enables them afterward.
    It then offers to restart the machine to complete the installation.

    .PARAMETER PostgreSQLPath
    The path to the PostgreSQL installation. The default is "C:\Program Files\PostgreSQL\15".
    If this parameter is explicitly provided, the script validates that the specified path exists. If the path does not exist, the script exits with an error.
    The script will also check if the path contains "PostgreSQL" in the name to ensure it is a valid installation path.

    .PARAMETER desiredVersion
    The desired version of PostgreSQL to install. The default is "15.12".
    Uses the type [version] to ensure the version is in the correct format.

    .PARAMETER Restart
    A switch to indicate whether to restart the machine after the update. The default is $false.
    If this switch is specified, the script creates a scheduled task to re-enable Veeam jobs after the restart. The scheduled task runs a temporary script that waits for 5 minutes before re-enabling the jobs. 
    After the jobs are re-enabled, the scheduled task and the temporary script are automatically deleted.

    .PARAMETER SkipIfNotInUse
    A switch to skip the update if PostgreSQL is not currently in use. The default is $false.
    If this switch is specified, the script will exit without performing the update if PostgreSQL is not actively being used.

    .PARAMETER LogFilePath
    The path to the log file where the script logs its actions. The default is "C:\Temp\PostgreSQL_Update.log".
    If the Restart switch is specified, the logging will continue (in the scheduled task script after the reboot) in the same log file.

    .EXAMPLE
    Update-PostgreSQL
    This command runs the script to update PostgreSQL to version 15.12. 
    It will proceed with the update even if PostgreSQL is not currently in use.

    .EXAMPLE
    Update-PostgreSQL -SkipIfNotInUse
    This command runs the script to update PostgreSQL to version 15.12, but it will skip the update if PostgreSQL is not currently in use.

    .EXAMPLE
    Update-PostgreSQL -Restart
    This command runs the script to update PostgreSQL to version 15.12 and restarts the machine after the update is complete. 
    A scheduled task is created to re-enable Veeam jobs after the restart, and the task and temporary script are automatically deleted after execution.

    .EXAMPLE
    Update-PostgreSQL -SkipIfNotInUse -Restart -logFilePath "C:\Update.log"
    This command runs the script to update PostgreSQL to version 15.12, skips the update if PostgreSQL is not in use, and restarts the machine if the update is performed successfully.
    A scheduled task is created to re-enable Veeam jobs after the restart, and the task and temporary script are automatically deleted after execution.
    The script logs are saved to "C:\Update.log".

    .NOTES
    Ensure the script is run with administrative privileges.

    To use this script, run "wget -uri 'https://raw.githubusercontent.com/IntelliScripts/Update-PostgreSQL/refs/heads/main/Update-PostgreSQL.ps1' -UseBasicParsing | iex" to download and load the script into memory.
    Then run 'Update-PostgreSQL', adding parameters as needed, to execute the script.

    If running via NinjaOne, the script can be run with the following environment variables:
    $Env:PostgreSQLPath, $Env:Restart, and $Env:SkipIfNotInUse.
    NinjaOne will check the parameters supplied when running the automation via the NinjaOne interface, and add the appropriate parameters based on their presence or values.

    .LINK
    https://www.veeam.com/kb4386
    https://www.enterprisedb.com/downloads/postgres-postgresql-downloads
    https://helpcenter.veeam.com/docs/backup/vsphere/system_requirements.html?zoom_highlight=versions%20of%20PostgreSQL&ver=120
    #>
    [CmdletBinding()]
    param (
        # Path to the PostgreSQL installation
        [string]$PostgreSQLPath = "C:\Program Files\PostgreSQL\15",
        
        [version]$desiredVersion = "15.12",
        
        [switch]$Restart = $false,
        
        [switch]$SkipIfNotInUse = $false, # Switch to skip the update if PostgreSQL is not in use

        [string]$LogFilePath = "C:\Temp\PostgreSQL_Update.log"
    )

    function Write-Log {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Message,
    
            [Parameter(Mandatory = $false)]
            [string]$LogPath = $LogFilePath,
    
            [Parameter(Mandatory = $false)]
            [ValidateSet("Info", "Warning", "Error")]
            [string]$Severity = "Info"
        )
        $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $LogEntry = "[$Timestamp] [$Severity] $Message"
    
        switch ($Severity) {
            "Warning" {
                Write-Warning $Message
            }
            "Error" {
                Write-Host $Message -ForegroundColor Red
            }
            default {
                Write-Host $Message
            }
        }
        Add-Content -Path $LogPath -Value $LogEntry
    } # function Write-Log
    

    Write-Log "<<< Starting PostgreSQL update script >>>"
    Write-Log "The log file for this script is located at: $($LogFilePath)."

    # Validate the PostgreSQLPath parameter (only if provided)
    if ($PSBoundParameters.ContainsKey('PostgreSQLPath')) {
        if (-not (Test-Path $PostgreSQLPath)) {
            Write-Log "Error: The specified PostgreSQLPath '$PostgreSQLPath' does not exist. Exiting the script." -Severity Error
            return
        }
        elseif ($PostgreSQLPath -notlike "*PostgreSQL*") {
            Write-Log "Error: The specified PostgreSQLPath '$PostgreSQLPath' does not appear to be a valid PostgreSQL installation path. Exiting the script." -Severity Error
            return
        }
    }

    # Check if the script is running with administrative privileges
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Log "This script must be run as an administrator. Please run PowerShell as admin."
        Write-Log "The script is currently being run under the account: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        return
    }

    # Check if PostgreSQL is installed
    if (Test-Path $PostgreSQLPath) {
        Write-Log "PostgreSQL is found at $PostgreSQLPath."
    }
    else {
        Write-Log "PostgreSQL not found at $PostgreSQLPath. Exiting."
        return
    }

    # Check if PostgreSQL or Microsoft SQL Server is being used by Veeam
    $PostgreSQL_Service = Get-Service -Name "*PostgreSQL*" -ErrorAction SilentlyContinue
    if ($PostgreSQL_Service -and $PostgreSQL_Service.Status -ne 'Running') {
        Write-Log "The PostgreSQL service is not running. Veeam is likely using Microsoft SQL Server."
        if ($SkipIfNotInUse) {
            Write-Log "The -SkipIfNotInUse switch was specified. Exiting the script."
            return
        }
        else {
            Write-Log "The -SkipIfNotInUse switch was not specified. Proceeding with the update."
        }
    }

    #Check the PostgreSQL version installed
    Write-Log "Checking PostgreSQL version installed."
    if ((Test-Path "$PostgreSQLPath\bin\pg_ctl.exe")) {
        $currentVersion = [version](Get-Item "$PostgreSQLPath\bin\pg_ctl.exe").VersionInfo.ProductVersion
        # Check if $currentVersion is populated correctly and is of object type version
        if ($null -eq $currentVersion -or $currentVersion.GetType().Name -ne 'Version') {
            Write-Log "Failed to retrieve the current PostgreSQL version. Exiting."
            return
        }
        Write-Debug "VersionInfo retrieved. Current PostgreSQL version: $currentVersion. Desired version: $desiredVersion."
        if ($currentVersion -lt $desiredVersion) {
            Write-Log "PostgreSQL version $currentVersion is installed. Updating to version 15.12."
        }
        else {
            Write-Log "PostgreSQL is already up to date with version $currentVersion installed. No further action required."
            Write-Log "Exiting the script."
            return
        }
    } # if Test-Path "$PostgreSQLPath\bin\pg_ctl.exe"
    else {
        Write-Log "pg_ctl.exe not found in $PostgreSQLPath\bin. Exiting."
        return
    }

    # Save a list of Veeam jobs that are enabled and disable them before the update
    Write-Log "Retrieving list of enabled Veeam jobs and disabling them for the update."
    # Cannot use the IsScheduleEnabled property below as in some instances that property does not return the correct value and instead shows "1/1/0001 12:00:00 AM"..
    # $enabledVeeamJobs = Get-VBRJob -WarningAction SilentlyContinue | Where-Object { $_.IsScheduleEnabled -eq $true -and $_.LatestRunLocal -gt (Get-Date).AddDays(-14) }

    # Get a list of 'backups' with recently created restore points (from within the last 2 weeks)
    $BackupObjects = Get-VBRBackup | Where-Object { ( ($_ | Get-VBRRestorePoint | Sort-Object CreationTime -Descending | Select-Object -First 1).CreationTime -gt ((Get-Date).AddDays(-14)) ) }
    # Get a list of Veeam jobs from the above list that are enabled (have a schedule set)
    $enabledVeeamJobs = Get-VBRJob -WarningAction SilentlyContinue | Where-Object { ($_.Name -in $BackupObjects.Name) -and ( $_.IsScheduleEnabled -eq $true) }

    # check if the last command returned any warning messages
    if ($? -eq $false) {
        Write-Log "Error retrieving Veeam jobs. Please check the Veeam Backup & Replication console for any issues."
        return
    }
    elseif ($enabledVeeamJobs.Count -eq 0) {
        Write-Log "No enabled (or enabled and recently run) Veeam jobs found."
        # set flag to note that there were no enabled jobs found so the script does not try enabling them later
        $noEnabledJobs = $true
    }
    else {
        # check that there are no actively running jobs before proceeding with disabling them
        $RunningJobs = $enabledVeeamJobs | Where-Object {
            ($_.IsRunning -eq $true -and $_.IsIdle -eq $false) 
            # the addition of IsIdle $false is needed for continuously running cloud jobs who always return IsRunning $true
        }
        if ($RunningJobs.Count -eq 0) {
            Write-Log "No Veeam jobs are currently running. Proceeding with disabling the jobs."
            foreach ($job in $enabledVeeamJobs) {
                # Disable the Veeam job
                Write-Log "Disabling Veeam job: $($job.Name)"
                $job | Disable-VBRJob -WarningAction SilentlyContinue | Out-Null
            }
            # Check if any Veeam jobs are still enabled
            # $still_EnabledJobs = Get-VBRJob -WarningAction SilentlyContinue | Where-Object { $_.IsScheduleEnabled -eq $true -and $_.LatestRunLocal -gt (Get-Date).AddDays(-14) }
            $BackupObjects = Get-VBRBackup | Where-Object { ( ($_ | Get-VBRRestorePoint | Sort-Object CreationTime -Descending | Select-Object -First 1).CreationTime -gt ((Get-Date).AddDays(-14)) ) }
            $still_EnabledJobs = Get-VBRJob -WarningAction SilentlyContinue | Where-Object { ($_.Name -in $BackupObjects.Name) -and ( $_.IsScheduleEnabled -eq $true) }

            if ($still_EnabledJobs.Count -gt 0) {
                Write-Log "Some Veeam jobs are still enabled. Please disable them manually before proceeding."
                Write-Log "Exiting script."
                return
            }
        }
        else {
            Write-Log "Veeam job(s) are currently running. Please wait for them to finish before proceeding."
            Write-Log "Exiting script."
            return
        }
    } 
    
    # Stop all Veeam services
    Write-Log "Stopping all Veeam services."
    Get-Service Veeam* -ErrorAction SilentlyContinue | Stop-Service -Force -WarningAction SilentlyContinue
    # Check if any Veeam services are still running after stopping them
    if (Get-Service Veeam* | Where-Object { $_.Status -eq 'Running' }) {
        Write-Log "Some Veeam services are still running. Killing the processes and checking the services again."
        Get-Process *veeam* -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 5
        if (Get-Service *Veeam* | Where-Object { $_.Status -eq 'Running' }) {
            Write-Log "Failed to stop all Veeam services. Please check manually."
            return
        }
    }

    # Check if the C:\Temp directory exists, if not create it
    if (-not (Test-Path "C:\Temp")) {
        Write-Log "Creating C:\Temp directory for installer download."
        # create flag to note that the directory was not found and was created so it can be removed later
        $tempDirCreated = $true
        New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
    }

    # Download PostgreSQL version 15.12 installer
    Write-Log "Downloading PostgreSQL version 15.12 installer and saving to C:\Temp\PostgreSQL-15.12-1-windows-x64.exe"
    # Retrive the current value for $ProgressPreference, set it to 'SilentlyContinue' to suppress the progress bar for a much quicker download, then reset it to its original value
    $originalProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    # Use Invoke-WebRequest to download the installer, if it fails, use WebClient.DownloadFile as a fallback
    Invoke-WebRequest -Uri "https://sbp.enterprisedb.com/getfile.jsp?fileid=1259414" -OutFile "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe"
    $ProgressPreference = $originalProgressPreference

    # Check if the download using Invoke-WebRequest was successful
    if (-not (Test-Path "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe")) {
        Write-Log "Download failed using Invoke-WebRequest. Attempting to download using WebClient."
        try {
            # Using WebClient.DownloadFile method to download the installer
            (New-Object System.Net.WebClient).DownloadFile("https://sbp.enterprisedb.com/getfile.jsp?fileid=1259414", "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe")
        }
        catch {
            Write-Log "Failed to download PostgreSQL installer. Error: $_"
            return
        }
    } # if download was not successful

    # Confirm the installer file exists after download and check the hash to ensure it was downloaded correctly
    if (-not (Test-Path "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe")) {
        Write-Log "Failed to download PostgreSQL installer. Exiting."
        return
    }
    else {
        # Check the hash of the downloaded file to ensure it is correct
        Write-Log "Verifying the hash of the downloaded PostgreSQL installer."
        $expectedHash = "2DFA43460950C1AECDA05F40A9262A66BC06DB960445EA78921C78F84377B148" # SHA256 hash of the installer
        $actualHash = (Get-FileHash "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe" -Algorithm SHA256).Hash
        if ($actualHash -ne $expectedHash) {
            Write-Log "Downloaded PostgreSQL installer hash does not match the expected hash. 
            Re-enable the Veeam jobs, start Veeam services, and remove the downloaded file. Exiting."
            return
        }
        Write-Log "PostgreSQL installer downloaded successfully."
        Write-Log "Proceeding with the installation. Please wait.."
    }

    # Install PostgreSQL silently

    # Close the Veeam console if it is open
    $veeamConsole = Get-Process -Name "Veeam.Backup.Shell" -ErrorAction SilentlyContinue
    if ($veeamConsole) {
        Write-Log "Closing the Veeam console."
        $veeamConsole | Stop-Process -Force
        Start-Sleep -Seconds 5
    }

    # Ensure no pgAdmin processes are running before installation
    Write-Log "Closing any pgAdmin processes before installation."
    Get-Process *pgAdmin* -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 5
    
    $processOptions = @{
        FilePath     = "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe"
        # https://silentinstallhq.com/postgresql-15-silent-install-how-to-guide/
        ArgumentList = "--mode unattended", "--unattendedmodeui none", "--disable-components stackbuilder" # remove '--unattendedmodeui none' if you want to see the installation progress
        NoNewWindow  = $true
        Wait         = $true
        PassThru     = $true
    }

    $Process = Start-Process @processOptions

    # retrieve installation process exit code
    $exitCode = $Process.ExitCode
    Write-Log "ExitCode: $($exitCode)"  

    if ($exitCode -ne 0) {
        Write-Log "PostgreSQL installation failed with exit code: $exitCode.Please look into this."
    }
    else {
        Write-Log "PostgreSQL installation completed successfully."
        
        # Remove the installer file
        if (Test-Path "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe") {
            Write-Log "Removing the installer file."
            Remove-Item "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe" -Force
            # Test if the installer file was removed successfully
            if (-not (Test-Path "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe")) {
                Write-Log "Installer file removed successfully."
            }
            else {
                Write-Log "Failed to remove the installer file. Please delete it manually."
            }
        } # if Test-Path installer file
        
        # Remove the temporary directory if it was created in this script
        if ($tempDirCreated -and (Test-Path "C:\Temp")) {
            Write-Log "Removing the temporary directory C:\Temp."
            Remove-Item "C:\Temp" -Recurse -Force
            # Test if the temporary directory was removed successfully
            if (-not (Test-Path "C:\Temp")) {
                Write-Log "Temporary directory C:\Temp removed successfully."
            }
            else {
                Write-Log "Failed to remove the temporary directory C:\Temp. Please delete it manually."
            }
        } # if $tempDirCreated -and Test-Path temp directory
    } # if $exitCode -eq 0

    if ($noEnabledJobs -eq $false) {
        Write-Log "The following Veeam jobs were disabled before the update and need to be re-enabled:`n$($enabledVeeamJobs.Name)"
        # Re-enable the Veeam jobs after the update
        Write-Log "Re-enabling Veeam jobs."
        foreach ($job in $enabledVeeamJobs) {
            # Write-Log "Re-enabling Veeam job: $($job.Name)"
            $job | Enable-VBRJob -WarningAction SilentlyContinue | Out-Null
            # check if the job was re-enabled successfully
            $reEnabledJob = Get-VBRJob -Name $job.Name -WarningAction SilentlyContinue
            if ($reEnabledJob.IsScheduleEnabled -eq $true) {
                Write-Log "Veeam job $($job.Name) re-enabled successfully."
            }
            else {
                Write-Log "Failed to re-enable Veeam job $($job.Name). Please manually re-enable the job."
            }
        } # foreach ($job in $enabledVeeamJobs)
    }
   
    # Restart the machine to complete the installation if $exitCode is 0
    if ($exitCode -eq 0) {
        Write-Log "A restart is required to finalize the installation."
        if ($Restart) {
            Write-Log "The -Restart switch was specified. Initializing restart procedure."

            # Create a scheduled task to re-enable Veeam jobs after the restart
            Write-Log "Creating a scheduled task to re-enable Veeam jobs after the restart."
            $taskScript = @"
param (
    [string]`$jobNames,
    [String]`$LogFilePath = "C:\Temp\PostgreSQL_Update.log"
)


function Write-Log {
        param(
            [Parameter(Mandatory = `$true)]
            [string]`$Message,
    
            [Parameter(Mandatory = `$false)]
            [string]`$LogPath = `$LogFilePath_taskScript,
    
            [Parameter(Mandatory = `$false)]
            [ValidateSet("Info", "Warning", "Error")]
            [string]`$Severity = "Info"
        )
        `$Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        `$LogEntry = "[`$Timestamp] [`$Severity] `$Message"
    
        switch (`$Severity) {
            "Warning" {
                Write-Warning $Message
            }
            "Error" {
                Write-Host `$Message -ForegroundColor Red
            }
            default {
                Write-Host `$Message
            }
        }
        Add-Content -Path `$LogPath -Value `$LogEntry
    } # function Write-Log

Write-Log "The machine rebooted. The post reboot script started."



# Decode the job names back into an array
`$jobNamesArray = `$jobNames -split ','

Write-Log "Waiting for 5 minutes before re-enabling the Veeam jobs, to give time for Veeam services to start etc."
Start-Sleep -Seconds 300

foreach (`$jobName in `$jobNamesArray) {
    Write-Log "Processing job: `$jobName"
    `$job = Get-VBRJob -Name `$jobName -WarningAction SilentlyContinue
    if (`$job) {
        `$job | Enable-VBRJob -WarningAction SilentlyContinue | Out-Null
        if ((Get-VBRJob -Name `$jobName -WarningAction SilentlyContinue).IsScheduleEnabled -eq `$true) {
            Write-Log "Veeam job `$jobName re-enabled successfully."
        } else {
            Write-Log "Failed to re-enable Veeam job `$jobName. Please manually re-enable the job." -Severity Warning
        }
    } else {
        Write-Log "Job `$jobName not found. Skipping."
    }
}


# Clean up: Delete the scheduled task and the temporary script
Write-Log "Cleaning up: Deleting the scheduled task and the temporary script."
`$taskName = "ReEnableVeeamJobs"
`$scriptPath = "C:\Temp\ReEnableVeeamJobs.ps1"
Unregister-ScheduledTask -TaskName `$taskName -Confirm:`$false -ErrorAction SilentlyContinue
Remove-Item -Path `$scriptPath -Force -ErrorAction SilentlyContinue

Write-Log "Post-reboot script complete."
"@

            # Save the script to a temporary file
            $taskScriptPath = "C:\Temp\ReEnableVeeamJobs.ps1"
            $enabledJobNames = $enabledVeeamJobs.Name
            Set-Content -Path $taskScriptPath -Value $taskScript

            # Join the job names into a single string, separated by a special delimiter (e.g., `,`)
            $encodedJobNames = $enabledJobNames -join ','

            # Create the scheduled task            
            $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$taskScriptPath`" -jobNames `"$encodedJobNames`" -LogFilePath `"$LogFilePath`""
            $trigger = New-ScheduledTaskTrigger -AtStartup
            $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount
            Register-ScheduledTask -TaskName "ReEnableVeeamJobs" -Action $action -Trigger $trigger -Principal $principal -Force

            Write-Log "Scheduled task created."

            # Restart the machine
            Write-Log "Restarting the machine in 15 seconds. Press 'C' to cancel the reboot."

            # Wait for 15 seconds and allow the user to cancel
            $cancelReboot = $false
            for ($i = 15; $i -gt 0; $i--) {
                Write-Host -NoNewline "`rRebooting in $i seconds... Press 'C' to cancel."
                Start-Sleep -Seconds 1
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true).Key
                    if ($key -eq 'C') {
                        $cancelReboot = $true
                        break
                    }
                }
            }

            if ($cancelReboot) {
                Write-Log "Reboot canceled by the user."
            }
            else {
                Write-Log "Proceeding with the reboot."
                Restart-Computer -Force
            }
        } # if $restart
        else {
            # Prompt the user to restart the machine
            $Answer = Read-Host "Restart now? (Y/N)"
            # Restart the server
            if ($Answer -eq 'Y') {
                Restart-Computer -Force
            }
            else {
                Write-Log "Please remember to restart the machine later to complete the installation."
                # Offer to start Veeam services now
                $Answer2 = Read-Host "Start Veeam services now? (Y/N)"
                if ($Answer2 -eq 'Y') {
                    Write-Log "Starting all Veeam services."
                    Get-Service Veeam* -ErrorAction SilentlyContinue | Start-Service -PassThru
                }
                else {
                    Write-Log "Don't forget to start the Veeam services manually since they were stopped by this script and the machine has not yet been restarted."
                }
            } # if no restart
        } # else no $Restart
    } # if $exitCode -eq 0
} # function Update-PostgreSQL



<# For use in the NinjaOne script only
if ($Env:Restart) {
    Update-PostgreSQL -Restart
}
if ($Env:SkipIfNotInUse) {
    Update-PostgreSQL -SkipIfNotInUse
}
if ($Env:Restart -and $Env:SkipIfNotInUse) {
    Update-PostgreSQL -Restart -SkipIfNotInUse
}
if ($Env:PostgreSQLPath) {
    Update-PostgreSQL -PostgreSQLPath $Env:PostgreSQLPath
}
#>