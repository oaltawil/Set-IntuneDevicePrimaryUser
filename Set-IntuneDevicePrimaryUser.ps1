<#
.SYNOPSIS
The Set-IntuneDevicePrimaryUser.ps1 script configures the primary user of an Intune device to the user with the highest number of sign-ins to the device.

.DESCRIPTION
1. The script requires a list of devices in a comma-separated value file with 2 column headers: DeviceId and DisplayName, where Device Id is the Azure AD Device Id.
2. The script retrieves all the Sign In Audit logs for the "Windows Sign In" application for the last 30 days
3. For each device in the list, the script determines the user with the highest number of sign-ins to Windows.
4. The script compares and updates the Intune device's primary user to the most frequently signed-in user.

Notes:
- Please note that the script uses the Device Id - and not the Display Name - when filtering the Sign In Logs and when configuring the Intune device.
- The script will skip a device if any of the following conditions happen:
    - The device is not managed by Intune
    - The most-frequently signed-in user could not be determined, e.g. there are no sign-in events to Windows
    - The most-frequently signed-in user doesn't exist in Azure AD

.PARAMETER DevicesInputFilePath
A comma-separated value file with 2 column headers: DeviceId and DisplayName. Example:
    DeviceId,DisplayName
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
$ColumnHeaders = $AllDevices | Get-Member -MemberType NoteProperty | Sort-Object -Property Name

# Verify that the PSCustomObject objects have 2 properties: DeviceId and DisplayName
if (($ColumnHeaders[0].Name -ne "DeviceId") -or ($ColumnHeaders[1].Name -ne "DisplayName")) {

    Write-Error "The script requires a Csv file that has 2 column headers: DeviceId and DisplayName."

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
    $DeviceDisplayName = $Device.DisplayName

    # Save the Azure AD Device Id
    $DeviceId = $Device.DeviceId

    Write-Host "`nProcessing Device $DeviceDisplayName"
    
    # Retrieve the Intune managed device using its Azure AD Device Id
    $ManagedDevice = Get-MgDeviceManagementManagedDevice -Filter "AzureAdDeviceId eq '$DeviceId'"

    # If the device is not managed by Intune, print a warning and skip to the next device
    if (-not $ManagedDevice) {

        Write-Warning "Failed to retrieve the Intune managed device with Display Name $DeviceDisplayName and Azure AD Device ID $DeviceId."

        # Skip this particular device and move on to the next one
        Continue
    }

    #
    #
    # 3. Determine the most frequently signed-in user to the device
    #
    #

    # Filter the Sign-In Logs for the Device Id
    $DeviceSignInLogs = $AllSignInLogs | Where-Object {$_.DeviceDetail.DeviceId -eq $DeviceId}

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

        Write-Host "The most frequently signed-in user to $DeviceDisplayName is $MostFrequentUpn."

        #
        #
        # 4.Compare and update the Intune device's primary user 
        #
        #

        # Save the Intune Device Id
        $ManagedDeviceId = $ManagedDevice.Id

        # Retrieve the device's primary user
        $PrimaryUser = Get-MgDeviceManagementManagedDeviceUser -ManagedDeviceId $ManagedDeviceId

        # The device has a primary user
        if ($PrimaryUser) {

            Write-Host "The primary user for $DeviceDisplayName is $($PrimaryUser.UserPrincipalName)."

            # The most frequent user is the same as the primary user
            if ($MostFrequentUpn -eq $PrimaryUser.UserPrincipalName) {

                Write-Host "The device's primary user and most frequent user are the same."
                
                Write-Host "No changes are required."
            }
            # The most frequent user is different than the primary user
            else {

                Write-Host "The device's primary user and most frequent user are different."
                
                Write-Host "Changing the device's primary user to $MostFrequentUpn."
                
                # Generate the Http REST API call by defining its URI, Body, and Method
                $Uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$ManagedDeviceId')/users/`$ref"
                $Body = @{ "@odata.id" = "https://graph.microsoft.com/beta/users/$($MostFrequentUser.Id)" } | ConvertTo-Json
                $Method = "POST"

                Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body $Body -Verbose
                
            }
        }
        # The device does not have a primary user
        else {

            Write-Host "$DeviceDisplayName does not have a primary user."

            Write-Host "Setting the device's primary user to $MostFrequentUpn."

            # Generate the Http REST API call by defining its URI, Body, and Method
            $Uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$ManagedDeviceId')/users/`$ref"
            $Body = @{ "@odata.id" = "https://graph.microsoft.com/beta/users/$($MostFrequentUser.Id)" } | ConvertTo-Json
            $Method = "POST"

            Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body $Body -Verbose

        }
    }
    # Most frequent user was not discovered
    else {

        Write-Warning "Failed to discover the most frequent user for $DeviceDisplayName (the device had no 'Windows Sign In' entries)."
    
    }
}
