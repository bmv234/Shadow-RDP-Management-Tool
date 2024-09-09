# Shadow RDP Management GUI Tool

This tool provides IT staff with a graphical user interface (GUI) to manage Remote Desktop Protocol (RDP) shadowing of computers within a domain. It requires Domain Admin credentials and leverages Active Directory to query and manage network computers.

## Features
- Retrieves a list of enabled domain computers from Active Directory (AD).
- Uses parallel pinging to identify online computers.
- Displays online computers in an easy-to-use GUI for quick selection.
- Facilitates RDP shadowing sessions on remote computers.

## Requirements
- **PowerShell**: Version 5.1 or higher.
- **Domain Admin Credentials**: Required to query domain computers and initiate RDP sessions.
- **Active Directory Module**: Ensure that the `ActiveDirectory` PowerShell module is installed.
- **Windows Forms**: Utilizes `System.Windows.Forms` and `System.Drawing` for the GUI, which must be accessible in your PowerShell session.

## GPO Requirements

For seamless RDP shadowing, you need to configure the following Group Policy settings:

1. **No Consent Prompt for Remote Assistance**
   
   To enable shadowing sessions without the need for user consent, configure the Group Policy setting:
   
   - **Path**: `Computer Configuration -> Administrative Templates -> System -> Remote Assistance`
   - **Policy**: Set "Configure Offer Remote Assistance" to "Enabled" and select "Allow helpers to remotely control the computer" without requiring user consent.

2. **Allow Remote Desktop Shadowing**

   Ensure that RDP shadowing is enabled by configuring the following Group Policy setting:

   - **Path**: `Computer Configuration -> Administrative Templates -> Windows Components -> Remote Desktop Services -> Remote Desktop Session Host -> Connections`
   - **Policy**: Set "Set rules for remote control of Remote Desktop Services user sessions" to "Enabled" and select "Full Control without user’s permission" to allow shadowing without consent.

3. **Ensure Remote Assistance is Enabled**
   
   - **Path**: `Computer Configuration -> Administrative Templates -> System -> Remote Assistance`
   - **Policy**: Enable "Offer Remote Assistance" and ensure that it allows the IT admin to shadow user sessions.

4. **Configure Network Level Authentication (NLA)**

   Ensure that Network Level Authentication is enabled for increased security:

   - **Path**: `Computer Configuration -> Administrative Templates -> Windows Components -> Remote Desktop Services -> Remote Desktop Session Host -> Security`
   - **Policy**: Set "Require user authentication for remote connections by using Network Level Authentication" to "Enabled".

## Installation

1. Install the Active Directory module if not already installed:
   
```powershell
Install-Module ActiveDirectory
```

2. Download the script (shadowrdp.ps1) to your local machine.

3. If your PowerShell execution policy restricts script execution, you can bypass it with one of the following methods:
Temporarily Bypass Execution Policy for the Current Session

    Use this command to bypass the execution policy for this session only:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\shadowrdp.ps1
```

Alternatively, you can permanently set the execution policy to bypass for the current session:

```powershell
Set-ExecutionPolicy Bypass -Scope Process
```

## Usage

Launch the script using PowerShell:

```powershell
.\shadowrdp.ps1
```
The tool will query Active Directory to retrieve a list of computers and check which ones are online.

From the GUI, select an online computer and an active user session to start an RDP shadow session.

## Troubleshooting

No computers found: Ensure your Active Directory connection is functioning properly and that you have the required permissions to query domain computers.
Assembly loading issues: Verify that System.Windows.Forms and System.Drawing are available and can be loaded in your PowerShell session. You may need to run PowerShell as an Administrator.
User consent prompt: If you receive a user consent prompt during shadowing, ensure that the Group Policy "Set rules for remote control of Remote Desktop Services user sessions" is configured to allow "Full Control without user’s permission."
