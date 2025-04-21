# Update-PostgreSQL.ps1

## Overview
This PowerShell script updates PostgreSQL to version 15.12 to address the vulnerability (CVE-2025-1094). It is designed for use on Veeam Backup & Replication (B&R) machines. The script performs the following tasks:
- Checks if PostgreSQL is installed and verifies the version.
- If PostgreSQL is not found or is already up to date, the script will exit.
- Downloads and installs the latest version of PostgreSQL if necessary.
- Disables any enabled Veeam jobs before the update and re-enables them afterward.
- Offers to restart the machine to complete the installation. A scheduled task and a temporary script re-enable the jobs post reboot.

## Prerequisites
- Ensure the script is run with administrative privileges.
- PowerShell 5.1 or later.

## Usage
To use this script, follow these steps:

1. Download the script:
    ```powershell
    wget -uri 'https://raw.githubusercontent.com/stangh/Update-PostgreSQL/refs/heads/main/Update-PostgreSQL.ps1' -UseBasicParsing | iex
    ```

2. Run the script:
    ```powershell
    Update-PostgreSQL
    ```

## Parameters
- `PostgreSQLPath`: The path to the PostgreSQL installation. Default is `"C:\Program Files\PostgreSQL\15"`.

## Examples
```powershell
# Run the script with the default PostgreSQL path
Update-PostgreSQL

# Run the script with a custom PostgreSQL path
Update-PostgreSQL -PostgreSQLPath "D:\PostgreSQL\15"
```
## Links
- [Veeam Knowledge Base](https://www.veeam.com/kb4386)
- [PostgreSQL Downloads](https://www.enterprisedb.com/downloads/postgres-postgresql-downloads)
- [Veeam System Requirements](https://helpcenter.veeam.com/docs/backup/vsphere/system_requirements.html?zoom_highlight=versions%20of%20PostgreSQL&ver=120)

## License
This script is provided as-is without any warranty. Use at your own risk.