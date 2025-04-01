function Update-PostgreSQL {
    <#
    .SYNOPSIS
    Updates PostgreSQL to version 15.12, to address vulnerability (CVE-2025-1094).
    .DESCRIPTION
    This script updates PostgreSQL on Veeam B&R machines to version 15.12.
    It checks if PostgreSQL is installed, verifies the version, and if necessary, downloads and installs the latest version.
    It also disables any enabled Veeam jobs before the update and re-enables them afterward.
    It then offers to restart the machine to complete the installation.
    .PARAMETER PostgreSQLPath
    The path to the PostgreSQL installation. The default is "C:\Program Files\PostgreSQL\15".
    .EXAMPLE
    Update-PostgreSQL
    This command runs the script to update PostgreSQL to version 15.12.
    .NOTES
    Ensure the script is run with administrative privileges.

    To use this script, run "wget -uri 'https://raw.githubusercontent.com/stangh/Update-PostgreSQL/refs/heads/main/Update-PostgreSQL.ps1' -UseBasicParsing | iex" to download and load the script into memory.
    Then run 'Update-PostgreSQL' to execute the script.
    .LINK
    https://www.veeam.com/kb4386
    https://www.enterprisedb.com/downloads/postgres-postgresql-downloads
    https://helpcenter.veeam.com/docs/backup/vsphere/system_requirements.html?zoom_highlight=versions%20of%20PostgreSQL&ver=120
    #>
    [CmdletBinding()]
    param (
        [string]$PostgreSQLPath = "C:\Program Files\PostgreSQL\15",
        [version]$desiredVersion = "15.12",
        [switch]$Restart = $false
    )
    
    # Check if the script is running with administrative privileges
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Host "This script must be run as an administrator. Please run PowerShell as admin."
        return
    }

    # Check if PostgreSQL is installed
    if (Test-Path $PostgreSQLPath) {
        Write-Host "PostgreSQL is found at $PostgreSQLPath."
    }
    else {
        Write-Host "PostgreSQL not found at $PostgreSQLPath. Exiting."
        return
    }

    # Check if PostgreSQL or Microsoft SQL Server is being used by Veeam
    $veeamService = Get-Service -Name "*PostgreSQL*" -ErrorAction SilentlyContinue
    if ($veeamService -and $veeamService.Status -ne 'Running') {
        Write-Host "The PostgreSQL service is not running. Veeam is likely using Microsoft SQL Server. Exiting."
        return
    }

    #Check the PostgreSQL version installed
    Write-Host "Checking PostgreSQL version installed."
    if ((Test-Path "$PostgreSQLPath\bin\pg_ctl.exe")) {
        $currentVersion = [version](Get-Item "$PostgreSQLPath\bin\pg_ctl.exe").VersionInfo.ProductVersion
        # Check if $currentVersion is populated correctly and is of object type version
        if ($null -eq $currentVersion -or $currentVersion.GetType().Name -ne 'Version') {
            Write-Host "Failed to retrieve the current PostgreSQL version. Exiting."
            return
        }
        Write-Debug "VersionInfo retrieved. Current PostgreSQL version: $currentVersion. Desired version: $desiredVersion."
        if ($currentVersion -lt $desiredVersion) {
            Write-Host "PostgreSQL version $currentVersion is installed. Updating to version 15.12."
        }
        else {
            Write-Host "PostgreSQL is already up to date with version $currentVersion installed. No further action required."
            return
        }
    } # if Test-Path "$PostgreSQLPath\bin\pg_ctl.exe"
    else {
        Write-Host "pg_ctl.exe not found in $PostgreSQLPath\bin. Exiting."
        return
    }

    # Save a list of Veeam jobs that are enabled and disable them before the update
    Write-Host "Retrieving list of enabled Veeam jobs and disabling them for the update."
    $enabledVeeamJobs = Get-VBRJob -WarningAction SilentlyContinue | Where-Object { $_.IsScheduleEnabled -eq $true }
    # check if Get-VBR returned any warning messages and if so, exit the script
    if ($? -eq $false) {
        Write-Host "Error retrieving Veeam jobs. Please check the Veeam Backup & Replication console for any issues."
        return
    }
    elseif ($enabledVeeamJobs.Count -eq 0) {
        Write-Host "No enabled Veeam jobs found."
        return
    }
    else {
        # check that there are no actively running jobs before proceeding with disabling them
        $RunningJobs = $enabledVeeamJobs | Where-Object {
            ($_.IsRunning -eq $true -and $_.IsIdle -eq $false) # the addition of IsIdle $false is needed for continuously running cloud jobs who always return IsRunning $true
        }
        if ($RunningJobs.Count -eq 0) {
            Write-Host "No Veeam jobs are currently running. Proceeding to disable the jobs."
            foreach ($job in $enabledVeeamJobs) {
                # Disable the Veeam job
                Write-Host "Disabling Veeam job: $($job.Name)"
                $job | Disable-VBRJob -WarningAction SilentlyContinue | Out-Null
            }
            # Check if any Veeam jobs are still enabled
            $still_EnabledJobs = Get-VBRJob -WarningAction SilentlyContinue | Where-Object { $_.IsScheduleEnabled -eq $true }
            if ($still_EnabledJobs.Count -gt 0) {
                Write-Host "Some Veeam jobs are still enabled. Please disable them manually before proceeding.`nExiting script."
                return
            }
        }
        else {
            Write-Host "Veeam job(s) are currently running. Please wait for them to finish before proceeding.`nExiting script."
            return
        }
    } 
    
    # Stop all Veeam services
    Write-Host "Stopping all Veeam services."
    Get-Service Veeam* -ErrorAction SilentlyContinue | Stop-Service -Force
    if (Get-Service Veeam* | Where-Object { $_.Status -eq 'Running' }) {
        Write-Host "Some Veeam services are still running. Killing the processes and checking the services again."
        Get-Process *veeam* -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 5
        if (Get-Service *Veeam* | Where-Object { $_.Status -eq 'Running' }) {
            Write-Host "Failed to stop all Veeam services. Please check manually."
            return
        }
    }

    # Check if the C:\Temp directory exists, if not create it
    if (-not (Test-Path "C:\Temp")) {
        Write-Host "Creating C:\Temp directory for installer download."
        # create flag to note that the directory was not found and was created so it can be removed later
        $tempDirCreated = $true
        New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
    }

    # Download PostgreSQL version 15.12 installer
    Write-Host "Downloading PostgreSQL version 15.12 installer and saving to C:\Temp\PostgreSQL-15.12-1-windows-x64.exe"
    # Retrive the current value for $ProgressPreference, set it to 'SilentlyContinue' to suppress the progress bar for a much quicker download, then reset it to its original value
    $originalProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    # Use Invoke-WebRequest to download the installer, if it fails, use WebClient.DownloadFile as a fallback
    Invoke-WebRequest -Uri "https://sbp.enterprisedb.com/getfile.jsp?fileid=1259414" -OutFile "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe"
    $ProgressPreference = $originalProgressPreference

    # Check if the download using Invoke-WebRequest was successful
    if (-not (Test-Path "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe")) {
        Write-Host "Download failed using Invoke-WebRequest. Attempting to download using WebClient."
        try {
            # Using WebClient.DownloadFile method to download the installer
            (New-Object System.Net.WebClient).DownloadFile("https://sbp.enterprisedb.com/getfile.jsp?fileid=1259414", "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe")
        }
        catch {
            Write-Host "Failed to download PostgreSQL installer. Error: $_"
            return
        }
    } # if download was not successful

    # Confirm the installer file exists after download and check the hash to ensure it was downloaded correctly
    if (-not (Test-Path "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe")) {
        Write-Host "Failed to download PostgreSQL installer. Exiting."
        return
    }
    else {
        # Check the hash of the downloaded file to ensure it is correct
        Write-Host "Verifying the hash of the downloaded PostgreSQL installer."
        $expectedHash = "2DFA43460950C1AECDA05F40A9262A66BC06DB960445EA78921C78F84377B148" # SHA256 hash of the installer
        $actualHash = (Get-FileHash "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe" -Algorithm SHA256).Hash
        if ($actualHash -ne $expectedHash) {
            Write-Host "Downloaded PostgreSQL installer hash does not match the expected hash. 
            Re-enable the Veeam jobs, start Veeam services, and remove the downloaded file. Exiting."
            return
        }
        Write-Host "PostgreSQL installer downloaded successfully.`nProceeding with the installation."
    }

    # Install PostgreSQL silently
    # Ensure no pgAdmin processes are running before installation
    Get-Process *pgAdmin* -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 5
    $processOptions = @{
        FilePath     = "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe"
        ArgumentList = "--mode unattended", "--disable-components stackbuilder"
        NoNewWindow  = $true
        Wait         = $true
        PassThru     = $true
    }
    $Process = Start-Process @processOptions -PassThru
    # retrieve installation process exit code
    $exitCode = $Process.ExitCode
    Write-Host "ExitCode: $($exitCode)"

    if ($exitCode -ne 0) {
        Write-Host "PostgreSQL installation failed with exit code: $exitCode.Please look into this."
    }
    else {
        Write-Host "PostgreSQL installation completed successfully."
        
        # Remove the installer file
        if (Test-Path "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe") {
            Write-Host "Removing the installer file."
            Remove-Item "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe" -Force
            # Test if the installer file was removed successfully
            if (-not (Test-Path "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe")) {
                Write-Host "Installer file removed successfully."
            }
            else {
                Write-Host "Failed to remove the installer file. Please delete it manually."
            }
        } # if Test-Path installer file
        
        # Remove the temporary directory if it was created in this script
        if ($tempDirCreated -and (Test-Path "C:\Temp")) {
            Write-Host "Removing the temporary directory C:\Temp."
            Remove-Item "C:\Temp" -Recurse -Force
            # Test if the temporary directory was removed successfully
            if (-not (Test-Path "C:\Temp")) {
                Write-Host "Temporary directory C:\Temp removed successfully."
            }
            else {
                Write-Host "Failed to remove the temporary directory C:\Temp. Please delete it manually."
            }
        } # if $tempDirCreated -and Test-Path temp directory
    } # if $exitCode -eq 0

    Write-Host "The following Veeam jobs were disabled before the update and should be re-enabled:`n$($enabledVeeamJobs.Name)"
    # Re-enable the Veeam jobs after the update
    Write-Host "Re-enabling Veeam jobs."
    foreach ($job in $enabledVeeamJobs) {
        # Write-Host "Re-enabling Veeam job: $($job.Name)"
        $job | Enable-VBRJob -WarningAction SilentlyContinue | Out-Null
        # check if the job was re-enabled successfully
        $reEnabledJob = Get-VBRJob -Name $job.Name -WarningAction SilentlyContinue
        if ($reEnabledJob.IsScheduleEnabled -eq $true) {
            Write-Host "Veeam job $($job.Name) re-enabled successfully."
        }
        else {
            Write-Host "Failed to re-enable Veeam job $($job.Name). Please manually re-enable the job."
        }
    } # foreach ($job in $enabledVeeamJobs)
   
    # Restart the machine to complete the installation if $exitCode is 0
    if ($exitCode -eq 0) {
        Write-Host "A restart is required to finalize the installation."
        if ($Restart) {
            Write-Host "Restarting the machine."
            Restart-Computer -Force
        } # if $restart
        else {
            # Prompt the user to restart the machine
            $Answer = Read-Host "Restart now? (Y/N)"
            # Restart the server
            if ($Answer -eq 'Y') {
                Restart-Computer -Force
            }
            else {
                Write-Host "Please remember to restart the machine later to complete the installation."
                # Offer to start Veeam services now
                $Answer2 = Read-Host "Start Veeam services now? (Y/N)"
                if ($Answer2 -eq 'Y') {
                    Write-Host "Starting all Veeam services."
                    Get-Service Veeam* -ErrorAction SilentlyContinue | Start-Service -PassThru
                }
                else {
                    Write-Host "Don't forget to start the Veeam services manually since they were stopped by this script and the machine has not yet been restarted."
                }
            } # if no restart
        } # else no $Restart
    } # if $exitCode -eq 0
} # function Update-PostgreSQL

# When running via NinjaOne: Update-PostgreSQL -Restart