param (
    [switch]$Help
)

<#
.SYNOPSIS

    An automated, GUI-based maintenance and repair tool for Windows 11. It handles admin rights
    elevation via Company Portal, runs a full suite of system/network repairs, automates Windows Updates,
    and manages manufacturer-specific driver and firmware updates, including silent installations.

.DESCRIPTION

    This script provides a user-friendly graphical interface (GUI) to guide a user or technician through a comprehensive,
    standardized system health and repair process. Its operational flow is as follows:

    1.  Pre-execution Checks: Before starting, the script performs several critical checks.
        - It first asks for user confirmation, warning that the process is lengthy and ends with a mandatory restart.
        - For laptops, it verifies the device is connected to AC power and will repeatedly prompt the user until it is.
        - It checks if it's running with elevated privileges to determine the next step.

    2.  Administrator Rights Elevation: If the script is not run as an administrator:
        - It automatically opens the Company Portal to the specific application for temporary admin rights.
        - It displays clear, step-by-step instructions for the user to install the rights, restart their PC, and then
          re-run the tool with the newly acquired privileges.

    3.  Background Processing: Once running with admin rights, all maintenance tasks are executed in a background
        PowerShell session. This ensures the GUI remains responsive, providing real-time progress without freezing.

    4.  Comprehensive Maintenance Sequence: The script executes a carefully ordered sequence of commands:
        - Network Repair: Flushes the DNS cache and resets the Winsock catalog and TCP/IP stack.
        - Windows Update Automation: Checks for the 'PSWindowsUpdate' module. If not present, it installs it automatically.
          It then proceeds to search for, download, and install all applicable Microsoft updates.
        - System Integrity: Runs DISM commands to check and restore the health of the component store, followed by
          a System File Checker (SFC) scan to repair corrupted system files.
        - Disk Health: Schedules a full check disk (`chkdsk`) to run on the next restart.

    5.  Automated Driver & Firmware Updates: The tool intelligently handles manufacturer-specific updates.
        - It first detects the computer's manufacturer (e.g., Dell, HP).
        - For Dell Machines: If Dell Command | Update is not found, it automatically downloads the installer,
          performs a silent installation, and then logs a message for the user to run it manually after the final restart.
          If it is already installed, it runs a scan and applies updates automatically.
        - For HP Machines: It checks for HP Image Assistant and runs it if found. If not, it provides a direct link
          and instructions for the user to install it manually.
        - For Other Manufacturers: It provides on-screen guidance for common update tools (e.g., Lenovo Vantage).

    6.  Dual Logging System: All actions, command outputs, successes, and errors are logged in two ways:
        - Real-Time GUI Log: The main window displays a color-coded log of every step as it happens.
        - Permanent File Log: A timestamped text file is created in 'C:\ProgramData\SystemMaintenance' for each
          session, allowing for later analysis and record-keeping.

    7.  Final Mandatory Restart: Upon completion of all tasks, the script displays a final message and, after a
        5-second countdown, performs an automatic restart to ensure all changes are fully applied.
#>

# This logic checks for the -Help switch
if ($Help) {
    # This text will be displayed in the console if someone runs: YourApp.exe -Help
    Write-Host @"
NAME:
    System Maintenance Tool

SYNOPSIS:
    An automated, GUI-based maintenance and repair tool for Windows 11. It handles admin rights
    elevation via Company Portal, runs a full suite of system/network repairs, automates Windows Updates,
    and manages manufacturer-specific driver and firmware updates, including silent installations.

DESCRIPTION:
    This script provides a user-friendly graphical interface (GUI) to guide a user or technician through a comprehensive,
    standardized system health and repair process. Its operational flow is as follows:

    1.  Pre-execution Checks: Before starting, the script performs several critical checks.
        - It first asks for user confirmation, warning that the process is lengthy and ends with a mandatory restart.
        - For laptops, it verifies the device is connected to AC power and will repeatedly prompt the user until it is.
        - It checks if it's running with elevated privileges to determine the next step.

    2.  Administrator Rights Elevation: If the script is not run as an administrator:
        - It automatically opens the Company Portal to the specific application for temporary admin rights.
        - It displays clear, step-by-step instructions for the user to install the rights, restart their PC, and then
          re-run the tool with the newly acquired privileges.

    3.  Background Processing: Once running with admin rights, all maintenance tasks are executed in a background
        PowerShell session. This ensures the GUI remains responsive, providing real-time progress without freezing.

    4.  Comprehensive Maintenance Sequence: The script executes a carefully ordered sequence of commands:
        - Network Repair: Flushes the DNS cache and resets the Winsock catalog and TCP/IP stack.
        - Windows Update Automation: Checks for the 'PSWindowsUpdate' module. If not present, it installs it automatically.
          It then proceeds to search for, download, and install all applicable Microsoft updates.
        - System Integrity: Runs DISM commands to check and restore the health of the component store, followed by
          a System File Checker (SFC) scan to repair corrupted system files.
        - Disk Health: Schedules a full check disk (`chkdsk`) to run on the next restart.

    5.  Automated Driver & Firmware Updates: The tool intelligently handles manufacturer-specific updates.
        - It first detects the computer's manufacturer (e.g., Dell, HP).
        - For Dell Machines: If Dell Command | Update is not found, it automatically downloads the installer,
          performs a silent installation, and then logs a message for the user to run it manually after the final restart.
          If it is already installed, it runs a scan and applies updates automatically.
        - For HP Machines: It checks for HP Image Assistant and runs it if found. If not, it provides a direct link
          and instructions for the user to install it manually.
        - For Other Manufacturers: It provides on-screen guidance for common update tools (e.g., Lenovo Vantage).

    6.  Dual Logging System: All actions, command outputs, successes, and errors are logged in two ways:
        - Real-Time GUI Log: The main window displays a color-coded log of every step as it happens.
        - Permanent File Log: A timestamped text file is created in 'C:\ProgramData\SystemMaintenance' for each
          session, allowing for later analysis and record-keeping.

    7.  Final Mandatory Restart: Upon completion of all tasks, the script displays a final message and, after a
        5-second countdown, performs an automatic restart to ensure all changes are fully applied.
"@
    # Exit the script after showing the help
    exit
}



#region --- Configuration ---

$config = @{
    LogDirectory        = Join-Path -Path $env:ProgramData -ChildPath "SystemMaintenance"
    DellUpdateCLI       = "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe"
    HPImageAssistant    = "C:\Program Files (x86)\HP\HP Image Assistant\HPImageAssistant.exe"
    CompanyPortalAppUri = "companyportal:ApplicationId=9f4e3de0-34be-47c0-be5d-b2c237f85125"
    DellInstallerUrl    = "https://dl.dell.com/FOLDER13309509M/1/Dell-Command-Update-Application_PPWHH_WIN64_5.5.0_A00.EXE"
    LogFile             = Join-Path -Path $env:ProgramData -ChildPath "SystemMaintenance\SystemMaintenance_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    EventLogSource      = "SystemMaintenanceTool"
}

$maintenanceCommands = @(
    # 1. System File Integrity First: Ensures the OS is healthy before updates.
    @{ Name = "Component Store Health Scan (DISM)"; Command = { DISM /Online /Cleanup-Image /ScanHealth } },
    @{ Name = "Component Store Restore (DISM)"; Command = { DISM /Online /Cleanup-Image /RestoreHealth }; SuccessCodes = @(3010) },
    @{ Name = "System File Integrity Scan (SFC)";   Command = { sfc /scannow }; SuccessCodes = @(3010) },

    # 2. Policy and UI Refreshes
    @{ Name = "Forcing Group Policy Update";    Command = { gpupdate /force } },
    @{ Name = "Restarting Windows Explorer";    Command = { Stop-Process -Name explorer -Force; Start-Process explorer } },
    
    # 3. Major Updates: Run on a verified healthy system.
    @{
        Name = "Install/Run PSWindowsUpdate Module"
        Command = {
            $updateCommand = @"
                if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
                    Write-Output 'PSWindowsUpdate module not found. Installing now...'
                    try {
                        Install-Module -Name PSWindowsUpdate -Force -AcceptLicense -Scope AllUsers -ErrorAction Stop
                    } catch {
                        Write-Error "Failed to install PSWindowsUpdate module. Please check internet connectivity. `n`$(`$_.Exception.Message)"
                        return 
                    }
                } else {
                    Write-Output 'PSWindowsUpdate module is already installed.'
                }
                
                Write-Output 'Searching for, downloading, and installing all applicable updates...'
                Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -Verbose -NoReboot
"@
            powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $updateCommand
        }
    },

    # 4. Network Resets: Performed after all network-dependent tasks are complete.
    @{ Name = "Flushing DNS Cache";             Command = { ipconfig /flushdns } },
    @{ Name = "Resetting Winsock Catalog";      Command = { netsh winsock reset }; SuccessCodes = @(1) },
    @{ Name = "Resetting TCP/IP Stack";         Command = { netsh int ip reset }; SuccessCodes = @(1) },

    # 5. Schedule Disk Check: Final task before mandatory restart.
    @{ Name = "Scheduling Disk Check (C:)";       Command = { cmd.exe /c "echo y | chkdsk C: /f /r" }; Note = "This will run on the next restart." }
)

#endregion

#region --- Helper and GUI Functions ---

function Show-MessageBox {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Text,
        [Parameter(Mandatory)] [string]$Title,
        [System.Windows.Forms.MessageBoxButtons]$Buttons = 'OK',
        [System.Windows.Forms.MessageBoxIcon]$Icon = 'None'
    )
    return [System.Windows.Forms.MessageBox]::Show($Text, $Title, $Buttons, $Icon)
}

function Initialize-GUI {
    [CmdletBinding()]
    param()
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text          = "System Maintenance Tool"
        StartPosition = "CenterScreen"
        WindowState   = "Maximized"
    }

    $label = New-Object System.Windows.Forms.Label -Property @{ Text = "Status Log:"; Dock = "Top" }
    $logBox = New-Object System.Windows.Forms.RichTextBox -Property @{ Font = "Consolas, 10"; ReadOnly = $true; ScrollBars = "Vertical"; Dock = "Fill" }
    
    $bottomPanel = New-Object System.Windows.Forms.Panel -Property @{ Height = 40; Dock = "Bottom" }
    $progressBar = New-Object System.Windows.Forms.ProgressBar -Property @{ Style = "Continuous"; Dock = "Fill"}
    $cancelButton = New-Object System.Windows.Forms.Button -Property @{ Text = "Cancel"; Dock = "Right"; Width = 100 }
    
    $bottomPanel.Controls.AddRange(@($progressBar, $cancelButton))
    $form.Controls.AddRange(@($logBox, $label, $bottomPanel))

    return [PSCustomObject]@{
        Form         = $form
        LogBox       = $logBox
        ProgressBar  = $progressBar
        CancelButton = $cancelButton
    }
}

#endregion

#region --- Script Entry Point ---

Add-Type -AssemblyName System.Windows.Forms

# Check for AC Power connection on laptops
$battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
if ($battery) {
    while ((Get-CimInstance -ClassName Win32_Battery).BatteryStatus -eq 1) {
        $promptResult = Show-MessageBox -Text "This maintenance script requires a constant power source. Please connect your laptop to AC power to continue." -Title "Power Connection Required" -Buttons 'OKCancel' -Icon 'Warning'
        if ($promptResult -eq 'Cancel') { exit }
    }
}

# Initial user confirmation
$confirmParams = @{
    Text    = "This tool will perform lengthy system maintenance and will restart your computer. Save all work and close all apps before proceeding.`n`nDo you want to continue?"
    Title   = "Confirmation Required"
    Buttons = 'YesNo'
    Icon    = 'Warning'
}
if ((Show-MessageBox @confirmParams) -ne 'Yes') { exit }

# Check for Admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try {
        Show-MessageBox -Text "This script requires administrator rights. We will now open the Company Portal so you can install them." -Title "Administrator Required" -Icon 'Information'
        Start-Process $config.CompanyPortalAppUri -ErrorAction Stop

        $instructions = @"

ACTION REQUIRED:

The Company Portal app has been opened for you.

1. Please find and click the 'Install' button for the admin rights application. If it says "Reinstall" or "Uninstall", just close the Company Portal and re-run the Maintenance Tool as an Administrator.

2. WAIT for the installation to fully complete.

3. Once it shows 'Installed', MANUALLY RESTART your computer.

4. After restarting, please run this script again as an administrator.

This tool will now close.

"@
        Show-MessageBox -Text $instructions -Title "Manual Steps Required" -Icon 'Information'
    }
    catch {
        Show-MessageBox -Text "Failed to open the Company Portal. Please contact IT for assistance with getting administrator rights." -Title "Error" -Icon 'Error'
    }
    exit
}

# Create Event Log source if it doesn't exist
if (-not ([System.Diagnostics.EventLog]::SourceExists($config.EventLogSource))) {
    try {
        New-EventLog -LogName "Application" -Source $config.EventLogSource -ErrorAction Stop
    }
    catch {
        Show-MessageBox -Text "Could not create the Event Log source '$($config.EventLogSource)'. Logging will be limited to the text file." -Title "Logging Warning" -Icon 'Warning'
    }
}

# Create Logging Directory
if (-not (Test-Path -Path $config.LogDirectory)) {
    try {
        New-Item -Path $config.LogDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Show-MessageBox -Text "Failed to create log directory at '$($config.LogDirectory)'. Please check permissions." -Title "Error" -Icon 'Error'
        exit
    }
}

# Initialize GUI and prepare for background job
$gui = Initialize-GUI

$cancellationState = [hashtable]::Synchronized(@{ CancelRequested = $false })

$gui.CancelButton.add_Click({
    $gui.CancelButton.Text = "Cancelling..."
    $gui.CancelButton.Enabled = $false
    $cancellationState.CancelRequested = $true
    $popupText = "Cancellation signal received.`n`nThe script will stop safely after the current task is finished. This may take several minutes.`n`nIt is strongly not recommended to work on other tasks. The computer will NOT restart. The window will close when cancellation is complete.`n`nWe strongly recommend restarting the computer ASAP."
    Show-MessageBox -Text $popupText -Title "Cancellation Pending" -Icon 'Information'
})

$scriptParameters = @{
    GuiControls         = $gui
    LogFile             = $config.LogFile
    MaintenanceCommands = $maintenanceCommands
    Config              = $config
    CancellationState   = $cancellationState
}

$ps = [powershell]::Create().AddScript({
    param($params)
    
    # Unpack parameters inside the runspace
    $guiControls         = $params.GuiControls
    $logFile             = $params.LogFile
    $maintenanceCommands = $params.MaintenanceCommands
    $config              = $params.Config
    $cancellationState   = $params.CancellationState

    # --- CORE FUNCTIONS  ---
    function Log-Message {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)] $GuiControls,
            [Parameter(Mandatory)] [string]$Message,
            [System.Drawing.Color]$Color = 'Black',
            [Parameter(Mandatory)] [string]$LogFile,
            [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Severity = 'INFO',
            [switch]$NoGuiOutput
        )
        # Always log to the file with the full severity prefix.
        $logEntry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Severity] - $Message"
        $logEntry | Out-File -FilePath $LogFile -Append

        $eventType = switch ($Severity) {
            'ERROR' { 'Error' }
            'WARN'  { 'Warning' }
            default { 'Information' }
        }
        
        if ([System.Diagnostics.EventLog]::SourceExists($config.EventLogSource)) {
            Write-EventLog -LogName "Application" -Source $config.EventLogSource -EventId 1000 -EntryType $eventType -Message $Message
        }

        # Update the GUI without recursion
        if (-not $NoGuiOutput) {
            $logBox = $GuiControls.LogBox
            $appendAction = {
                param($box, $msg, $c)
                $box.SelectionStart = $box.TextLength
                $box.SelectionLength = 0
                $box.SelectionColor = $c
                $box.AppendText("$(Get-Date -Format 'HH:mm:ss') - $msg" + [System.Environment]::NewLine)
                $box.ScrollToCaret()
            }
            if ($logBox.InvokeRequired) {
                $null = $logBox.Invoke($appendAction, @($logBox, $Message, $Color))
            } else {
                & $appendAction $logBox $Message $Color
            }
        }
    }

    function Invoke-LoggedCommand {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)] $GuiControls,
            [Parameter(Mandatory)] [scriptblock]$Command,
            [Parameter(Mandatory)] [string]$Name,
            [Parameter(Mandatory)] [string]$LogFile,
            [array]$SuccessCodes
        )
        Log-Message -GuiControls $GuiControls -Message "Running: $Name..." -LogFile $LogFile -Severity 'INFO'
        
        try {
            $output = & $Command *>&1 | ForEach-Object { $_.ToString() }

            if ($LASTEXITCODE -eq 0) {
                Log-Message -GuiControls $GuiControls -Message "SUCCESS: $Name completed." -Color "Green" -LogFile $LogFile -Severity 'INFO'
                if ($output) { $output | ForEach-Object { if ($_.Trim()) { Log-Message -GuiControls $GuiControls -Message "  $_" -Color "Gray" -LogFile $LogFile -Severity 'INFO' } } }
            }
            elseif ($SuccessCodes -and $LASTEXITCODE -in $SuccessCodes) {
                $warnMsg = "Task '$Name' completed with a special status. This is not an error. It often means repairs were made and a restart is required to finalize them."
                Log-Message -GuiControls $GuiControls -Message $warnMsg -Color "Orange" -LogFile $LogFile -Severity 'WARN'
                if ($output) { $output | ForEach-Object { if ($_.Trim()) { Log-Message -GuiControls $GuiControls -Message "  $_" -Color "Gray" -LogFile $LogFile -Severity 'INFO' } } }
            }
            else {
                Log-Message -GuiControls $GuiControls -Message "Command '$Name' completed with a non-zero exit code: $LASTEXITCODE" -Color "Red" -LogFile $LogFile -Severity 'ERROR'
                if ($output) { $output | ForEach-Object { if ($_.Trim()) { Log-Message -GuiControls $GuiControls -Message "  $_" -Color "Red" -LogFile $LogFile -Severity 'ERROR' } } }
            }
        }
        catch {
            Log-Message -GuiControls $GuiControls -Message "A critical error occurred while running '$Name'." -Color "Red" -LogFile $LogFile -Severity 'ERROR'
            $_.Exception.Message | ForEach-Object { if ($_.Trim()) { Log-Message -GuiControls $GuiControls -Message "  $_" -Color "Red" -LogFile $LogFile -Severity 'ERROR' } }
        }
    }

    function Check-HardwareUpdates {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)] $GuiControls,
            [Parameter(Mandatory)] $Config,
            [Parameter(Mandatory)] [string]$LogFile
        )
        $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
        Log-Message -GuiControls $GuiControls -Message "Manufacturer detected: $manufacturer" -LogFile $LogFile -Severity 'INFO'

        if ($manufacturer -like "*Dell*") {
            Log-Message -GuiControls $GuiControls -Message "Dell system detected..." -Color "Blue" -LogFile $LogFile -Severity 'INFO'
            if (Test-Path $Config.DellUpdateCLI) {
                Invoke-LoggedCommand -GuiControls $GuiControls -Name "Dell Update Scan" -Command { & $Config.DellUpdateCLI /scan } -LogFile $LogFile
                Invoke-LoggedCommand -GuiControls $GuiControls -Name "Dell Update Apply" -Command { & $Config.DellUpdateCLI /applyUpdates -reboot=disable } -LogFile $LogFile
            } else {
                Log-Message -GuiControls $GuiControls -Message "Dell Command | Update not found. Attempting automatic installation..." -Color "Orange" -LogFile $LogFile -Severity 'WARN'
                try {
                    $tempPath = Join-Path $env:TEMP "DCU_Installer.exe"
                    Invoke-WebRequest -Uri $Config.DellInstallerUrl -OutFile $tempPath -ErrorAction Stop
                    Start-Process -FilePath $tempPath -ArgumentList "/s" -Wait -ErrorAction Stop
                    Remove-Item -Path $tempPath -Force
                    Log-Message -GuiControls $GuiControls -Message "ACTION REQUIRED: Dell Command | Update installed. Please run it manually after restart." -Color "Orange" -LogFile $LogFile -Severity 'WARN'
                }
                catch {
                    Log-Message -GuiControls $GuiControls -Message "Failed to install Dell Command | Update. $_" -Color "Red" -LogFile $LogFile -Severity 'ERROR'
                }
            }
        }
        elseif ($manufacturer -like "*HP*") {
            Log-Message -GuiControls $GuiControls -Message "HP system detected..." -Color "Blue" -LogFile $LogFile -Severity 'INFO'
            if (Test-Path $Config.HPImageAssistant) {
                Invoke-LoggedCommand -GuiControls $GuiControls -Name "HP Image Assistant Update" -Command { & $Config.HPImageAssistant /Operation:Analyze /Action:Install /Silent } -LogFile $LogFile
            } else {
                Log-Message -GuiControls $GuiControls -Message "HP Image Assistant not installed. Please download from: https://support.hp.com/us-en/help/hp-support-assistant" -Color "Orange" -LogFile $LogFile -Severity 'WARN'
            }
        }
        else {
            Log-Message -GuiControls $GuiControls -Message "Please check for updates using your manufacturer's tool (e.g., Lenovo Vantage)." -Color "Orange" -LogFile $LogFile -Severity 'WARN'
        }
    }

    function Start-MaintenanceSequence {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)] $GuiControls,
            [Parameter(Mandatory)] $LogFile,
            [Parameter(Mandatory)] $MaintenanceCommands,
            [Parameter(Mandatory)] $Config,
            [Parameter(Mandatory)] $CancellationState
        )
        Log-Message -GuiControls $GuiControls -Message "Administrator privileges confirmed. Starting maintenance..." -Color "Green" -LogFile $LogFile -Severity 'INFO'
        Log-Message -GuiControls $GuiControls -Message "Log file for this session is: $LogFile" -Color "DarkBlue" -LogFile $LogFile -Severity 'INFO'
        
        $GuiControls.ProgressBar.Maximum = $MaintenanceCommands.Count + 1
        $operationCancelled = $false

        foreach ($item in $maintenanceCommands) {
            if ($CancellationState.CancelRequested) {
                Log-Message -GuiControls $GuiControls -Message "Operation cancelled by user. Halting maintenance tasks." -Color "Orange" -LogFile $LogFile -Severity 'WARN'
                $operationCancelled = $true
                break
            }
            Invoke-LoggedCommand -GuiControls $GuiControls -Command $item.Command -Name $item.Name -LogFile $LogFile -SuccessCodes $item.SuccessCodes
            if ($item.Note) { Log-Message -GuiControls $GuiControls -Message "NOTE: $($item.Note)" -Color "Orange" -LogFile $LogFile -Severity 'WARN' }
            $GuiControls.ProgressBar.Value++
        }

        if (-not $operationCancelled) {
            Check-HardwareUpdates -GuiControls $GuiControls -Config $Config -LogFile $LogFile
            $GuiControls.ProgressBar.Value++

            Log-Message -GuiControls $GuiControls -Message "All maintenance tasks are complete. Restarting computer in 120 seconds..." -Color "DarkBlue" -LogFile $LogFile -Severity 'INFO'
            Start-Sleep -Seconds 120
            Restart-Computer -Force
        }
        else {
            Log-Message -GuiControls $GuiControls -Message "Maintenance halted. The system will not be restarted automatically." -Color "DarkBlue" -LogFile $LogFile -Severity 'INFO'
            Start-Sleep -Seconds 120
            if ($GuiControls.Form.IsHandleCreated) {
                $GuiControls.Form.Invoke([Action]{ $GuiControls.Form.Close() })
            }
        }
    }

    # --- SCRIPT EXECUTION (Inside the runspace) ---
    Start-MaintenanceSequence -GuiControls $guiControls -LogFile $logFile -MaintenanceCommands $maintenanceCommands -Config $config -CancellationState $cancellationState

}).AddArgument($scriptParameters)

# Start the background task and show the form
$handle = $ps.BeginInvoke()
$gui.Form.ShowDialog() | Out-Null

# Cleanup
$ps.EndInvoke($handle)
$ps.Dispose()

#endregion
