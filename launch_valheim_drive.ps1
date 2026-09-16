[CmdletBinding()]
param(
    [switch]$NoGui,
    [string]$DriveFolder = "",
    [string]$WorldName = "Dedicated",
    [string]$ServerExecutable = "$env:ProgramFiles(x86)\Steam\steamapps\common\Valheim dedicated server\valheim_server.exe",
    [string]$WorldDirectory = "$env:USERPROFILE\AppData\LocalLow\IronGate\Valheim\worlds_local",
    [string]$SessionLogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ConfigPath = Join-Path $PSScriptRoot "drive-launcher.config.json"
if (-not $PSBoundParameters.ContainsKey("DriveFolder") -and (Test-Path -LiteralPath $script:ConfigPath)) {
    try {
        $savedConfig = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        if ($savedConfig.DriveFolder) { $DriveFolder = [string]$savedConfig.DriveFolder }
        if ($savedConfig.WorldName) { $WorldName = [string]$savedConfig.WorldName }
    } catch {
        Write-Warning "No se pudo leer la configuracion local."
    }
}

$script:LockName = "server.lock"
$script:LogPath = Join-Path $PSScriptRoot "logs\drive-launcher.log"
$script:ChildProcessId = $null
$script:ChildLogPath = if ($SessionLogPath) { $SessionLogPath } else {
    Join-Path $PSScriptRoot "logs\drive-session-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss')).log"
}

function Write-DriveLog {
    param([Parameter(Mandatory)][string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    New-Item -ItemType Directory -Path (Split-Path -Parent $script:LogPath) -Force | Out-Null
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding ASCII
}

function Save-DriveConfig {
    [ordered]@{
        DriveFolder = $DriveFolder
        WorldName = $WorldName
    } | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigPath -Encoding ASCII
}

function Test-DriveFolder {
    if ([string]::IsNullOrWhiteSpace($DriveFolder)) {
        throw "Selecciona una carpeta de Google Drive."
    }
    if (-not (Test-Path -LiteralPath $DriveFolder -PathType Container)) {
        throw "La carpeta no existe o Google Drive no esta conectado: $DriveFolder"
    }
    return (Resolve-Path -LiteralPath $DriveFolder).Path
}

function Get-WorldFiles {
    if (-not (Test-Path -LiteralPath $WorldDirectory -PathType Container)) {
        throw "No existe la carpeta local de mundos: $WorldDirectory"
    }
    $files = @()
    foreach ($extension in @("*.db", "*.fwl")) {
        $files += Get-ChildItem -LiteralPath $WorldDirectory -Filter "$WorldName$extension" -File -ErrorAction SilentlyContinue
    }
    if ($files.Count -eq 0) {
        throw "No se encontraron archivos del mundo '$WorldName'."
    }
    return $files
}

function Get-SharedWorldDirectory {
    $root = Test-DriveFolder
    $sharedWorld = Join-Path $root $WorldName
    New-Item -ItemType Directory -Path $sharedWorld -Force | Out-Null
    return $sharedWorld
}

function Get-SharedLock {
    $lockPath = Join-Path (Test-DriveFolder) $script:LockName
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        return (Get-Content -LiteralPath $lockPath -Raw -ErrorAction Stop).Trim()
    }
    return $null
}

function New-SharedLock {
    $root = Test-DriveFolder
    $lockPath = Join-Path $root $script:LockName
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        throw "El servidor esta siendo usado por otro jugador."
    }
    $temporary = Join-Path $root ".server-$([Guid]::NewGuid().ToString('N')).tmp"
    Set-Content -LiteralPath $temporary -Value "Host: $env:COMPUTERNAME`nUser: $env:USERNAME`nStart: $(Get-Date -Format o)" -Encoding ASCII
    Move-Item -LiteralPath $temporary -Destination $lockPath -Force
    Write-DriveLog "Bloqueo compartido creado."
}

function Remove-SharedLock {
    $lockPath = Join-Path (Test-DriveFolder) $script:LockName
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        Remove-Item -LiteralPath $lockPath -Force
        Write-DriveLog "Bloqueo compartido eliminado."
    }
}

function Sync-WorldFromDrive {
    $sharedWorld = Get-SharedWorldDirectory
    $backupDirectory = Join-Path $WorldDirectory "backups"
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    foreach ($localFile in Get-WorldFiles) {
        $sharedFile = Join-Path $sharedWorld $localFile.Name
        if (-not (Test-Path -LiteralPath $sharedFile -PathType Leaf)) {
            continue
        }
        $remoteFile = Get-Item -LiteralPath $sharedFile
        if ($remoteFile.LastWriteTimeUtc -gt $localFile.LastWriteTimeUtc) {
            Copy-Item -LiteralPath $localFile.FullName -Destination (Join-Path $backupDirectory "$($localFile.Name).bak") -Force
            Copy-Item -LiteralPath $sharedFile -Destination $localFile.FullName -Force
            Write-DriveLog "Descargado $($localFile.Name) desde Google Drive."
        }
    }
}

function Start-DriveSession {
    Test-DriveFolder | Out-Null
    $lockOwner = Get-SharedLock
    if ($null -ne $lockOwner -and $lockOwner.Length -gt 0) {
        throw "El servidor esta siendo usado por: $lockOwner"
    }
    Sync-WorldFromDrive
    New-SharedLock
    $serverProcess = $null
    try {
        if (-not (Test-Path -LiteralPath $ServerExecutable -PathType Leaf)) {
            throw "No se encontro el ejecutable del servidor: $ServerExecutable"
        }
        Write-DriveLog "Iniciando Valheim para el mundo $WorldName."
        $serverProcess = Start-Process -FilePath $ServerExecutable -ArgumentList @(
            "-nographics", "-batchmode", "-world", $WorldName
        ) -PassThru
        Wait-Process -Id $serverProcess.Id
        $sharedWorld = Get-SharedWorldDirectory
        foreach ($localFile in Get-WorldFiles) {
            Copy-Item -LiteralPath $localFile.FullName -Destination (Join-Path $sharedWorld $localFile.Name) -Force
            Write-DriveLog "Subido $($localFile.Name) a Google Drive."
        }
    } finally {
        if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
            Stop-Process -Id $serverProcess.Id
        }
        Remove-SharedLock
    }
}

function Start-DriveGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object Windows.Forms.Form
    $form.Text = "Valheim World Share - Google Drive"
    $form.ClientSize = New-Object Drawing.Size(760, 520)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [Drawing.Color]::FromArgb(245, 247, 250)

    $header = New-Object Windows.Forms.Label
    $header.Text = "VALHEIM WORLD SHARE - GOOGLE DRIVE"
    $header.Dock = "Top"
    $header.Height = 52
    $header.Padding = New-Object Windows.Forms.Padding(16, 14, 0, 0)
    $header.BackColor = [Drawing.Color]::FromArgb(31, 41, 55)
    $header.ForeColor = [Drawing.Color]::White
    $header.Font = New-Object Drawing.Font("Segoe UI", 12, [Drawing.FontStyle]::Bold)

    $status = New-Object Windows.Forms.Label
    $status.Text = "Selecciona la carpeta sincronizada."
    $status.Dock = "Top"
    $status.Height = 42
    $status.TextAlign = "MiddleCenter"
    $status.BackColor = [Drawing.Color]::FromArgb(245, 158, 11)
    $status.ForeColor = [Drawing.Color]::White
    $status.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)

    $settings = New-Object Windows.Forms.TableLayoutPanel
    $settings.Dock = "Top"
    $settings.Height = 120
    $settings.Padding = New-Object Windows.Forms.Padding(16, 10, 16, 4)
    $settings.ColumnCount = 2
    $settings.RowCount = 2
    $settings.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 150)))
    $settings.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    $folderBox = New-Object Windows.Forms.TextBox
    $folderBox.Text = $DriveFolder
    $folderBox.Dock = "Fill"
    $worldBox = New-Object Windows.Forms.TextBox
    $worldBox.Text = $WorldName
    $worldBox.Dock = "Fill"
    $folderLabel = New-Object Windows.Forms.Label
    $folderLabel.Text = "Google Drive folder"
    $worldLabel = New-Object Windows.Forms.Label
    $worldLabel.Text = "World name"
    $settings.Controls.Add($folderLabel, 0, 0)
    $settings.Controls.Add($folderBox, 1, 0)
    $settings.Controls.Add($worldLabel, 0, 1)
    $settings.Controls.Add($worldBox, 1, 1)

    $actions = New-Object Windows.Forms.FlowLayoutPanel
    $actions.Dock = "Top"
    $actions.Height = 60
    $actions.Padding = New-Object Windows.Forms.Padding(16, 8, 16, 4)
    $actions.WrapContents = $false
    $choose = New-Object Windows.Forms.Button
    $choose.Text = "Choose folder"
    $choose.Width = 130
    $choose.Height = 34
    $test = New-Object Windows.Forms.Button
    $test.Text = "Test folder"
    $test.Width = 110
    $test.Height = 34
    $start = New-Object Windows.Forms.Button
    $start.Text = "Start server"
    $start.Width = 130
    $start.Height = 34
    $release = New-Object Windows.Forms.Button
    $release.Text = "Release lock"
    $release.Width = 120
    $release.Height = 34
    $actions.Controls.Add($choose)
    $actions.Controls.Add($test)
    $actions.Controls.Add($start)
    $actions.Controls.Add($release)

    $log = New-Object Windows.Forms.TextBox
    $log.Multiline = $true
    $log.ReadOnly = $true
    $log.ScrollBars = "Vertical"
    $log.Dock = "Fill"
    $log.BackColor = [Drawing.Color]::FromArgb(17, 24, 39)
    $log.ForeColor = [Drawing.Color]::FromArgb(229, 231, 235)
    $log.BorderStyle = "None"
    $log.Font = New-Object Drawing.Font("Consolas", 9)
    $form.Controls.Add($log)
    $form.Controls.Add($actions)
    $form.Controls.Add($settings)
    $form.Controls.Add($status)
    $form.Controls.Add($header)

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        if (Test-Path -LiteralPath $script:ChildLogPath) {
            $log.Text = Get-Content -LiteralPath $script:ChildLogPath -Raw
            $log.SelectionStart = $log.Text.Length
            $log.ScrollToCaret()
        }
        if ($script:ChildProcessId -and $null -eq (Get-Process -Id $script:ChildProcessId -ErrorAction SilentlyContinue)) {
            $timer.Stop()
            $start.Enabled = $true
            $status.Text = "Session finished."
            $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
        }
    })
    $choose.Add_Click({
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Select your local Google Drive folder"
        if ($dialog.ShowDialog() -eq "OK") {
            $folderBox.Text = $dialog.SelectedPath
            $script:DriveFolder = $folderBox.Text
            Save-DriveConfig
            $status.Text = "Folder selected. Test it before starting."
            $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
        }
    })
    $test.Add_Click({
        try {
            $script:DriveFolder = $folderBox.Text.Trim()
            $script:WorldName = $worldBox.Text.Trim()
            Test-DriveFolder | Out-Null
            Save-DriveConfig
            $status.Text = "Folder is ready."
            $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
        } catch {
            $status.Text = "Folder is not available."
            $status.BackColor = [Drawing.Color]::FromArgb(239, 68, 68)
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Folder error", "OK", "Error") | Out-Null
        }
    })
    $start.Add_Click({
        try {
            $script:DriveFolder = $folderBox.Text.Trim()
            $script:WorldName = $worldBox.Text.Trim()
            Test-DriveFolder | Out-Null
            Save-DriveConfig
            $start.Enabled = $false
            $choose.Enabled = $false
            $test.Enabled = $false
            $script:ChildLogPath = Join-Path $PSScriptRoot "logs\drive-session-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss')).log"
            $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -NoGui -DriveFolder `"$script:DriveFolder`" -WorldName `"$script:WorldName`" -ServerExecutable `"$ServerExecutable`" -WorldDirectory `"$WorldDirectory`" -SessionLogPath `"$script:ChildLogPath`""
            $script:ChildProcessId = (Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru).Id
            $status.Text = "Sync and server session running."
            $status.BackColor = [Drawing.Color]::FromArgb(59, 130, 246)
            $timer.Start()
        } catch {
            $start.Enabled = $true
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Start error", "OK", "Error") | Out-Null
        }
    })
    $release.Add_Click({
        if ([Windows.Forms.MessageBox]::Show("Only release this lock when nobody is playing. Continue?", "Warning", "YesNo", "Warning") -eq "Yes") {
            try {
                $script:DriveFolder = $folderBox.Text.Trim()
                Remove-SharedLock
                $status.Text = "Shared lock removed."
                $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
            } catch {
                [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Release error", "OK", "Error") | Out-Null
            }
        }
    })
    $form.Add_FormClosing({ $timer.Stop() })
    [void]$form.ShowDialog()
}

try {
    if ($NoGui) {
        Start-DriveSession *>&1 | Tee-Object -FilePath $script:ChildLogPath -Append
    } else {
        Start-DriveGui
    }
} catch {
    Write-DriveLog "ERROR: $($_.Exception.Message)"
    if ($NoGui) { exit 1 }
    [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Valheim World Share", "OK", "Error") | Out-Null
}
