[CmdletBinding()]
param(
    [switch]$NoGui,
    [switch]$UploadOnly,
    [string]$DriveFolder = "",
    [string]$WorldName = "Dedicated",
    [string]$ServerExecutable = "${env:ProgramFiles(x86)}\Steam\steamapps\common\Valheim dedicated server\valheim_server.exe",
    [string]$WorldDirectory = "$env:USERPROFILE\AppData\LocalLow\IronGate\Valheim\worlds_local",
    [string]$SessionLogPath = "",
    [string]$ServerName = "Valheim World Share",
    [string]$ServerPassword = "valheim",
    [int]$ServerPort = 2456,
    [bool]$Crossplay = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ConfigPath = Join-Path $PSScriptRoot "drive-launcher.config.json"
$script:LauncherPath = $PSCommandPath
if (-not $PSBoundParameters.ContainsKey("DriveFolder") -and (Test-Path -LiteralPath $script:ConfigPath)) {
    try {
        $savedConfig = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        if ($savedConfig.DriveFolder) { $DriveFolder = [string]$savedConfig.DriveFolder }
        if ($savedConfig.WorldName) { $WorldName = [string]$savedConfig.WorldName }
        if ($savedConfig.ServerExecutable) { $ServerExecutable = [string]$savedConfig.ServerExecutable }
        if ($savedConfig.ServerName) { $ServerName = [string]$savedConfig.ServerName }
        if ($savedConfig.ServerPassword) { $ServerPassword = [string]$savedConfig.ServerPassword }
        if ($savedConfig.ServerPort) { $ServerPort = [int]$savedConfig.ServerPort }
    } catch {
        Write-Warning "No se pudo leer la configuracion local."
    }
}

$script:LockName = "server.lock"
$script:ServerExecutable = $ServerExecutable
$script:LogPath = Join-Path $PSScriptRoot "logs\drive-launcher.log"
$script:ChildProcessId = $null
$script:ChildProcess = $null
$script:ServerOutputLineCounts = @{}
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

function Write-NewServerOutput {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$EncodingName
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    try {
        $lines = @(Get-Content -LiteralPath $Path -Encoding $EncodingName -ErrorAction Stop)
        $key = "$Prefix`_$Path"
        $lastCount = if ($script:ServerOutputLineCounts.ContainsKey($key)) {
            $script:ServerOutputLineCounts[$key]
        } else { 0 }
        if ($lines.Count -gt $lastCount) {
            for ($index = $lastCount; $index -lt $lines.Count; $index++) {
                if (-not [string]::IsNullOrWhiteSpace($lines[$index])) {
                    Write-DriveLog "$Prefix $($lines[$index])"
                }
            }
            $script:ServerOutputLineCounts[$key] = $lines.Count
        }
    } catch {
        Write-DriveLog "$Prefix no disponible temporalmente: $($_.Exception.Message)"
    }
}

function Stop-LauncherProcessTree {
    param([Parameter(Mandatory)][int]$ProcessId)
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        Stop-LauncherProcessTree -ProcessId ([int]$child.ProcessId)
    }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -ne $process) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        Write-DriveLog "Proceso del lanzador finalizado: PID $ProcessId."
    }
}

function Save-DriveConfig {
    [ordered]@{
        DriveFolder = $DriveFolder
        WorldName = $WorldName
        ServerExecutable = $script:ServerExecutable
        ServerName = $ServerName
        ServerPassword = $ServerPassword
        ServerPort = $ServerPort
    } | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigPath -Encoding ASCII
}

function Find-ServerExecutable {
    $candidates = @(
        $ServerExecutable,
        "${env:ProgramFiles(x86)}\Steam\steamapps\common\Valheim dedicated server\valheim_server.exe",
        "${env:ProgramFiles}\Steam\steamapps\common\Valheim dedicated server\valheim_server.exe",
        "C:\Steam\steamapps\common\Valheim dedicated server\valheim_server.exe",
        "F:\Steam\steamapps\common\Valheim dedicated server\valheim_server.exe",
        "G:\Steam\steamapps\common\Valheim dedicated server\valheim_server.exe"
    )
    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
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

function Get-LocalWorldDirectory {
    param([switch]$AllowMissing)
    if (-not (Test-Path -LiteralPath $WorldDirectory -PathType Container)) {
        throw "No existe la carpeta local de mundos: $WorldDirectory"
    }
    $worldPath = Join-Path $WorldDirectory $WorldName
    if (Test-Path -LiteralPath $worldPath -PathType Container) {
        return (Resolve-Path -LiteralPath $worldPath).Path
    }
    if ($AllowMissing) {
        return $worldPath
    }
    throw "No se encontro la carpeta del mundo '$WorldName'."
}

function Get-SharedWorldDirectory {
    $root = Test-DriveFolder
    $sharedWorld = Join-Path $root $WorldName
    New-Item -ItemType Directory -Path $sharedWorld -Force | Out-Null
    return $sharedWorld
}

function Get-WorldManifestPath {
    param([Parameter(Mandatory)][string]$WorldPath)
    return Join-Path $WorldPath ".worldshare-meta.json"
}

function Read-WorldUploadedAt {
    param([Parameter(Mandatory)][string]$WorldPath)
    $manifestPath = Get-WorldManifestPath -WorldPath $WorldPath
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $null
    }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if (-not $manifest.UploadedAtUtc) {
            throw "El manifiesto no contiene UploadedAtUtc: $manifestPath"
        }
        return [DateTime]::Parse(
            [string]$manifest.UploadedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        ).ToUniversalTime()
    } catch {
        throw "No se pudo leer el manifiesto del mundo '$WorldName': $($_.Exception.Message)"
    }
}

function Write-WorldManifest {
    param([Parameter(Mandatory)][string]$WorldPath)
    $manifest = [ordered]@{
        WorldName = $WorldName
        UploadedAtUtc = [DateTime]::UtcNow.ToString("o")
        UploadedBy = "$env:COMPUTERNAME\$env:USERNAME"
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Get-WorldManifestPath -WorldPath $WorldPath) -Encoding ASCII
}

function Test-WorldHasFiles {
    param([Parameter(Mandatory)][string]$WorldPath)
    return (Test-Path -LiteralPath $WorldPath -PathType Container) -and
        $null -ne (Get-ChildItem -LiteralPath $WorldPath -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Get-SharedLock {
    $lockPath = Join-Path (Test-DriveFolder) $script:LockName
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        return (Get-Content -LiteralPath $lockPath -Raw -ErrorAction Stop).Trim()
    }
    return $null
}

function Get-LockOwnerFromFolder {
    param([Parameter(Mandatory)][string]$Folder)
    if ([string]::IsNullOrWhiteSpace($Folder)) {
        return $null
    }
    $lockPath = Join-Path $Folder $script:LockName
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        return (Get-Content -LiteralPath $lockPath -Raw -ErrorAction SilentlyContinue).Trim()
    }
    return $null
}

function Wait-FileStable {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$StableSeconds = 3,
        [int]$TimeoutSeconds = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastSignature = $null
    $stableSince = $null
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "El archivo no esta disponible: $Path"
        }
        $item = Get-Item -LiteralPath $Path
        $signature = "$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
        if ($signature -eq $lastSignature) {
            if ($null -eq $stableSince) { $stableSince = Get-Date }
            if (((Get-Date) - $stableSince).TotalSeconds -ge $StableSeconds) {
                return
            }
        } else {
            $lastSignature = $signature
            $stableSince = Get-Date
        }
        Start-Sleep -Seconds 1
    }
    throw "El archivo sigue cambiando y no se puede copiar con seguridad: $Path"
}

function Copy-AndVerifyFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    Wait-FileStable -Path $Source
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Wait-FileStable -Path $Destination
    $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $destinationHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($sourceHash -ne $destinationHash) {
        throw "La verificacion fallo para $([IO.Path]::GetFileName($Source))."
    }
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
    $root = Test-DriveFolder
    $sharedWorld = Join-Path $root $WorldName
    $backupDirectory = Join-Path $WorldDirectory "backups"
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $localWorld = Get-LocalWorldDirectory -AllowMissing
    $hasSharedWorld = Test-WorldHasFiles -WorldPath $sharedWorld
    $hasLocalWorld = Test-WorldHasFiles -WorldPath $localWorld
    if (-not $hasSharedWorld -and -not $hasLocalWorld) {
        New-Item -ItemType Directory -Path $localWorld -Force | Out-Null
        Write-DriveLog "No existe una copia previa para '$WorldName'; se iniciara como mundo nuevo."
        return
    }
    $sharedUploadedAt = if ($hasSharedWorld) { Read-WorldUploadedAt -WorldPath $sharedWorld } else { $null }
    $localUploadedAt = if ($hasLocalWorld) { Read-WorldUploadedAt -WorldPath $localWorld } else { $null }
    $useShared = $hasSharedWorld -and (
        -not $hasLocalWorld -or
        $null -eq $localUploadedAt -or
        $null -ne $sharedUploadedAt -and $sharedUploadedAt -ge $localUploadedAt
    )
    if ($useShared) {
        Write-DriveLog "Usando la copia compartida de '$WorldName' porque es la mas reciente."
    } elseif ($hasLocalWorld) {
        Write-DriveLog "Usando la copia local de '$WorldName' porque es la mas reciente o no hay manifiesto compartido."
    }
    if ($useShared) {
        $backupPath = Join-Path $backupDirectory "$WorldName-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss'))"
        if ($hasLocalWorld) {
            Copy-Item -LiteralPath $localWorld -Destination $backupPath -Recurse -Force
            Write-DriveLog "Backup local creado antes de descargar '$WorldName'."
        }
        New-Item -ItemType Directory -Path $localWorld -Force | Out-Null
        Copy-AndVerifyDirectory -Source $sharedWorld -Destination $localWorld
        Write-DriveLog "Copia compartida descargada y verificada: $WorldName."
    } elseif (-not $hasLocalWorld) {
        New-Item -ItemType Directory -Path $localWorld -Force | Out-Null
    }
}

function Copy-AndVerifyDirectory {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -File -Recurse | ForEach-Object {
        $relative = $_.FullName.Substring($Source.Length).TrimStart('\')
        $target = Join-Path $Destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-AndVerifyFile -Source $_.FullName -Destination $target
    }
}

function Upload-WorldToDrive {
    $sharedWorld = Get-SharedWorldDirectory
    $localWorld = Get-LocalWorldDirectory
    Write-DriveLog "Copiando y verificando el mundo '$WorldName' en la carpeta compartida. Espera hasta que termine."
    Write-WorldManifest -WorldPath $localWorld
    Copy-AndVerifyDirectory -Source $localWorld -Destination $sharedWorld
    Write-DriveLog "Carpeta completa del mundo copiada y verificada: $WorldName."
    Write-DriveLog "Archivos copiados. Revisa el estado de sincronizacion antes de liberar el bloqueo."
}

function Get-AvailableWorldNames {
    $names = @()
    if (Test-Path -LiteralPath $WorldDirectory -PathType Container) {
        $names += Get-ChildItem -LiteralPath $WorldDirectory -Directory |
            Where-Object { $_.Name -ne "backups" -and (Test-WorldHasFiles -WorldPath $_.FullName) } |
            ForEach-Object { $_.Name }
    }
    if (Test-Path -LiteralPath $DriveFolder -PathType Container) {
        $names += Get-ChildItem -LiteralPath $DriveFolder -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "backups" -and (Test-WorldHasFiles -WorldPath $_.FullName) } |
            ForEach-Object { $_.Name }
    }
    return @($names | Sort-Object -Unique)
}

function Request-ServerSettings {
    param([Parameter(Mandatory)]$Owner)
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = "Server settings"
    $dialog.ClientSize = New-Object Drawing.Size(430, 220)
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false

    $nameLabel = New-Object Windows.Forms.Label
    $nameLabel.Text = "Server name"
    $nameLabel.Location = New-Object Drawing.Point(18, 20)
    $nameLabel.AutoSize = $true
    $nameBox = New-Object Windows.Forms.TextBox
    $nameBox.Text = $ServerName
    $nameBox.Location = New-Object Drawing.Point(150, 16)
    $nameBox.Width = 250

    $passwordLabel = New-Object Windows.Forms.Label
    $passwordLabel.Text = "Password (5+ chars)"
    $passwordLabel.Location = New-Object Drawing.Point(18, 62)
    $passwordLabel.AutoSize = $true
    $passwordBox = New-Object Windows.Forms.TextBox
    $passwordBox.Text = $ServerPassword
    $passwordBox.UseSystemPasswordChar = $true
    $passwordBox.Location = New-Object Drawing.Point(150, 58)
    $passwordBox.Width = 250

    $portLabel = New-Object Windows.Forms.Label
    $portLabel.Text = "Port"
    $portLabel.Location = New-Object Drawing.Point(18, 104)
    $portLabel.AutoSize = $true
    $portBox = New-Object Windows.Forms.NumericUpDown
    $portBox.Minimum = 1024
    $portBox.Maximum = 65535
    $portBox.Value = $ServerPort
    $portBox.Location = New-Object Drawing.Point(150, 100)
    $portBox.Width = 100

    $ok = New-Object Windows.Forms.Button
    $ok.Text = "Start"
    $ok.DialogResult = [Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object Drawing.Point(230, 155)
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = "Cancel"
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $cancel.Location = New-Object Drawing.Point(315, 155)
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    $dialog.Controls.AddRange(@($nameLabel, $nameBox, $passwordLabel, $passwordBox, $portLabel, $portBox, $ok, $cancel))

    if ($dialog.ShowDialog($Owner) -ne [Windows.Forms.DialogResult]::OK) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($nameBox.Text) -or $passwordBox.Text.Length -lt 5) {
        [Windows.Forms.MessageBox]::Show("Enter a server name and a password with at least 5 characters.", "Invalid settings", "OK", "Warning") | Out-Null
        return $false
    }
    if ($nameBox.Text -like "*$($passwordBox.Text)*") {
        [Windows.Forms.MessageBox]::Show("The password cannot be part of the server name.", "Invalid settings", "OK", "Warning") | Out-Null
        return $false
    }
    $script:ServerName = $nameBox.Text.Trim()
    $script:ServerPassword = $passwordBox.Text
    $script:ServerPort = [int]$portBox.Value
    Save-DriveConfig
    return $true
}

function Start-DriveSession {
    Test-DriveFolder | Out-Null
    if ($ServerPassword.Length -lt 5) {
        throw "La password debe tener al menos 5 caracteres."
    }
    if ($ServerName -like "*$ServerPassword*") {
        throw "La password no puede estar contenida en el nombre del servidor."
    }
    $detectedServer = Find-ServerExecutable
    if ($null -eq $detectedServer) {
        throw "No se encontro valheim_server.exe. Usa Choose server para seleccionarlo."
    }
    $script:ServerExecutable = $detectedServer
    $ServerExecutable = $detectedServer
    $lockOwner = Get-SharedLock
    if ($null -ne $lockOwner -and $lockOwner.Length -gt 0) {
        throw "El servidor esta siendo usado por: $lockOwner"
    }
    Sync-WorldFromDrive
    New-SharedLock
    $lockCreated = $true
    $serverProcess = $null
    $sessionStarted = $false
    $previousSteamAppId = $env:SteamAppId
    try {
        Write-DriveLog "Iniciando Valheim para el mundo $WorldName."
        $serverOutputLog = "$script:ChildLogPath.server.out.txt"
        $serverErrorLog = "$script:ChildLogPath.server.err.txt"
        $env:SteamAppId = "892970"
        $serverArguments = @(
            "-nographics", "-batchmode", "-name", $ServerName, "-port", $ServerPort,
            "-world", $WorldName, "-password", $ServerPassword, "-public", "0"
        )
        if ($Crossplay) {
            $serverArguments += "-crossplay"
        }
        $serverProcess = Start-Process -FilePath $ServerExecutable -ArgumentList $serverArguments `
            -WorkingDirectory (Split-Path -Parent $ServerExecutable) `
            -RedirectStandardOutput $serverOutputLog -RedirectStandardError $serverErrorLog -WindowStyle Hidden -PassThru
        $sessionStarted = $true
        $nextStatusLog = Get-Date
        while (-not $serverProcess.HasExited) {
            Write-NewServerOutput -Path $serverOutputLog -Prefix "Valheim:" -EncodingName Unicode
            Write-NewServerOutput -Path $serverErrorLog -Prefix "Valheim error:" -EncodingName Unicode
            if ((Get-Date) -ge $nextStatusLog) {
                Write-DriveLog "Servidor en ejecucion. Manteniendo el bloqueo compartido."
                $nextStatusLog = (Get-Date).AddMinutes(10)
            }
            Start-Sleep -Seconds 2
            $serverProcess.Refresh()
        }
        Write-DriveLog "El servidor se cerro. Iniciando la copia de archivos; espera hasta que termine."
        if (Test-Path -LiteralPath $serverOutputLog) {
            $serverOutput = Get-Content -LiteralPath $serverOutputLog -Raw -ErrorAction SilentlyContinue
            if ($serverOutput) {
                Write-DriveLog "Salida del servidor:`n$serverOutput"
            }
        }
        if (Test-Path -LiteralPath $serverErrorLog) {
            $serverError = Get-Content -LiteralPath $serverErrorLog -Raw -ErrorAction SilentlyContinue
            if ($serverError) {
                Write-DriveLog "Errores del servidor:`n$serverError"
            }
        }
        Upload-WorldToDrive
    } finally {
        if ($null -eq $previousSteamAppId) {
            Remove-Item Env:SteamAppId -ErrorAction SilentlyContinue
        } else {
            $env:SteamAppId = $previousSteamAppId
        }
        if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
            Stop-Process -Id $serverProcess.Id
        }
        if ($lockCreated) {
            Remove-SharedLock
            Write-DriveLog "Copia finalizada. El bloqueo compartido fue eliminado automaticamente."
        }
    }
}

function Start-DriveUpload {
    Test-DriveFolder | Out-Null
    $lockOwner = Get-SharedLock
    if ($null -ne $lockOwner -and $lockOwner.Length -gt 0) {
        throw "El servidor esta siendo usado por: $lockOwner"
    }
    New-SharedLock
    try {
        Upload-WorldToDrive
    } finally {
        Remove-SharedLock
        Write-DriveLog "Subida finalizada. El bloqueo compartido fue eliminado automaticamente."
    }
}

function Start-DriveGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not ("DriveLauncher.ConsoleWindow" -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
namespace DriveLauncher {
    public static class ConsoleWindow {
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr handle, int command);
    }
}
"@
    }
    [DriveLauncher.ConsoleWindow]::ShowWindow([DriveLauncher.ConsoleWindow]::GetConsoleWindow(), 0) | Out-Null
    [Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object Windows.Forms.Form
    $form.Text = "Valheim World Share - Google Drive"
    $form.ClientSize = New-Object Drawing.Size(760, 520)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [Drawing.Color]::FromArgb(245, 247, 250)
    $form.MinimumSize = New-Object Drawing.Size(760, 520)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font

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
    [void]$settings.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 150)))
    [void]$settings.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    $folderBox = New-Object Windows.Forms.TextBox
    $folderBox.Text = $DriveFolder
    $folderBox.Dock = "Fill"
    $worldBox = New-Object Windows.Forms.ComboBox
    $worldBox.Text = $WorldName
    $worldBox.DropDownStyle = "DropDown"
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
    $actions.Height = 92
    $actions.Padding = New-Object Windows.Forms.Padding(16, 8, 16, 4)
    $actions.WrapContents = $true
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
    $create = New-Object Windows.Forms.Button
    $create.Text = "Create world"
    $create.Width = 120
    $create.Height = 34
    $upload = New-Object Windows.Forms.Button
    $upload.Text = "Upload world"
    $upload.Width = 120
    $upload.Height = 34
    $refreshWorlds = New-Object Windows.Forms.Button
    $refreshWorlds.Text = "Refresh worlds"
    $refreshWorlds.Width = 120
    $refreshWorlds.Height = 34
    $chooseServer = New-Object Windows.Forms.Button
    $chooseServer.Text = "Choose server"
    $chooseServer.Width = 120
    $chooseServer.Height = 34
    $toolTip = New-Object Windows.Forms.ToolTip
    $toolTip.SetToolTip($choose, "Select the local folder synchronized by Google Drive, Dropbox, OneDrive, or another provider.")
    $toolTip.SetToolTip($test, "Check that the selected folder is available before starting.")
    $toolTip.SetToolTip($start, "Load the selected world, start the dedicated server, and upload it when the server closes.")
    $toolTip.SetToolTip($create, "Prepare a new world name so the dedicated server can create it.")
    $toolTip.SetToolTip($upload, "Upload the selected local world without starting the server.")
    $toolTip.SetToolTip($refreshWorlds, "Reload world folders from local and shared storage.")
    $toolTip.SetToolTip($chooseServer, "Select valheim_server.exe if it is not detected automatically.")
    $actions.Controls.Add($choose)
    $actions.Controls.Add($test)
    $actions.Controls.Add($start)
    $actions.Controls.Add($create)
    $actions.Controls.Add($upload)
    $actions.Controls.Add($refreshWorlds)
    $actions.Controls.Add($chooseServer)

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
            $currentLog = $log.Text
            if ($currentLog -match "Copiando y verificando") {
                $status.Text = "Copiando y verificando archivos. Espera hasta que termine."
                $status.BackColor = [Drawing.Color]::FromArgb(59, 130, 246)
            } elseif ($currentLog -match "El servidor se cerro") {
                $status.Text = "Servidor cerrado. Copiando el mundo; no cierres el programa."
                $status.BackColor = [Drawing.Color]::FromArgb(59, 130, 246)
            } elseif ($currentLog -match "Servidor en ejecucion") {
                $status.Text = "Servidor en ejecucion. Puedes conectarte desde Valheim."
                $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
            } elseif ($currentLog -match "Usando la copia") {
                $status.Text = "Seleccionando la copia mas reciente del mundo."
                $status.BackColor = [Drawing.Color]::FromArgb(59, 130, 246)
            }
        }
        if ($script:ChildProcessId -and $null -eq (Get-Process -Id $script:ChildProcessId -ErrorAction SilentlyContinue)) {
            $logText = if (Test-Path -LiteralPath $script:ChildLogPath) {
                Get-Content -LiteralPath $script:ChildLogPath -Raw -ErrorAction SilentlyContinue
            } else { "" }
            $successful = $logText -match "Carpeta completa del mundo copiada y verificada"
            $failed = $logText -match "ERROR:"
            $start.Enabled = $true
            $upload.Enabled = $true
            $choose.Enabled = $true
            $test.Enabled = $true
            $refreshWorlds.Enabled = $true
            $chooseServer.Enabled = $true
            $create.Enabled = $true
            if ($successful -and -not $failed) {
                $start.Enabled = $true
                $status.Text = "Local copy verified. The shared lock was released."
                $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
                [Windows.Forms.MessageBox]::Show(
                    "The files were copied and verified locally. The shared lock was released automatically.",
                    "Local copy complete",
                    "OK",
                    "Information"
                ) | Out-Null
            } else {
                $status.Text = "The session failed. Check the event log."
                $status.BackColor = [Drawing.Color]::FromArgb(239, 68, 68)
                [Windows.Forms.MessageBox]::Show(
                    "The server did not complete successfully. Check the event log for the exact error.",
                    "Server start failed",
                    "OK",
                    "Error"
                ) | Out-Null
            }
            $script:ChildProcessId = $null
        }
        if (-not $script:ChildProcessId) {
            $owner = Get-LockOwnerFromFolder -Folder $folderBox.Text.Trim()
            if ($null -ne $owner -and $owner.Length -gt 0) {
                $start.Enabled = $false
                $status.Text = "Server locked by another player. Start server is disabled."
                $status.BackColor = [Drawing.Color]::FromArgb(239, 68, 68)
            } elseif ($start.Enabled -eq $false -and $status.Text -like "*locked*") {
                $start.Enabled = $true
                $status.Text = "The shared lock is clear. You can start the server."
                $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
            }
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
    $refreshWorlds.Add_Click({
        try {
            $worldBox.Items.Clear()
            foreach ($availableWorld in Get-AvailableWorldNames) {
                [void]$worldBox.Items.Add($availableWorld)
            }
            if ($worldBox.Items.Count -gt 0 -and [string]::IsNullOrWhiteSpace($worldBox.Text)) {
                $worldBox.SelectedIndex = 0
            }
            $status.Text = "World list updated. You can type a new world name."
            $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
            $owner = Get-LockOwnerFromFolder -Folder $folderBox.Text.Trim()
            if ($null -ne $owner -and $owner.Length -gt 0) {
                $start.Enabled = $false
                $status.Text = "Server locked by another player. Start server is disabled."
                $status.BackColor = [Drawing.Color]::FromArgb(239, 68, 68)
            }
        } catch {
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "World list error", "OK", "Error") | Out-Null
        }
    })
    $chooseServer.Add_Click({
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Title = "Select valheim_server.exe"
        $dialog.Filter = "Valheim server (valheim_server.exe)|valheim_server.exe|Executable files (*.exe)|*.exe"
        $dialog.FileName = "valheim_server.exe"
        if ($dialog.ShowDialog() -eq "OK") {
            $script:ServerExecutable = $dialog.FileName
            Save-DriveConfig
            $status.Text = "Server executable selected."
            $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
        }
    })
    $test.Add_Click({
        try {
            $script:DriveFolder = $folderBox.Text.Trim()
            $script:WorldName = $worldBox.Text.Trim()
            $script:ServerExecutable = $ServerExecutable
            Test-DriveFolder | Out-Null
            Save-DriveConfig
            $status.Text = "Folder is ready."
            $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
        } catch {
            Write-DriveLog "GUI test error: $($_.Exception.Message)"
            $status.Text = "Folder is not available."
            $status.BackColor = [Drawing.Color]::FromArgb(239, 68, 68)
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Folder error", "OK", "Error") | Out-Null
        }
    })
    $start.Add_Click({
        try {
            Write-DriveLog "GUI start requested for world '$($worldBox.Text)'."
            if (-not (Request-ServerSettings -Owner $form)) {
                Write-DriveLog "GUI start cancelled or server settings invalid."
                return
            }
            $script:DriveFolder = $folderBox.Text.Trim()
            $script:WorldName = $worldBox.Text.Trim()
            $script:ServerExecutable = Find-ServerExecutable
            if ($null -eq $script:ServerExecutable) {
                [Windows.Forms.MessageBox]::Show("Server executable not found. Use Choose server first.", "Server not found", "OK", "Warning") | Out-Null
                Write-DriveLog "GUI start blocked: server executable not found."
                return
            }
            Test-DriveFolder | Out-Null
            Save-DriveConfig
            $start.Enabled = $false
            $choose.Enabled = $false
            $test.Enabled = $false
            $script:ChildLogPath = Join-Path $PSScriptRoot "logs\drive-session-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss')).log"
            $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:LauncherPath`" -NoGui -DriveFolder `"$script:DriveFolder`" -WorldName `"$script:WorldName`" -ServerExecutable `"$script:ServerExecutable`" -WorldDirectory `"$WorldDirectory`" -SessionLogPath `"$script:ChildLogPath`" -ServerName `"$script:ServerName`" -ServerPassword `"$script:ServerPassword`" -ServerPort $script:ServerPort"
            $launcherOutputLog = "$script:ChildLogPath.launcher.out.txt"
            $launcherErrorLog = "$script:ChildLogPath.launcher.err.txt"
            Write-DriveLog "GUI child command: powershell.exe $arguments"
            $script:ChildProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments `
                -RedirectStandardOutput $launcherOutputLog -RedirectStandardError $launcherErrorLog -WindowStyle Hidden -PassThru
            $script:ChildProcessId = $script:ChildProcess.Id
            Write-DriveLog "GUI child session started with PID $($script:ChildProcessId)."
            $status.Text = "Sync and server session running."
            $status.BackColor = [Drawing.Color]::FromArgb(59, 130, 246)
            $timer.Start()
        } catch {
            Write-DriveLog "GUI start error: $($_.Exception.Message)"
            $start.Enabled = $true
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Start error", "OK", "Error") | Out-Null
        }
    })
    $create.Add_Click({
        if ([string]::IsNullOrWhiteSpace($worldBox.Text)) {
            [Windows.Forms.MessageBox]::Show("Escribe un nombre para el mundo nuevo.", "Create world", "OK", "Warning") | Out-Null
            return
        }
        if ([Windows.Forms.MessageBox]::Show(
                "Se creara el mundo '$($worldBox.Text)' si no existe. El servidor se iniciara ahora.",
                "Create world",
                "YesNo",
                "Question") -eq "Yes") {
            $start.PerformClick()
        }
    })
    $upload.Add_Click({
        try {
            Write-DriveLog "GUI upload requested for world '$($worldBox.Text)'."
            $script:DriveFolder = $folderBox.Text.Trim()
            $script:WorldName = $worldBox.Text.Trim()
            Test-DriveFolder | Out-Null
            Get-LocalWorldDirectory | Out-Null
            Save-DriveConfig
            $upload.Enabled = $false
            $start.Enabled = $false
            $choose.Enabled = $false
            $test.Enabled = $false
            $refreshWorlds.Enabled = $false
            $chooseServer.Enabled = $false
            $create.Enabled = $false
            $script:ChildLogPath = Join-Path $PSScriptRoot "logs\drive-upload-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss')).log"
            $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -NoGui -DriveFolder `"$script:DriveFolder`" -WorldName `"$script:WorldName`" -ServerExecutable `"$ServerExecutable`" -WorldDirectory `"$WorldDirectory`" -SessionLogPath `"$script:ChildLogPath`" -UploadOnly"
            $script:ChildProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru
            $script:ChildProcessId = $script:ChildProcess.Id
            Write-DriveLog "GUI upload child started with PID $($script:ChildProcessId)."
            $status.Text = "Uploading and verifying world files."
            $status.BackColor = [Drawing.Color]::FromArgb(59, 130, 246)
            $timer.Start()
        } catch {
            Write-DriveLog "GUI upload error: $($_.Exception.Message)"
            $upload.Enabled = $true
            $start.Enabled = $true
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Upload error", "OK", "Error") | Out-Null
        }
    })
    $form.Add_FormClosing({
        $timer.Stop()
        if ($script:ChildProcessId -and (Get-Process -Id $script:ChildProcessId -ErrorAction SilentlyContinue)) {
            $closeSession = [Windows.Forms.MessageBox]::Show(
                "Hay una operacion en curso. Si cierras ahora se detendran sus procesos y puede quedar una copia incompleta. Continuar?",
                "Operacion en curso",
                "YesNo",
                "Warning"
            )
            if ($closeSession -eq [Windows.Forms.DialogResult]::No) {
                $_.Cancel = $true
                $timer.Start()
                return
            }
            Stop-LauncherProcessTree -ProcessId $script:ChildProcessId
            $script:ChildProcessId = $null
        }
    })
    $form.Add_Shown({
        $refreshWorlds.PerformClick()
        $timer.Start()
        $owner = Get-LockOwnerFromFolder -Folder $folderBox.Text.Trim()
        if ($null -ne $owner -and $owner.Length -gt 0) {
            $start.Enabled = $false
            $status.Text = "Server locked by another player. Start server is disabled."
            $status.BackColor = [Drawing.Color]::FromArgb(239, 68, 68)
        }
    })
    [void]$form.ShowDialog()
}

try {
    Write-DriveLog "Launcher started. GUI=$(-not $NoGui) UploadOnly=$UploadOnly"
    if ($NoGui) {
        if ($UploadOnly) {
            Start-DriveUpload *>&1 | Tee-Object -FilePath $script:ChildLogPath -Append
        } else {
            Start-DriveSession *>&1 | Tee-Object -FilePath $script:ChildLogPath -Append
        }
    } else {
        Start-DriveGui
    }
} catch {
    Write-DriveLog "ERROR: $($_.Exception.Message)"
    if ($NoGui) { exit 1 }
    [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Valheim World Share", "OK", "Error") | Out-Null
}
