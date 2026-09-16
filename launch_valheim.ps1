[CmdletBinding()]
param(
    [switch]$NoGui,
    [string]$Remote = "gdrive:",
    [string]$WorldName = "Dedicated",
    [string]$ServerExecutable = "${env:ProgramFiles(x86)}\Steam\steamapps\common\Valheim dedicated server\valheim_server.exe",
    [string]$WorldDirectory = "$env:USERPROFILE\AppData\LocalLow\IronGate\Valheim\worlds_local",
    [string]$RclonePath = "$PSScriptRoot\.tools\rclone.exe",
    [int]$NetworkTimeoutSeconds = 60,
    [string]$SessionLogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ConfigPath = Join-Path $PSScriptRoot "launcher.config.json"
if (-not $PSBoundParameters.ContainsKey("Remote") -and (Test-Path -LiteralPath $script:ConfigPath)) {
    try {
        $savedConfig = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        if ($savedConfig.Remote) { $Remote = [string]$savedConfig.Remote }
        if ($savedConfig.WorldName) { $WorldName = [string]$savedConfig.WorldName }
    } catch {
        Write-Warning "No se pudo leer la configuracion local. Se usaran valores por defecto."
    }
}

$script:LockName = "server.lock"
$script:ChildProcessId = $null
$script:LogPath = Join-Path $PSScriptRoot "logs\launcher.log"
$script:ChildLogPath = if ($SessionLogPath) { $SessionLogPath } else {
    Join-Path $PSScriptRoot "logs\session-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss')).log"
}

function Write-LauncherLog {
    param([Parameter(Mandatory)][string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    $directory = Split-Path -Parent $script:LogPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}

function Get-RclonePath {
    if (Test-Path -LiteralPath $RclonePath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $RclonePath).Path
    }

    $installed = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if ($null -ne $installed) {
        return $installed.Source
    }

    $toolDirectory = Split-Path -Parent $RclonePath
    New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
    $archive = Join-Path $toolDirectory "rclone.zip"
    $downloadUrl = "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
    Write-LauncherLog "rclone no esta instalado; descargando la version portable."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $archive -UseBasicParsing
    Expand-Archive -LiteralPath $archive -DestinationPath $toolDirectory -Force
    $downloaded = Get-ChildItem -Path $toolDirectory -Filter "rclone.exe" -Recurse | Select-Object -First 1
    if ($null -eq $downloaded) {
        throw "La descarga de rclone no contiene rclone.exe."
    }
    Copy-Item -LiteralPath $downloaded.FullName -Destination $RclonePath -Force
    Remove-Item -LiteralPath $archive -Force
    Get-ChildItem -Path $toolDirectory -Directory -Filter "rclone-v*" | Remove-Item -Recurse -Force
    return (Resolve-Path -LiteralPath $RclonePath).Path
}

function Save-LauncherConfig {
    $config = [ordered]@{
        Remote = $Remote
        WorldName = $WorldName
    }
    $config | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigPath -Encoding ASCII
}

function Start-RcloneSetup {
    param([Parameter(Mandatory)][string]$Executable)
    Start-Process -FilePath $Executable -ArgumentList "config" -Wait
}

function Test-RcloneConnection {
    param([Parameter(Mandatory)][string]$Executable)
    Invoke-Rclone -Executable $Executable -Arguments @(
        "lsd", $Remote, "--max-depth", "1", "--timeout", "$NetworkTimeoutSeconds`s"
    ) | Out-Null
}

function Invoke-Rclone {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $output = & $Executable @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "rclone fallo ($LASTEXITCODE): $($output -join [Environment]::NewLine)"
    }
    return @($output)
}

function Get-RemoteLock {
    param([Parameter(Mandatory)][string]$Executable)
    $lockPath = "$Remote/$script:LockName"
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("valheim-lock-" + [Guid]::NewGuid().ToString("N") + ".txt")
    try {
        & $Executable copyto $lockPath $temporary --timeout "$NetworkTimeoutSeconds`s" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return (Get-Content -LiteralPath $temporary -Raw -ErrorAction Stop).Trim()
        }
        return $null
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-WorldFiles {
    if (-not (Test-Path -LiteralPath $WorldDirectory -PathType Container)) {
        throw "No existe la carpeta de mundos: $WorldDirectory"
    }
    $files = @()
    foreach ($extension in @("*.db", "*.fwl")) {
        $files += Get-ChildItem -LiteralPath $WorldDirectory -Filter "$WorldName$extension" -File -ErrorAction SilentlyContinue
    }
    if ($files.Count -eq 0) {
        throw "No se encontraron archivos .db/.fwl para el mundo '$WorldName'."
    }
    return $files
}

function Sync-WorldFromRemote {
    param([Parameter(Mandatory)][string]$Executable)
    $remoteWorld = "$Remote/$WorldName"
    $backupDirectory = Join-Path $WorldDirectory "backups"
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    foreach ($file in Get-WorldFiles) {
        $remoteFile = "$remoteWorld/$($file.Name)"
        $remoteInfo = & $Executable lsl $remoteFile 2>$null
        if ($LASTEXITCODE -ne 0 -or $remoteInfo.Count -eq 0) {
            continue
        }
        $parts = $remoteInfo[0] -split "\s+", 4
        if ($parts.Count -lt 3) {
            throw "Respuesta invalida de rclone para $remoteFile."
        }
        $remoteTimestamp = [DateTime]::Parse("$($parts[1]) $($parts[2])").ToUniversalTime()
        if ($remoteTimestamp -gt $file.LastWriteTimeUtc) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $backupDirectory "$($file.Name).bak") -Force
            Invoke-Rclone -Executable $Executable -Arguments @(
                "copyto", $remoteFile, $file.FullName, "--timeout", "$NetworkTimeoutSeconds`s"
            ) | Out-Null
            Write-LauncherLog "Descargado $($file.Name) desde Google Drive."
        }
    }
}

function New-RemoteLock {
    param([Parameter(Mandatory)][string]$Executable)
    $lockContents = "Host: $env:COMPUTERNAME`nUsuario: $env:USERNAME`nInicio: $(Get-Date -Format o)"
    $localLock = Join-Path ([IO.Path]::GetTempPath()) ("valheim-lock-" + [Guid]::NewGuid().ToString("N") + ".txt")
    try {
        Set-Content -LiteralPath $localLock -Value $lockContents -Encoding UTF8
        Invoke-Rclone -Executable $Executable -Arguments @(
            "copyto", $localLock, "$Remote/$script:LockName", "--timeout", "$NetworkTimeoutSeconds`s"
        ) | Out-Null
        Write-LauncherLog "Bloqueo remoto creado para $env:USERNAME."
    } finally {
        Remove-Item -LiteralPath $localLock -Force -ErrorAction SilentlyContinue
    }
}

function Remove-RemoteLock {
    param([Parameter(Mandatory)][string]$Executable)
    Invoke-Rclone -Executable $Executable -Arguments @(
        "deletefile", "$Remote/$script:LockName", "--timeout", "$NetworkTimeoutSeconds`s"
    ) | Out-Null
    Write-LauncherLog "Bloqueo remoto eliminado."
}

function Start-ValheimSession {
    $rclone = Get-RclonePath
    $lockOwner = Get-RemoteLock -Executable $rclone
    if ($null -ne $lockOwner -and $lockOwner.Length -gt 0) {
        throw "El servidor esta siendo usado por $lockOwner. Espera a que termine."
    }

    Sync-WorldFromRemote -Executable $rclone
    New-RemoteLock -Executable $rclone
    $serverProcess = $null
    try {
        if (-not (Test-Path -LiteralPath $ServerExecutable -PathType Leaf)) {
            throw "No se encontro el ejecutable del servidor: $ServerExecutable"
        }
        Write-LauncherLog "Iniciando Valheim para el mundo $WorldName."
        $serverProcess = Start-Process -FilePath $ServerExecutable -ArgumentList @(
            "-nographics", "-batchmode", "-world", $WorldName
        ) -PassThru
        Wait-Process -Id $serverProcess.Id
        Write-LauncherLog "El proceso de Valheim termino; subiendo cambios."
        foreach ($file in Get-WorldFiles) {
            Invoke-Rclone -Executable $rclone -Arguments @(
                "copyto", $file.FullName, "$Remote/$WorldName/$($file.Name)",
                "--timeout", "$NetworkTimeoutSeconds`s"
            ) | Out-Null
            Write-LauncherLog "Subido $($file.Name) a Google Drive."
        }
    } finally {
        if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
            Stop-Process -Id $serverProcess.Id
        }
        try {
            Remove-RemoteLock -Executable $rclone
        } catch {
            Write-LauncherLog "ADVERTENCIA: no se pudo eliminar el bloqueo remoto: $($_.Exception.Message)"
            throw
        }
    }
}

function Start-LauncherGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object Windows.Forms.Form
    $form.Text = "Valheim World Share"
    $form.ClientSize = New-Object Drawing.Size(760, 560)
    $form.StartPosition = "CenterScreen"
    $form.MinimumSize = New-Object Drawing.Size(700, 500)
    $form.BackColor = [Drawing.Color]::FromArgb(245, 247, 250)

    $status = New-Object Windows.Forms.Label
    $status.Text = "Servidor disponible. Haz clic para iniciar."
    $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
    $status.Dock = "Fill"
    $status.Height = 54
    $status.TextAlign = "MiddleCenter"
    $status.Font = New-Object Drawing.Font("Segoe UI", 11, [Drawing.FontStyle]::Bold)
    $status.ForeColor = [Drawing.Color]::White

    $header = New-Object Windows.Forms.Panel
    $header.Dock = "Top"
    $header.Height = 76
    $header.Padding = New-Object Windows.Forms.Padding(16, 10, 16, 10)
    $header.BackColor = [Drawing.Color]::FromArgb(31, 41, 55)
    $title = New-Object Windows.Forms.Label
    $title.Text = "VALHEIM WORLD SHARE"
    $title.Dock = "Top"
    $title.Height = 28
    $title.ForeColor = [Drawing.Color]::White
    $title.Font = New-Object Drawing.Font("Segoe UI", 14, [Drawing.FontStyle]::Bold)
    $subtitle = New-Object Windows.Forms.Label
    $subtitle.Text = "Sincronizacion segura de partidas con Google Drive"
    $subtitle.Dock = "Fill"
    $subtitle.ForeColor = [Drawing.Color]::FromArgb(209, 213, 219)
    $subtitle.Font = New-Object Drawing.Font("Segoe UI", 9)
    $header.Controls.Add($subtitle)
    $header.Controls.Add($title)

    $details = New-Object Windows.Forms.TableLayoutPanel
    $details.Dock = "Top"
    $details.Height = 116
    $details.Padding = New-Object Windows.Forms.Padding(16, 12, 16, 6)
    $details.ColumnCount = 2
    $details.RowCount = 3
    $details.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 130)))
    $details.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    foreach ($row in 0..2) {
        $details.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 30)))
    }
    $details.BackColor = [Drawing.Color]::White

    $worldLabel = New-Object Windows.Forms.Label
    $worldLabel.Text = "Mundo"
    $worldLabel.TextAlign = "MiddleLeft"
    $remoteLabel = New-Object Windows.Forms.Label
    $remoteLabel.Text = "Remoto"
    $remoteLabel.TextAlign = "MiddleLeft"
    $serverLabel = New-Object Windows.Forms.Label
    $serverLabel.Text = "Ejecutable"
    $serverLabel.TextAlign = "MiddleLeft"
    $worldValue = New-Object Windows.Forms.TextBox
    $worldValue.Text = $WorldName
    $worldValue.Dock = "Fill"
    $remoteValue = New-Object Windows.Forms.TextBox
    $remoteValue.Text = $Remote
    $remoteValue.Dock = "Fill"
    $serverValue = New-Object Windows.Forms.Label
    $serverValue.Text = $ServerExecutable
    $serverValue.AutoEllipsis = $true
    $details.Controls.Add($worldLabel, 0, 0)
    $details.Controls.Add($worldValue, 1, 0)
    $details.Controls.Add($remoteLabel, 0, 1)
    $details.Controls.Add($remoteValue, 1, 1)
    $details.Controls.Add($serverLabel, 0, 2)
    $details.Controls.Add($serverValue, 1, 2)
    foreach ($control in @($worldLabel, $remoteLabel, $serverLabel)) {
        $control.Font = New-Object Drawing.Font("Segoe UI", 9, [Drawing.FontStyle]::Bold)
        $control.ForeColor = [Drawing.Color]::FromArgb(75, 85, 99)
    }
    foreach ($control in @($worldValue, $remoteValue, $serverValue)) {
        $control.Font = New-Object Drawing.Font("Segoe UI", 9)
        $control.ForeColor = [Drawing.Color]::FromArgb(31, 41, 55)
    }

    $setup = New-Object Windows.Forms.Button
    $setup.Text = "Configurar Google Drive"
    $setup.Dock = "Top"
    $setup.Height = 32
    $setup.FlatStyle = "Flat"
    $setup.Font = New-Object Drawing.Font("Segoe UI", 9)
    $setup.BackColor = [Drawing.Color]::FromArgb(219, 234, 254)

    $actionPanel = New-Object Windows.Forms.FlowLayoutPanel
    $actionPanel.Dock = "Top"
    $actionPanel.Height = 72
    $actionPanel.Padding = New-Object Windows.Forms.Padding(16, 10, 16, 8)
    $actionPanel.BackColor = [Drawing.Color]::FromArgb(245, 247, 250)
    $actionPanel.WrapContents = $false

    $start = New-Object Windows.Forms.Button
    $start.Text = "Iniciar servidor"
    $start.Width = 170
    $start.Height = 40
    $start.BackColor = [Drawing.Color]::FromArgb(37, 99, 235)
    $start.ForeColor = [Drawing.Color]::White
    $start.FlatStyle = "Flat"
    $start.Font = New-Object Drawing.Font("Segoe UI", 9, [Drawing.FontStyle]::Bold)
    $release = New-Object Windows.Forms.Button
    $release.Text = "Liberar bloqueo"
    $release.Width = 150
    $release.Height = 40
    $release.FlatStyle = "Flat"
    $release.Font = New-Object Drawing.Font("Segoe UI", 9)
    $refresh = New-Object Windows.Forms.Button
    $refresh.Text = "Actualizar estado"
    $refresh.Width = 145
    $refresh.Height = 40
    $refresh.FlatStyle = "Flat"
    $refresh.Font = New-Object Drawing.Font("Segoe UI", 9)
    $actionPanel.Controls.Add($start)
    $actionPanel.Controls.Add($release)
    $actionPanel.Controls.Add($refresh)
    $actionPanel.Controls.Add($setup)

    $progress = New-Object Windows.Forms.ProgressBar
    $progress.Dock = "Top"
    $progress.Height = 8
    $progress.Style = "Marquee"
    $progress.MarqueeAnimationSpeed = 30
    $progress.Visible = $false

    $logTitle = New-Object Windows.Forms.Label
    $logTitle.Text = "EVENTOS DE LA SESION"
    $logTitle.Dock = "Top"
    $logTitle.Height = 28
    $logTitle.Padding = New-Object Windows.Forms.Padding(16, 8, 0, 0)
    $logTitle.Font = New-Object Drawing.Font("Segoe UI", 8, [Drawing.FontStyle]::Bold)
    $logTitle.ForeColor = [Drawing.Color]::FromArgb(75, 85, 99)
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
    $form.Controls.Add($logTitle)
    $form.Controls.Add($progress)
    $form.Controls.Add($actionPanel)
    $form.Controls.Add($details)
    $statusHost = New-Object Windows.Forms.Panel
    $statusHost.Dock = "Top"
    $statusHost.Height = 54
    $statusHost.Padding = New-Object Windows.Forms.Padding(16, 8, 16, 8)
    $statusHost.BackColor = [Drawing.Color]::FromArgb(245, 247, 250)
    $statusHost.Controls.Add($status)
    $form.Controls.Add($statusHost)
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
            $progress.Visible = $false
            $start.Enabled = $true
            $release.Enabled = $true
            $refresh.Enabled = $true
            $status.Text = "Sesion finalizada. El mundo se guardo correctamente."
            $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
        }
    })
    $start.Add_Click({
        $script:Remote = $remoteValue.Text.Trim()
        $script:WorldName = $worldValue.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($script:Remote) -or [string]::IsNullOrWhiteSpace($script:WorldName)) {
            [Windows.Forms.MessageBox]::Show("Completa el remoto y el nombre del mundo.", "Datos incompletos", "OK", "Warning") | Out-Null
            return
        }
        Save-LauncherConfig
        $start.Enabled = $false
        $release.Enabled = $false
        $refresh.Enabled = $false
        $progress.Visible = $true
        $status.Text = "Sincronizando partida... No cierres la ventana."
        $status.BackColor = [Drawing.Color]::FromArgb(59, 130, 246)
        $script:ChildLogPath = Join-Path $PSScriptRoot "logs\session-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss')).log"
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -NoGui -Remote `"$Remote`" -WorldName `"$WorldName`" -ServerExecutable `"$ServerExecutable`" -WorldDirectory `"$WorldDirectory`" -RclonePath `"$RclonePath`" -SessionLogPath `"$script:ChildLogPath`""
        $script:ChildProcessId = (Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru).Id
        $timer.Start()
    })
    $setup.Add_Click({
        try {
            $setup.Enabled = $false
            $status.Text = "Abriendo configuracion de Google Drive..."
            $status.BackColor = [Drawing.Color]::FromArgb(59, 130, 246)
            Start-RcloneSetup -Executable (Get-RclonePath)
            [Windows.Forms.MessageBox]::Show("Configuracion terminada. Pulsa Actualizar estado para probar el acceso.", "Google Drive", "OK", "Information") | Out-Null
            $status.Text = "Configuracion lista. Pulsa Actualizar estado."
            $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
        } catch {
            $status.Text = "No se pudo configurar Google Drive."
            $status.BackColor = [Drawing.Color]::FromArgb(239, 68, 68)
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error de configuracion", "OK", "Error") | Out-Null
        } finally {
            $setup.Enabled = $true
        }
    })
    $release.Add_Click({
        if ([Windows.Forms.MessageBox]::Show("Solo libera el bloqueo si confirmaste que nadie esta jugando. Continuar?", "Advertencia", "YesNo", "Warning") -eq "Yes") {
            try {
                Remove-RemoteLock -Executable (Get-RclonePath)
                $status.Text = "Servidor disponible. Bloqueo liberado."
                $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
            } catch {
                [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error", "OK", "Error") | Out-Null
            }
        }
    })
    $refresh.Add_Click({
        try {
            $script:Remote = $remoteValue.Text.Trim()
            $script:WorldName = $worldValue.Text.Trim()
            Save-LauncherConfig
            Test-RcloneConnection -Executable (Get-RclonePath)
            $lockOwner = Get-RemoteLock -Executable (Get-RclonePath)
            if ($null -ne $lockOwner -and $lockOwner.Length -gt 0) {
                $status.Text = "Servidor ocupado. $lockOwner"
                $status.BackColor = [Drawing.Color]::FromArgb(239, 68, 68)
            } else {
                $status.Text = "Servidor disponible. Haz clic para iniciar."
                $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
            }
        } catch {
            $status.Text = "No se pudo consultar el estado remoto."
            $status.BackColor = [Drawing.Color]::FromArgb(245, 158, 11)
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error de conexion", "OK", "Error") | Out-Null
        }
    })
    $form.Add_FormClosing({
        $timer.Stop()
    })
    $form.Add_Shown({
        $rcloneConfig = Join-Path $env:APPDATA "rclone\rclone.conf"
        if (-not (Test-Path -LiteralPath $rcloneConfig)) {
            $answer = [Windows.Forms.MessageBox]::Show(
                "Es la primera ejecucion. Debes conectar tu cuenta de Google Drive. Quieres configurarla ahora?",
                "Configuracion inicial",
                "YesNo",
                "Information"
            )
            if ($answer -eq "Yes") {
                $setup.PerformClick()
            }
        }
    })
    [void]$form.ShowDialog()
}

try {
    if ($NoGui) {
        Start-ValheimSession *>&1 | Tee-Object -FilePath $script:ChildLogPath -Append
    } else {
        Start-LauncherGui
    }
} catch {
    Write-LauncherLog "ERROR: $($_.Exception.Message)"
    if ($NoGui) { exit 1 }
    [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Valheim World Share", "OK", "Error") | Out-Null
}
