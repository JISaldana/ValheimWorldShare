[CmdletBinding()]
param(
    [switch]$NoGui,
    [string]$Remote = "gdrive:",
    [string]$WorldName = "Dedicated",
    [string]$ServerExecutable = "$env:ProgramFiles(x86)\Steam\steamapps\common\Valheim dedicated server\valheim_server.exe",
    [string]$WorldDirectory = "$env:USERPROFILE\AppData\LocalLow\IronGate\Valheim\worlds_local",
    [string]$RclonePath = "$PSScriptRoot\.tools\rclone.exe",
    [int]$NetworkTimeoutSeconds = 60,
    [string]$SessionLogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:LockName = "server.lock"
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
    Write-LauncherLog "rclone no está instalado; descargando la versión portable."
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

function Invoke-Rclone {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $output = & $Executable @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "rclone falló ($LASTEXITCODE): $($output -join [Environment]::NewLine)"
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
            throw "Respuesta inválida de rclone para $remoteFile."
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
        throw "El servidor está siendo hosteado por $lockOwner. Espera a que termine."
    }

    Sync-WorldFromRemote -Executable $rclone
    New-RemoteLock -Executable $rclone
    $serverProcess = $null
    try {
        if (-not (Test-Path -LiteralPath $ServerExecutable -PathType Leaf)) {
            throw "No se encontró el ejecutable del servidor: $ServerExecutable"
        }
        Write-LauncherLog "Iniciando Valheim para el mundo $WorldName."
        $serverProcess = Start-Process -FilePath $ServerExecutable -ArgumentList @(
            "-nographics", "-batchmode", "-world", $WorldName
        ) -PassThru
        Wait-Process -Id $serverProcess.Id
        Write-LauncherLog "El proceso de Valheim terminó; subiendo cambios."
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
    $form.Size = New-Object Drawing.Size(620, 430)
    $form.StartPosition = "CenterScreen"

    $status = New-Object Windows.Forms.Label
    $status.Text = "Servidor disponible. Haz clic para iniciar."
    $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
    $status.Dock = "Top"
    $status.Height = 48
    $status.TextAlign = "MiddleCenter"
    $status.Font = New-Object Drawing.Font("Segoe UI", 11, [Drawing.FontStyle]::Bold)

    $start = New-Object Windows.Forms.Button
    $start.Text = "Iniciar servidor"
    $start.Dock = "Top"
    $start.Height = 42
    $release = New-Object Windows.Forms.Button
    $release.Text = "Liberación manual (riesgo de colisión)"
    $release.Dock = "Top"
    $release.Height = 35
    $log = New-Object Windows.Forms.TextBox
    $log.Multiline = $true
    $log.ReadOnly = $true
    $log.ScrollBars = "Vertical"
    $log.Dock = "Fill"
    $log.Font = New-Object Drawing.Font("Consolas", 9)
    $form.Controls.Add($log)
    $form.Controls.Add($release)
    $form.Controls.Add($start)
    $form.Controls.Add($status)

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        if (Test-Path -LiteralPath $script:ChildLogPath) {
            $log.Text = Get-Content -LiteralPath $script:ChildLogPath -Raw
            $log.SelectionStart = $log.Text.Length
            $log.ScrollToCaret()
        }
    })
    $start.Add_Click({
        $start.Enabled = $false
        $release.Enabled = $false
        $status.Text = "Sincronizando partida... No cierres la ventana."
        $status.BackColor = [Drawing.Color]::FromArgb(59, 130, 246)
        $script:ChildLogPath = Join-Path $PSScriptRoot "logs\session-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss')).log"
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -NoGui -Remote `"$Remote`" -WorldName `"$WorldName`" -ServerExecutable `"$ServerExecutable`" -WorldDirectory `"$WorldDirectory`" -RclonePath `"$RclonePath`" -SessionLogPath `"$script:ChildLogPath`""
        Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden | Out-Null
        $timer.Start()
    })
    $release.Add_Click({
        if ([Windows.Forms.MessageBox]::Show("Solo libera el bloqueo si confirmaste que nadie está jugando. ¿Continuar?", "Advertencia", "YesNo", "Warning") -eq "Yes") {
            try {
                Remove-RemoteLock -Executable (Get-RclonePath)
                $status.Text = "Servidor disponible. Bloqueo liberado."
                $status.BackColor = [Drawing.Color]::FromArgb(34, 197, 94)
            } catch {
                [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error", "OK", "Error") | Out-Null
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
