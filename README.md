# Set-IntuneDevicePrimaryUser
Configures the Primary User of a Microsoft Intune Device

The Set-IntuneDevicePrimaryUser.ps1 script configures the primary user of an Intune device to the user with the highest number of sign-ins to the device.

1. The script requires the name of a group that contains Intune devices or a comma-separated value file with 2 column headers: IntuneDeviceId and DisplayName.
2. The script retrieves all the Sign In Audit logs for the "Windows Sign In" application for the last 30 days.
3. For each device, the script determines the user with the highest number of sign-ins to Windows.
4. The script compares and updates the Intune device's primary user to the most frequently signed-in user.
5. The script creates a Csv file in the same folder as the script titled "IntuneDevices-PrimaryUsers-DateTime. csv" with the following details: "IntuneDeviceId,DisplayName,CurrentPrimaryUser,NewPrimaryUser,Modified, ErrorMessage"

Notes:
- If the most-frequently signed-in user could not be determined, e.g. there are no sign-in events to Windows, the script will return "Failed" for the NewPrimaryUser field in the output file and won't make any changes.
- If the device does not have a primary user, the script will use "None" for the CurrentPrimaryUser field
- The script will skip a device if any of the following conditions happen:
    - The device is not managed by Intune
    - The most-frequently signed-in user does not exist in Azure AD
