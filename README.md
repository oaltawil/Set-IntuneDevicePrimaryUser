# Set-IntuneDevicePrimaryUser
Configures the Primary User of a Microsoft Intune Device

The Set-IntuneDevicePrimaryUser.ps1 script configures the primary user of an Intune device to the user with the highest number of sign-ins to the device.

1. The script requires a list of devices in a comma-separated value file with 2 column headers: DeviceId and DisplayName, where Device Id is the Azure AD Device Id.
2. The script retrieves all the Sign In Audit logs for the "Windows Sign In" application for the last 30 days.
3. For each device in the list, the script determines the user with the highest number of sign-ins to Windows.
4. The script compares and updates the Intune device's primary user to the most frequently signed-in user.

Notes:
- Please note that the script uses the Device Id - and not the Display Name - when filtering the Sign In Logs and when configuring the Intune device.
- The script will skip a device if any of the following conditions happen:
    - The device is not managed by Intune
    - The most-frequently signed-in user could not be determined, e.g. there are no sign-in events to Windows
    - The most-frequently signed-in user does not exist in Azure AD
