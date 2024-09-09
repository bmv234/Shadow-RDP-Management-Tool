# Shadow RDP Management GUI Tool for IT Staff
# Requires Domain Admin credentials and proper permissions
# Compatible with PowerShell 5.1 and above

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module ActiveDirectory

# Function to get online hosts in the domain
function Global:Get-OnlineHosts {
    param([System.Windows.Forms.TextBox]$LogTextBox, [System.Windows.Forms.ListBox]$ListBox)
    
    Log-Message -Message "Starting parallel ping host discovery process..." -LogTextBox $LogTextBox
    try {
        Log-Message -Message "Retrieving computers from Active Directory..." -LogTextBox $LogTextBox
        $allHosts = Get-ADComputer -Filter * -Properties Name, DNSHostName | Where-Object { $_.Enabled -eq $true }
        
        if ($null -eq $allHosts -or $allHosts.Count -eq 0) {
            throw "No computers found in Active Directory. Please check your AD connection and permissions."
        }
        
        Log-Message -Message "Found $($allHosts.Count) enabled computers in AD." -LogTextBox $LogTextBox
        $maxThreads = 100 # Adjust based on your system's capabilities
        $timeoutMilliseconds = 1000 # 1 second timeout for each ping

        # Create runspace pool
        $runspacePool = [runspacefactory]::CreateRunspacePool(1, $maxThreads)
        $runspacePool.Open()

        $scriptBlock = {
            param($computer, $timeoutMilliseconds)
            $pingTarget = if ([string]::IsNullOrEmpty($computer.DNSHostName)) { $computer.Name } else { $computer.DNSHostName }
            $ping = New-Object System.Net.NetworkInformation.Ping
            try {
                $reply = $ping.Send($pingTarget, $timeoutMilliseconds)
                if ($reply.Status -eq 'Success') {
                    return @{
                        Name = $computer.Name
                        DNSHostName = $computer.DNSHostName
                        IPAddress = $reply.Address.ToString()
                    }
                }
            }
            catch {
                # Ping failed, computer is likely offline
            }
            return $null
        }

        # Create and invoke runspaces
        $runspaces = @()
        foreach ($computer in $allHosts) {
            $runspace = [powershell]::Create().AddScript($scriptBlock).AddArgument($computer).AddArgument($timeoutMilliseconds)
            $runspace.RunspacePool = $runspacePool
            $runspaces += [PSCustomObject]@{ Pipe = $runspace; Status = $runspace.BeginInvoke() }
        }

        # Process results
        $onlineHosts = @()
        $processedCount = 0
        foreach ($runspace in $runspaces) {
            $result = $runspace.Pipe.EndInvoke($runspace.Status)
            if ($result) {
                $onlineHosts += $result
                $ListBox.Invoke([Action]{$ListBox.Items.Add($result.Name)})
                Log-Message -Message "$($result.Name) ($($result.IPAddress)) is online" -LogTextBox $LogTextBox
            }
            $runspace.Pipe.Dispose()
            $processedCount++
            
            # Update progress every 10 hosts or for the last host
            if ($processedCount % 10 -eq 0 -or $processedCount -eq $allHosts.Count) {
                $percentComplete = [math]::Round(($processedCount / $allHosts.Count) * 100, 2)
                Log-Message -Message "Progress: $percentComplete% ($processedCount/$($allHosts.Count))" -LogTextBox $LogTextBox
            }
        }

        # Clean up
        $runspacePool.Close()
        $runspacePool.Dispose()

        Log-Message -Message "Scan complete. Found $($onlineHosts.Count) online hosts." -LogTextBox $LogTextBox
        
        # Query hostnames for online hosts
        Log-Message -Message "Querying hostnames for online hosts..." -LogTextBox $LogTextBox
        foreach ($onlineHost in $onlineHosts) {
            $hostname = $onlineHost.DNSHostName
            if ([string]::IsNullOrEmpty($hostname)) {
                $hostname = $onlineHost.Name
            }
            Log-Message -Message "Hostname: $hostname (IP: $($onlineHost.IPAddress))" -LogTextBox $LogTextBox
        }

        return $onlineHosts.Count
    }
    catch {
        Log-Message -Message ("Error in Get-OnlineHosts: {0}" -f $_.Exception.Message) -LogTextBox $LogTextBox
        Log-Message -Message ("Stack Trace: {0}" -f $_.ScriptStackTrace) -LogTextBox $LogTextBox
        return 0
    }
}

# Function to get active sessions on a host
function Global:Get-ActiveSessions {
    param (
        [string]$ComputerName,
        [System.Windows.Forms.TextBox]$LogTextBox
    )
    Log-Message -Message "Retrieving active sessions for $ComputerName..." -LogTextBox $LogTextBox
    
    try {
        $qwinstaOutput = qwinsta /server:$ComputerName 2>&1
        if ($qwinstaOutput -is [System.Management.Automation.ErrorRecord]) {
            throw $qwinstaOutput
        }

        $sessions = @()
        $qwinstaOutput | Select-Object -Skip 1 | ForEach-Object {
            if ($_ -match '^\s*(\S+)\s+(\S+)?\s+(\d+)\s+(\S+)\s+(\S+)?') {
                $session = @{
                    SessionName = $Matches[1]
                    Username = if ($Matches[2] -and $Matches[2] -ne "") { $Matches[2] } else { $Matches[1] }
                    ID = $Matches[3]
                    State = $Matches[4]
                    Type = if ($Matches[5]) { $Matches[5] } else { "" }
                }

                # Check if the session is active
                if ($session.State -eq "Active") {
                    $sessions += $session
                }
            }
        }

        Log-Message -Message "Found $($sessions.Count) active sessions on $ComputerName." -LogTextBox $LogTextBox
        return $sessions
    }
    catch {
        $errorMessage = $_.Exception.Message
        Log-Message -Message "Error retrieving sessions for $ComputerName." -LogTextBox $LogTextBox
        Log-Message -Message "Error details: $errorMessage" -LogTextBox $LogTextBox
        return @()
    }
}

# Function to initiate shadow RDP session
function Global:Start-ShadowRDP {
    param (
        [string]$ComputerName,
        [string]$SessionID,
        [System.Windows.Forms.TextBox]$LogTextBox
    )
    Log-Message -Message "Initiating shadow RDP session to $ComputerName, Session ID: $SessionID" -LogTextBox $LogTextBox
    
    try {
        # Check session state
        $sessionInfo = qwinsta /server:$ComputerName | Where-Object { $_ -match "^\s*\S+\s+\S+\s+$SessionID\s+" }
        if ($null -eq $sessionInfo) {
            throw "Session ID $SessionID not found on $ComputerName."
        }

        $sessionState = if ($sessionInfo -match 'Active') { 'Active' } elseif ($sessionInfo -match 'Disc') { 'Disconnected' } else { 'Unknown' }

        if ($sessionState -ne 'Active') {
            throw "The specified session (ID: $SessionID) is not in an Active state. Current state: $sessionState"
        }

        # Construct the mstsc command for shadow mode
        $mstscArguments = "/v:$ComputerName /shadow:$SessionID /control /noConsentPrompt"
        
        # Start the mstsc process
        $process = Start-Process -FilePath "mstsc.exe" -ArgumentList $mstscArguments -PassThru
        
        if ($null -eq $process) {
            throw "Failed to start mstsc.exe process"
        }
        
        Log-Message -Message "Shadow RDP session initiated. Process ID: $($process.Id)" -LogTextBox $LogTextBox
        
        # Wait a bit to see if the process exits immediately (which would indicate an error)
        Start-Sleep -Seconds 2
        if ($process.HasExited) {
            throw "mstsc.exe process exited immediately. Exit Code: $($process.ExitCode)"
        }
        
        [System.Windows.Forms.MessageBox]::Show("Shadow RDP session to $ComputerName (Session ID: $SessionID) has been initiated.", "Shadow RDP")
    }
    catch {
        $errorMessage = $_.Exception.Message
        Log-Message -Message "Error starting shadow RDP session: $errorMessage" -LogTextBox $LogTextBox
        [System.Windows.Forms.MessageBox]::Show("Failed to start shadow RDP session: $errorMessage", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

# Function to log messages
function Global:Log-Message {
    param (
        [string]$Message,
        [System.Windows.Forms.TextBox]$LogTextBox
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogTextBox.AppendText("[$timestamp] $Message`r`n")
    $LogTextBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# Create the main form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Shadow RDP Management Tool"
$form.Size = New-Object System.Drawing.Size(600,600)
$form.StartPosition = "CenterScreen"

# Create and add a ListBox for online hosts
$listBoxHosts = New-Object System.Windows.Forms.ListBox
$listBoxHosts.Location = New-Object System.Drawing.Point(10,10)
$listBoxHosts.Size = New-Object System.Drawing.Size(560,150)
$form.Controls.Add($listBoxHosts)

# Create and add a Button to refresh online hosts
$buttonRefresh = New-Object System.Windows.Forms.Button
$buttonRefresh.Location = New-Object System.Drawing.Point(10,170)
$buttonRefresh.Size = New-Object System.Drawing.Size(100,30)
$buttonRefresh.Text = "Refresh Hosts"
$form.Controls.Add($buttonRefresh)

# Create and add a ListBox for active sessions
$listBoxSessions = New-Object System.Windows.Forms.ListBox
$listBoxSessions.Location = New-Object System.Drawing.Point(10,210)
$listBoxSessions.Size = New-Object System.Drawing.Size(560,150)
$form.Controls.Add($listBoxSessions)

# Create and add a Button to get sessions
$buttonGetSessions = New-Object System.Windows.Forms.Button
$buttonGetSessions.Location = New-Object System.Drawing.Point(10,370)
$buttonGetSessions.Size = New-Object System.Drawing.Size(100,30)
$buttonGetSessions.Text = "Get Sessions"
$form.Controls.Add($buttonGetSessions)

# Create and add a Button to start shadow RDP
$buttonStartShadow = New-Object System.Windows.Forms.Button
$buttonStartShadow.Location = New-Object System.Drawing.Point(120,370)
$buttonStartShadow.Size = New-Object System.Drawing.Size(120,30)
$buttonStartShadow.Text = "Start Shadow RDP"
$form.Controls.Add($buttonStartShadow)

# Create and add a TextBox for logging
$logTextBox = New-Object System.Windows.Forms.TextBox
$logTextBox.Location = New-Object System.Drawing.Point(10,410)
$logTextBox.Size = New-Object System.Drawing.Size(560,140)
$logTextBox.Multiline = $true
$logTextBox.ScrollBars = "Vertical"
$logTextBox.ReadOnly = $true
$form.Controls.Add($logTextBox)

# Event handler for the Refresh Hosts button
$buttonRefresh.Add_Click({
    $listBoxHosts.Items.Clear()
    Log-Message -Message "Starting refresh of online hosts..." -LogTextBox $logTextBox
    $onlineHostsCount = Get-OnlineHosts -LogTextBox $logTextBox -ListBox $listBoxHosts
    Log-Message -Message "Refresh complete. Found $onlineHostsCount online hosts." -LogTextBox $logTextBox
})

# Event handler for the Get Sessions button
# Event handler for the Get Sessions button
$buttonGetSessions.Add_Click({
    $selectedHost = $listBoxHosts.SelectedItem
    if ($selectedHost) {
        $listBoxSessions.Items.Clear()
        $sessions = Get-ActiveSessions -ComputerName $selectedHost -LogTextBox $logTextBox
        foreach ($session in $sessions) {
            $listBoxSessions.Items.Add("ID: $($session.ID), User: $($session.Username), Type: $($session.Type)")
        }
    } else {
        Log-Message -Message "Error: No host selected." -LogTextBox $logTextBox
        [System.Windows.Forms.MessageBox]::Show("Please select a host first.", "Error")
    }
})

# Event handler for the Start Shadow button
$buttonStartShadow.Add_Click({
    $selectedHost = $listBoxHosts.SelectedItem
    $selectedSession = $listBoxSessions.SelectedItem
    if ($selectedHost -and $selectedSession) {
        $sessionId = ($selectedSession -split ',')[0] -replace 'ID: '
        Start-ShadowRDP -ComputerName $selectedHost -SessionID $sessionId -LogTextBox $logTextBox
    } else {
        Log-Message -Message "Error: Host or session not selected." -LogTextBox $logTextBox
        [System.Windows.Forms.MessageBox]::Show("Please select both a host and a session.", "Error")
    }
})

# Show the form
$form.ShowDialog()