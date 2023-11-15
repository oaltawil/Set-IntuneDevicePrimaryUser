<#
.NOTES
This sample script is not supported under any Microsoft standard support program or service. The sample script is provided AS IS without warranty of any kind. Microsoft disclaims all implied warranties including, without limitation, any implied warranties of merchantability or of fitness for a particular purpose. The entire risk arising out of the use or performance of the sample script remains with you. 
In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the script be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the sample script, even if Microsoft has been advised of the possibility of such damages.

.SYNOPSIS
The Set-IntuneDevicePrimaryUser.ps1 script configures the primary user of an Intune device to the user with the highest number of sign-ins to the device.

.DESCRIPTION
1. The script requires a list of devices in a comma-separated value file with 2 column headers: DeviceId and DisplayName, where Device Id is the Intune Device Id.
2. The script retrieves all the Sign In Audit logs for the "Windows Sign In" application for the last 30 days
3. For each device in the list, the script determines the user with the highest number of sign-ins to Windows.
4. The script compares and updates the Intune device's primary user to the most frequently signed-in user.
5. The script creates a Csv file in the same folder as the script titled "IntuneDevices-PrimaryUsers-<Date>" with the following details: "IntuneDeviceId,DisplayName,CurrentPrimaryUser,NewPrimaryUser,Modified"

Notes:
- Please note that the script uses the Intune Device Id - and not the Display Name - when filtering the Sign In Logs and when configuring the Intune device.
- The script will skip a device if any of the following conditions happen:
    - The device is not managed by Intune
    - The most-frequently signed-in user could not be determined, e.g. there are no sign-in events to Windows
    - The most-frequently signed-in user does not exist in Azure AD

.PARAMETER DevicesInputFilePath
A comma-separated value file with 2 column headers: DeviceId and DisplayName. Example:
    IntuneDeviceId,DisplayName
    0159b6fb-89a7-4bf1-abf8-cc178be41a7a,Laptop-001
    8b8b5c16-91b0-4b4e-8225-247c8a43da6a,Desktop-020

.EXAMPLE
.\Set-IntuneDevicePrimaryUser.ps1 -DevicesInputFilePath "~\Documents\Devices.csv"
#>

[CmdletBinding()]
param (
  [String]
  [Parameter(Mandatory, Position=0)]
  $DevicesInputFilePath
)


# The script will stop execution upon encountering any errors
$ErrorActionPreference = 'Stop'

# Retrieve the parent directory containing the script
$WorkingDirectoryPath = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

# Generate the output file name
$OutputFileName = "IntuneDevices-PrimaryUsers-$((Get-Date).ToShortDateString())"

# Join the script's parent folder with the output file name
$OutputFilePath = Join-Path -Path $WorkingDirectoryPath -ChildPath $OutputFileName

# The first line of the output file contains the column headers of the Csv file
Set-Content -Path $OutputFilePath -Value "IntuneDeviceId,DisplayName,CurrentPrimaryUser,NewPrimaryUser,Modified"

#
#
# 1. Import the Devices Csv File
#
#

# Verify that the Csv input file path is valid
Get-Item -Path $DevicesInputFilePath

# Import the contents of the Csv file into a collection of PSCustomObject objects
$AllDevices = Import-Csv -Path $DevicesInputFilePath

# Retrieve the note properties (static properties) of the PSCustomObject objects
$ColumnHeaders = $AllDevices | Get-Member -MemberType NoteProperty | Sort-Object -Property Name -Descending

# Verify that the PSCustomObject objects have 2 properties: DeviceId and DisplayName
if (($ColumnHeaders[0].Name -ne "IntuneDeviceId") -or ($ColumnHeaders[1].Name -ne "DisplayName")) {

    Write-Error "The script requires a Csv file that has 2 column headers: IntuneDeviceId and DisplayName."

}

#
#
# 2. Retreive the Sign In Audit Logs 
#
#

# Connect to Microsoft Graph and request the ability to read Audit logs and Users and modify Intune Devices
Connect-MgGraph -Scopes AuditLog.Read.All, User.Read.All, DeviceManagementManagedDevices.ReadWrite.All

# Retrieve all the sign-in events to Windows
$AllSignInLogs = Get-MgAuditLogSignIn -All -Filter "appDisplayName eq 'Windows Sign In'"

foreach ($Device in $AllDevices) {

    #
    #
    # Verify that the device is managed by Intune
    #
    #

    # Save the Device Display Name
    $DisplayName = $Device.DisplayName

    # Save the Azure AD Device Id
    $IntuneDeviceId = $Device.IntuneDeviceId

    Write-Host "`nProcessing Device $DisplayName"
    
    # Retrieve the Intune managed device using its Intune Device Id
    $ManagedDevice = Get-MgDeviceManagementManagedDevice -ManagedDeviceId $IntuneDeviceId

    # If the device is not managed by Intune, print a warning and skip to the next device
    if (-not $ManagedDevice) {

        Write-Warning "Failed to retrieve the Intune managed device with Display Name $DisplayName and Intune Device ID $IntuneDeviceId."

        # Skip this particular device and move on to the next one
        Continue
    }
    else {

        $AzureADDeviceId = $ManagedDevice.AzureAdDeviceId
    }

    #
    #
    # 3. Determine the most frequently signed-in user to the device
    #
    #

    # Filter the Sign-In Logs for the Azure AD Device Id
    $DeviceSignInLogs = $AllSignInLogs | Where-Object {$_.DeviceDetail.DeviceId -eq $AzureADDeviceId}

    # Group the Sign-In Events by the User Principal Name and sort the groups by the number of elements they contain (Count)
    $MostFrequentUpn = $DeviceSignInLogs | Where-Object {$_.UserPrincipalName} | Group-Object -Property UserPrincipalName -NoElement | Sort-Object -Descending -Property Count | Select-Object -First 1 | ForEach-Object {$_.Name}

    # The most frequent user has been determined
    if ($MostFrequentUpn) {

        # Retrieve the Azure AD User with matching Upn
        $MostFrequentUser = Get-MgUser -Filter "UserPrincipalName eq '$MostFrequentUpn'"

        # Verify that the most frequent user has a valid Azure AD User object
        if (-not $MostFrequentUser) {
    
            Write-Warning "Unable to find the Azure AD User $MostFrequentUpn."

            Continue

        }

        #
        #
        # 4.Compare and update the Intune device's primary user 
        #
        #

        # Retrieve the device's primary user
        $PrimaryUser = Get-MgDeviceManagementManagedDeviceUser -ManagedDeviceId $IntuneDeviceId

        # The device has a primary user
        if ($PrimaryUser) {

            $PrimaryUserUpn = $PrimaryUser.UserPrincipalName

            # The most frequent user is the same as the primary user
            if ($MostFrequentUpn -eq $PrimaryUserUpn) {

                $Modified = "No"
            }
            # The most frequent user is different than the primary user
            else {
                
                # Generate the Http REST API call by defining its URI, Body, and Method
                $Uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$IntuneDeviceId')/users/`$ref"
                $Body = @{ "@odata.id" = "https://graph.microsoft.com/beta/users/$($MostFrequentUser.Id)" } | ConvertTo-Json
                $Method = "POST"

                Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body $Body

                $Modified = "Yes"
            }
        }
        # The device does not have a primary user
        else {

            $PrimaryUserUpn = "None"

            # Generate the Http REST API call by defining its URI, Body, and Method
            $Uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$IntuneDeviceId')/users/`$ref"
            $Body = @{ "@odata.id" = "https://graph.microsoft.com/beta/users/$($MostFrequentUser.Id)" } | ConvertTo-Json
            $Method = "POST"

            Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body $Body

            $Modified = "Yes"
        }

        # Add a record to the Csv Output file with the details
        Add-Content -Path $OutputFilePath -Value "$IntuneDeviceId,$DisplayName,$PrimaryUserUpn,$MostFrequentUpn,$Modified"
    
    }
    # Most frequent user was not discovered
    else {

        Write-Warning "Failed to discover the most frequent user for $DisplayName (the device had no 'Windows Sign In' entries)."
    
    }
}
