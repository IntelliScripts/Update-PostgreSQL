function Update-PostgreSQL {
    [CmdletBinding()]
    param (
        [string]$PostgreSQLPath = "C:\Program Files\PostgreSQL\15"
    )

    # Check if the script is running with administrative privileges
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Host "This script must be run as an administrator. Please run PowerShell as admin."
        return
    }

    # Check if PostgreSQL is installed
    if (Test-Path $PostgreSQLPath) {
        Write-Host "PostgreSQL is found at $PostgreSQLPath. Proceeding with update."
    }
    else {
        Write-Host "PostgreSQL not found at $PostgreSQLPath. Exiting."
        return
    }

    # Check if PostgreSQL or Microsoft SQL Server is being used by Veeam
    $veeamService = Get-Service -Name "*PostgreSQL*" -ErrorAction SilentlyContinue
    if ($veeamService -and $veeamService.Status -ne 'Running') {
        Write-Host "The PostgreSQL service is not running. Veeam is likely using Microsoft SQL Server instead. Exiting."
        return
    }

    #Check the PostgreSQL version installed
    Write-Host "Checking PostgreSQL version installed."
    if (-not (Test-Path "$PostgreSQLPath\bin\pg_ctl.exe")) {
        Write-Host "pg_ctl.exe not found in $PostgreSQLPath\bin. Exiting."
        return
    }
    $versionInfo = (Get-Item "$PostgreSQLPath\bin\pg_ctl.exe").VersionInfo.ProductVersion
    if ($versionInfo -lt "15.12") {
        Write-Host "PostgreSQL version $versionInfo is installed. Updating to version 15.12."
    }
    else {
        Write-Host "PostgreSQL is already up to date with version $versionInfo installed. No action required."
        return
    }

    # Save list of Veeam jobs that are enabled and disable them before the update
    Write-Host "Saving list of enabled Veeam jobs and disabling them for the update."
    $veeamJobs = Get-VBRJob | Where-Object { $_.IsScheduleEnabled -eq $true }
    if ($veeamJobs.Count -eq 0) {
        Write-Host "No enabled Veeam jobs found."
        return
    }
    else {
        foreach ($job in $veeamJobs) {
            Write-Host "Disabling Veeam job: $($job.Name)"
            $job | Disable-VBRJob | Out-Null
        }
        # Check if any Veeam jobs are still enabled
        $enabledJobs = Get-VBRJob | Where-Object { $_.IsScheduleEnabled -eq $true }
        if ($enabledJobs.Count -gt 0) {
            Write-Host "Some Veeam jobs are still enabled. Please disable them manually before proceeding."
            return
        }
    }
    
    # Stopping all Veeam services
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

    # Download PostgreSQL version 15.12 installer
    if (-not (Test-Path "C:\Temp")) {
        Write-Host "Creating C:\Temp directory for installer download."
        New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
    }
    Write-Host "Downloading PostgreSQL version 15.12 installer and saving to C:\Temp\PostgreSQL-15.12-1-windows-x64.exe"
    # Invoke-WebRequest -Uri "https://sbp.enterprisedb.com/getfile.jsp?fileid=1259414" -OutFile "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe"
    # Using WebClient to download the installer as Invoke-WebRequest takes a much longer time to download the file
    (New-Object System.Net.WebClient).DownloadFile("https://sbp.enterprisedb.com/getfile.jsp?fileid=1259414", "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe")
    if (-not (Test-Path "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe")) {
        Write-Host "Failed to download PostgreSQL installer. Exiting."
        return
    }
    else {
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
    $Process = Start-Process @processOptions
    # retrieve installation process exit code
    $exitCode = $Process.ExitCode
    if ($exitCode -ne 0) {
        Write-Host "PostgreSQL installation failed with exit code: $exitCode"
    }
    else {
        Write-Host "PostgreSQL installation completed successfully."
        
        # Remove the installer after installation
        if (Test-Path "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe") {
            Write-Host "Removing the installer file."
            Remove-Item "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe" -Force
        }
        # test if the installer was removed successfully
        if (-not (Test-Path "C:\Temp\PostgreSQL-15.12-1-windows-x64.exe")) {
            Write-Host "Installer file removed successfully."
        }
        else {
            Write-Host "Failed to remove the installer file. Please delete it manually."
        }
    }

    Write-Host "The following Veeam jobs were disabled before the update and should be re-enabled:`n$($veeamJobs.Name)"
    # Re-enable the Veeam jobs after the update
    $Answer1 = Read-Host "Re-enable Veeam jobs now? (Y/N)"
    if ($Answer1 -eq 'Y') {
        Write-Host "Re-enabling Veeam jobs."
        foreach ($job in $veeamJobs) {
            Write-Host "Re-enabling Veeam job: $($job.Name)"
            $job | Enable-VBRJob | Out-Null
            # check if the job was re-enabled successfully
            $reEnabledJob = Get-VBRJob -Name $job.Name
            if ($reEnabledJob.IsScheduleEnabled -eq $true) {
                Write-Host "Veeam job $($job.Name) re-enabled successfully."
            }
            else {
                Write-Host "Failed to re-enable Veeam job $($job.Name). Please check manually."
            }
        } # foreach ($job in $veeamJobs)
    } # if ($Answer1 -eq 'Y')
    else {
        Write-Host "Please remember to re-enable the Veeam jobs after the update."
    }    

    # Restart the machine to complete the installation
    Write-Host "A restart is required to finalize the installation."
    # Prompt the user to restart the machine
    $Answer = Read-Host "Restart now? (Y/N)"
    # Restart the server
    if ($Answer -eq 'Y') {
        Restart-Computer -Force
    }
    else {
        Write-Host "Please remember to restart the machine later to complete the installation."
    }
} # function Update-PostgreSQL