<#
.NOTES
This sample script is not supported under any Microsoft standard support program or service. The sample script is provided AS IS without warranty of any kind. Microsoft disclaims all implied warranties including, without limitation, any implied warranties of merchantability or of fitness for a particular purpose. The entire risk arising out of the use or performance of the sample script remains with you. 
In no event shall Microsoft, its authors, or anyone else involved in the creation, production, or delivery of the script be liable for any damages whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business information, or other pecuniary loss) arising out of the use of or inability to use the sample script, even if Microsoft has been advised of the possibility of such damages.

.SYNOPSIS
The Set-IntuneDevicePrimaryUser.ps1 script configures the primary user of an Intune device to the user with the highest number of sign-ins to the device.

.DESCRIPTION
1. The script requires the name of a Group that contains Intune Devices or a comma-separated value file with 2 column headers: IntuneDeviceId and DisplayName.
2. The script retrieves all the Sign In Audit logs for the "Windows Sign In" application for the last 30 days
3. For each device, the script determines the user with the highest number of sign-ins to Windows.
4. The script compares and updates the Intune device's primary user to the most frequently signed-in user.
5. The script creates a Csv file in the same folder as the script titled "IntuneDevices-PrimaryUsers-Date" with the following details: "IntuneDeviceId,DisplayName,CurrentPrimaryUser,NewPrimaryUser,Modified"

Notes:
- If the most-frequently signed-in user could not be determined, e.g. there are no sign-in events to Windows, the script will return "Failed" for the NewPrimaryUser field in the output file and won't make any changes.
- If the device does not have a primary user, the script will use "None" for the PreviousPrimaryUser field
- The script will skip a device if any of the following conditions happen:
    - The device is not managed by Intune
    - The most-frequently signed-in user does not exist in Azure AD

.PARAMETER GroupName
The name of a Group that contains Intune devices

.PARAMETER InputFilePath
A comma-separated value file with 2 column headers: DeviceId and DisplayName. Example:
    IntuneDeviceId,DisplayName
    0159b6fb-89a7-4bf1-abf8-cc178be41a7a,Laptop-001
    8b8b5c16-91b0-4b4e-8225-247c8a43da6a,Desktop-020

.EXAMPLE
.\Set-IntuneDevicePrimaryUser.ps1 -GroupName "FLW Laptops"

.EXAMPLE
.\Set-IntuneDevicePrimaryUser.ps1 -InputFilePath "~\Documents\Devices.csv"
#>

[CmdletBinding(DefaultParameterSetName = 'GroupName')]
param (
  [String]
  [Parameter(Mandatory, ParameterSetName = 'GroupName', Position=0)]
  $GroupName,
  [String]
  [Parameter(Mandatory, ParameterSetName = 'InputFilePath', Position=0)]
  $InputFilePath
)

# The script will stop execution upon encountering any errors
$ErrorActionPreference = 'Stop'

# Connect to Microsoft Graph and request the ability to read Audit logs and Users and modify Intune Devices
Connect-MgGraph -Scopes AuditLog.Read.All, User.Read.All, DeviceManagementManagedDevices.ReadWrite.All, Group.Read.All, GroupMember.Read.All, Device.Read.All

#
#
# 1. Configure the Output Csv file 
#
#

# Retrieve the parent directory containing the script
$WorkingDirectoryPath = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

# Generate the output file name
$OutputFileName = "IntuneDevices-PrimaryUsers-" + $(Get-Date -Format "MM-dd-yyyy-HHmm") + ".csv"

# Join the script's parent folder with the output file name
$OutputFilePath = Join-Path -Path $WorkingDirectoryPath -ChildPath $OutputFileName

# The first line of the output file contains the column headers of the Csv file
Set-Content -Path $OutputFilePath -Value "IntuneDeviceId,DisplayName,CurrentPrimaryUser,NewPrimaryUser,Modified,ErrorMessage"

#
#
# 2. Import the Devices Csv Input File
#
#

# If the InputFilePath parameter was used
if ($InputFilePath) {

    # Verify that the Csv input file path is valid
    Get-Item -Path $InputFilePath

    # Import the contents of the Csv file into a collection of PSCustomObject objects
    $AllDevices = Import-Csv -Path $InputFilePath

    # Retrieve the note properties (static properties) of the PSCustomObject objects
    $ColumnHeaders = $AllDevices | Get-Member -MemberType NoteProperty | Sort-Object -Property Name -Descending

    # Verify that the PSCustomObject objects have 2 properties: DeviceId and DisplayName
    if (($ColumnHeaders[0].Name -ne "IntuneDeviceId") -or ($ColumnHeaders[1].Name -ne "DisplayName")) {

        Write-Error "The script requires a Csv file that has 2 column headers: IntuneDeviceId and DisplayName."

    }

}

#
#
# 3. Retrieve Device members of the Group
#
#

# If the GroupName parameter was specified
if ($GroupName) {

    # Verify that the group exists
    $Group = Get-MgGroup -Filter "DisplayName eq '$GroupName'"

    if (-not $Group){

        Write-Error "Unable to find an Azure AD group named '$GroupName'."
    }

    # Retrieve all Device members of the Group
    $DirectoryObjects = Get-MgGroupMember -GroupId $Group.Id | Where-Object {$_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.device'}

    if (-not $DirectoryObjects) {

        Write-Error "Failed to find any devices that are members of group '$GroupName'."
    }

    # Initialize the $AllDevices variable to an empty array
    $AllDevices = @()

    foreach ($DirectoryObject in $DirectoryObjects) {

        # Save the Azure AD Device Id
        $AzureAdDeviceId = $DirectoryObject.AdditionalProperties.deviceId

        # Save the Device Display Name
        $DisplayName = $DirectoryObject.AdditionalProperties.displayName

        # Retrieve the Intune managed device with matching Azure AD Device Id
        $ManagedDevice = Get-MgDeviceManagementManagedDevice -Filter "AzureAdDeviceId eq '$AzureAdDeviceId'"

        # If the device is not managed by Intune, print a warning and skip to the next device
        if (-not $ManagedDevice) {
    
            Write-Warning "Failed to retrieve the Intune managed device with Display Name $DisplayName and Azure AD Device ID $AzureAdDeviceId."
    
            # Skip this particular device and move on to the next one
            Continue
        }
        else {

            $Device = [PSCustomObject]@{
                IntuneDeviceId = $ManagedDevice.Id
                DisplayName = $DisplayName
            }

        }

        $AllDevices += $Device
    
    }

}

# Retrieve all the sign-in events to Windows
$AllSignInLogs = Get-MgAuditLogSignIn -All -Filter "appDisplayName eq 'Windows Sign In'"

foreach ($Device in $AllDevices) {

    # Save the Device Display Name
    $DisplayName = $Device.DisplayName

    # Save the Intune Device Id
    $IntuneDeviceId = $Device.IntuneDeviceId

    Write-Host "`nProcessing Device $DisplayName"

    #
    #
    # 4. Verify that each device is managed by Intune
    #
    #

    # Retrieve the Intune managed device using its Intune Device Id
    $ManagedDevice = Get-MgDeviceManagementManagedDevice -ManagedDeviceId $IntuneDeviceId

    # If the device is not managed by Intune, print a warning and skip to the next device
    if (-not $ManagedDevice) {

        Write-Warning "Failed to retrieve the Intune managed device with Display Name $DisplayName and Intune Device ID $IntuneDeviceId."

        # Skip this particular device and move on to the next one
        Continue
    }
    else {
        # Retrieve the Azure AD Device Id
        $AzureADDeviceId = $ManagedDevice.AzureAdDeviceId
    }

    #
    #
    # 5. Determine the most frequently signed-in user to the device
    #
    #

    # Filter the Sign-In Logs for the Azure AD Device Id
    $DeviceSignInLogs = $AllSignInLogs | Where-Object {$_.DeviceDetail.DeviceId -eq $AzureADDeviceId}

    # Group the Sign-In Events by the User Principal Name and sort the groups by the number of elements they contain (Count)
    $MostFrequentUserUpn = $DeviceSignInLogs | Where-Object {$_.UserPrincipalName} | Group-Object -Property UserPrincipalName -NoElement | Sort-Object -Descending -Property Count | Select-Object -First 1 | ForEach-Object {$_.Name}

    # The most frequent user has been determined
    if ($MostFrequentUserUpn) {

        # Validate that the user exists
        $MostFrequentUser = Get-MgUser -Filter "UserPrincipalName eq '$MostFrequentUserUpn'"

        # Verify that the most frequent user has a valid Azure AD User object
        if (-not $MostFrequentUser) {
    
            $ErrorMessage = "The most frequent user '$MostFrequentUserUpn' for $DisplayName does not exist."

            Write-Warning $ErrorMessage

            $MostFrequentUserUpn = "Failed"


        }

    }
    # Failed to determine the user who signed-in the most to the device
    else {

        $ErrorMessage = "Failed to discover the most frequent user for $DisplayName (the device had no 'Windows Sign In' entries)."

        Write-Warning $ErrorMessage

        $MostFrequentUserUpn = "Failed"
    }

    #
    #
    # 6. Obtain the Primary User of the Device
    #
    #

    # Retrieve the device's primary user
    $PrimaryUser = Get-MgDeviceManagementManagedDeviceUser -ManagedDeviceId $IntuneDeviceId

    # If the device has a primary user
    if ($PrimaryUser) 
    {
        # Obtain the primary user's Upn
        $PrimaryUserUpn = $PrimaryUser.UserPrincipalName
    }
    else 
    {
        # Otherwise, the device doesn't have a primary user, set the output to 'None'
        $PrimaryUserUpn = "None"
    }

    #
    #
    # 7.Compare and update the Intune device's primary user 
    #
    #

    # The most frequent user is the same as the primary user
    if ($MostFrequentUserUpn -eq $PrimaryUserUpn) 
    {
        $Modified = "No"

        $ErrorMessage = "The most frequently-signed user is already configured as the primary user"
    }
    # The most frequent user and the primary user are different and the most frequent user has been determined
    elseif ($MostFrequentUserUpn -ne "Failed") 
    {

        # Generate the Http REST API call by defining its URI, Body, and Method
        $Uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$IntuneDeviceId')/users/`$ref"
        $Body = @{ "@odata.id" = "https://graph.microsoft.com/beta/users/$($MostFrequentUser.Id)" } | ConvertTo-Json
        $Method = "POST"

        $Error.PSBase.Clear()

        try {

            Invoke-MgGraphRequest -Method $Method -Uri $Uri -Body $Body -ErrorAction Continue

        }
        catch {

            if ($Error[0]) {

                $ErrorMessageDetails = $Error[0].ErrorDetails.Message

                $ErrorMessageToken = $ErrorMessageDetails.Split('\"Message\": \"')[1]

                $ErrorMessage = $ErrorMessageToken.Split(' - Operation ID')[0]

                Write-Warning $ErrorMessage

                $Modified = "No"

            }
            else {

                $Modified = "Yes"

            }

        }
    }
    # The most frequent user was not determined
    else 
    {
        $Modified = "No"
    }

    # Add a record to the Csv Output file with the details
    Add-Content -Path $OutputFilePath -Value "$IntuneDeviceId,$DisplayName,$PrimaryUserUpn,$MostFrequentUserUpn,$Modified,$ErrorMessage"

}
