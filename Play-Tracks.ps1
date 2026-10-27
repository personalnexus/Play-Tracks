#requires -Version 5.1

# Place NAudio 1.10.0's lib\net35\NAudio.dll next to this script.
# Run with Windows PowerShell, for example: powershell.exe -STA -File .\Play-Tracks.ps1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$naudioPath = Join-Path $PSScriptRoot 'NAudio.dll'
if (-not (Test-Path -LiteralPath $naudioPath -PathType Leaf)) {
    [System.Windows.Forms.MessageBox]::Show(
        "NAudio.dll is required. Download NAudio 1.10.0 from NuGet, extract the package, and copy lib\net35\NAudio.dll next to this script.",
        'Missing dependency',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

try {
    Add-Type -Path $naudioPath -ErrorAction Stop
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Could not load NAudio.dll:`r`n$($_.Exception.Message)",
        'Audio initialization error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

$script:tracksPath = Join-Path $PSScriptRoot 'Tracks'
$script:trackPanel = $null
$script:devicePanel = $null
$script:settingsPanel = $null
$script:audioDevices = @()
$script:deviceMasterVolumes = @()
$script:defaultDeviceRadios = @()
$script:defaultDeviceIndex = -1
$script:playbacks = @{}
$script:trackVolumes = @{}
$script:trackFades = @{}
$script:trackDeviceSelections = @{}
$script:initialDeviceVolumes = @()
$script:trackStatusLabels = @{}
$script:deviceMasterSliders = @()
$script:lastTrackPaths = @()

if (-not (Test-Path -LiteralPath $script:tracksPath -PathType Container)) {
    New-Item -ItemType Directory -Path $script:tracksPath -ErrorAction Stop | Out-Null
}

function Stop-TrackPlayback {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($script:playbacks.ContainsKey($Path)) {
        $playback = $script:playbacks[$Path]
        $script:playbacks.Remove($Path)
        try {
            $playback.Output.Stop()
        }
        finally {
            $playback.Output.Dispose()
            $playback.VolumeProvider.Dispose()
            if ($script:trackStatusLabels.ContainsKey($Path)) {
                $script:trackStatusLabels[$Path].Text = ''
            }
        }
    }
}

function Update-TrackPlaybackVolume {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Playback
    )

    $elapsedMs = ([DateTime]::UtcNow - $Playback.StartedAt).TotalMilliseconds
    $fadeFactor = 1.0
    if ($Playback.FadeInMs -gt 0) {
        $fadeFactor *= [Math]::Min(1.0, [Math]::Max(0.0, $elapsedMs / $Playback.FadeInMs))
    }

    $remainingMs = ($Playback.Duration - [TimeSpan]::FromMilliseconds($elapsedMs)).TotalMilliseconds
    if ($Playback.FadeOutMs -gt 0 -and $remainingMs -le $Playback.FadeOutMs) {
        $fadeFactor *= [Math]::Min(1.0, [Math]::Max(0.0, $remainingMs / $Playback.FadeOutMs))
    }

    $trackVolume = $script:trackVolumes[$Path] / 100.0
    $Playback.VolumeProvider.Volume = [single]($trackVolume * $fadeFactor)
}

function Start-TrackPlayback {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$DeviceIndex,
        [Parameter(Mandatory = $true)][int]$Volume,
        [Parameter(Mandatory = $true)][int]$FadeInMs,
        [Parameter(Mandatory = $true)][int]$FadeOutMs
    )

    if ($DeviceIndex -lt 0 -or $DeviceIndex -ge $script:audioDevices.Count) {
        [System.Windows.Forms.MessageBox]::Show(
            'No active audio device is selected.',
            'Cannot play track',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    Stop-TrackPlayback -Path $Path
    $reader = $null
    $volumeProvider = $null
    $output = $null
    try {
        $reader = New-Object NAudio.Wave.MediaFoundationReader -ArgumentList $Path
        $volumeProvider = New-Object NAudio.Wave.WaveChannel32 -ArgumentList $reader
        $volumeProvider.Volume = [single]($Volume / 100.0)
        $device = $script:audioDevices[$DeviceIndex]
        $output = [NAudio.Wave.WasapiOut]::new(
            $device,
            [NAudio.CoreAudioApi.AudioClientShareMode]::Shared,
            $true,
            100
        )
        $output.Volume = [single]($script:deviceMasterVolumes[$DeviceIndex] / 100.0)
        $output.Init($volumeProvider)
        $output.Play()
        $script:playbacks[$Path] = @{
            VolumeProvider = $volumeProvider
            Output = $output
            DeviceIndex = $DeviceIndex
            StartedAt = [DateTime]::UtcNow
            Duration = $reader.TotalTime
            FadeInMs = $FadeInMs
            FadeOutMs = $FadeOutMs
        }
        Update-TrackPlaybackVolume -Path $Path -Playback $script:playbacks[$Path]
        if ($script:trackStatusLabels.ContainsKey($Path)) {
            $script:trackStatusLabels[$Path].Text = 'Playing...'
        }
    }
    catch {
        if ($output) {
            $output.Dispose()
        }
        if ($volumeProvider) {
            $volumeProvider.Dispose()
        } elseif ($reader) {
            $reader.Dispose()
        }
        [System.Windows.Forms.MessageBox]::Show(
            "Could not play '$([System.IO.Path]::GetFileName($Path))':`r`n$($_.Exception.Message)",
            'Playback error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Get-TrackFiles {
    @(Get-ChildItem -LiteralPath $script:tracksPath -File -Filter '*.mp3' -ErrorAction Stop |
        Sort-Object -Property @{ Expression = { $_.Name }; Ascending = $true })
}

function Get-TrackSettingsSnapshot {
    $trackSettings = @(
        foreach ($row in $script:trackPanel.Controls) {
            $track = $row.Tag
            $deviceSelection = $track.DevicePicker.SelectedIndex
            $deviceId = $null
            if ($deviceSelection -gt 0) {
                $deviceId = $script:audioDevices[$deviceSelection - 1].ID
            }

            [pscustomobject]@{
                FileName = [System.IO.Path]::GetFileName($track.Path)
                Sha256 = (Get-FileHash -LiteralPath $track.Path -Algorithm SHA256 -ErrorAction Stop).Hash
                DeviceId = $deviceId
                Volume = $track.VolumeSlider.Value
                FadeInMs = [int]$track.FadeInInput.Value
                FadeOutMs = [int]$track.FadeOutInput.Value
            }
        }
    )

    $deviceVolumes = @(
        for ($index = 0; $index -lt $script:audioDevices.Count; $index++) {
            [pscustomobject]@{
                DeviceId = $script:audioDevices[$index].ID
                Volume = $script:deviceMasterSliders[$index].Value
            }
        }
    )

    $defaultDeviceId = $null
    if ($script:defaultDeviceIndex -ge 0 -and $script:defaultDeviceIndex -lt $script:audioDevices.Count) {
        $defaultDeviceId = $script:audioDevices[$script:defaultDeviceIndex].ID
    }

    [pscustomobject]@{
        Version = 1
        DefaultDeviceId = $defaultDeviceId
        DeviceVolumes = $deviceVolumes
        Tracks = $trackSettings
    }
}

function Apply-TrackSettings {
    param([Parameter(Mandatory = $true)][object]$Settings)

    if ($Settings.Version -ne 1 -or $null -eq $Settings.Tracks) {
        throw 'The settings file has an unsupported version or is missing its track list.'
    }

    $currentFiles = @(Get-TrackFiles)
    $fileHashes = @{}
    foreach ($file in $currentFiles) {
        $fileHashes[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
    }

    $deviceIndexes = @{}
    for ($index = 0; $index -lt $script:audioDevices.Count; $index++) {
        $deviceIndexes[$script:audioDevices[$index].ID] = $index
    }

    if ($Settings.DefaultDeviceId -and $deviceIndexes.ContainsKey([string]$Settings.DefaultDeviceId)) {
        $script:defaultDeviceRadios[$deviceIndexes[[string]$Settings.DefaultDeviceId]].Checked = $true
    }

    foreach ($savedDevice in @($Settings.DeviceVolumes)) {
        $deviceId = [string]$savedDevice.DeviceId
        if ($deviceIndexes.ContainsKey($deviceId)) {
            $volume = [int]$savedDevice.Volume
            if ($volume -ge 0 -and $volume -le 100) {
                $script:deviceMasterSliders[$deviceIndexes[$deviceId]].Value = $volume
            }
        }
    }

    foreach ($savedTrack in @($Settings.Tracks)) {
        $matches = @($currentFiles | Where-Object {
            [string]::Equals($fileHashes[$_.FullName], [string]$savedTrack.Sha256, [System.StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -gt 1) {
            $namedMatch = @($matches | Where-Object {
                [string]::Equals($_.Name, [string]$savedTrack.FileName, [System.StringComparison]::OrdinalIgnoreCase)
            })
            if ($namedMatch.Count -gt 0) {
                $matches = $namedMatch
            }
        }
        if ($matches.Count -eq 0) {
            $matches = @($currentFiles | Where-Object {
                [string]::Equals($_.Name, [string]$savedTrack.FileName, [System.StringComparison]::OrdinalIgnoreCase)
            })
        }
        if ($matches.Count -eq 0) {
            continue
        }

        $path = $matches[0].FullName
        $row = @($script:trackPanel.Controls | Where-Object { $_.Tag.Path -eq $path }) | Select-Object -First 1
        if (-not $row) {
            continue
        }
        $track = $row.Tag

        $volume = [int]$savedTrack.Volume
        if ($volume -ge 0 -and $volume -le 100) {
            $track.VolumeSlider.Value = $volume
        }
        $fadeInMs = [int]$savedTrack.FadeInMs
        if ($fadeInMs -ge 0 -and $fadeInMs -le 3600000) {
            $track.FadeInInput.Value = $fadeInMs
        }
        $fadeOutMs = [int]$savedTrack.FadeOutMs
        if ($fadeOutMs -ge 0 -and $fadeOutMs -le 3600000) {
            $track.FadeOutInput.Value = $fadeOutMs
        }

        if ($savedTrack.DeviceId -and $deviceIndexes.ContainsKey([string]$savedTrack.DeviceId)) {
            $track.DevicePicker.SelectedIndex = $deviceIndexes[[string]$savedTrack.DeviceId] + 1
        } else {
            $track.DevicePicker.SelectedIndex = 0
        }
        $script:trackDeviceSelections[$path] = $track.DevicePicker.SelectedIndex
    }
}

function Reset-TrackSettings {
    foreach ($row in $script:trackPanel.Controls) {
        $track = $row.Tag
        $track.VolumeSlider.Value = 50
        $track.FadeInInput.Value = 0
        $track.FadeOutInput.Value = 0
        $track.DevicePicker.SelectedIndex = 0
    }

    foreach ($slider in $script:deviceMasterSliders) {
        $index = [int]$slider.Tag
        $slider.Value = $script:initialDeviceVolumes[$index]
    }

    if ($script:defaultDeviceRadios.Count -gt 0) {
        $script:defaultDeviceRadios[0].Checked = $true
    }
}

function Update-TrackButtons {
    $files = Get-TrackFiles
    $paths = @($files | ForEach-Object { $_.FullName })

    $unchanged = $paths.Count -eq $script:lastTrackPaths.Count
    if ($unchanged) {
        for ($index = 0; $index -lt $paths.Count; $index++) {
            if (-not [string]::Equals(
                $paths[$index],
                $script:lastTrackPaths[$index],
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                $unchanged = $false
                break
            }
        }
    }
    if ($unchanged) {
        return
    }

    $script:lastTrackPaths = $paths
    $script:trackStatusLabels = @{}
    $script:trackPanel.SuspendLayout()
    try {
        foreach ($oldRow in @($script:trackPanel.Controls)) {
            $oldRow.Dispose()
        }
        $script:trackPanel.Controls.Clear()
        foreach ($file in $files) {
            $row = New-Object System.Windows.Forms.TableLayoutPanel
            $row.Height = 72
            $row.ColumnCount = 8
            $row.RowCount = 2
            $row.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 8)
            $row.Padding = New-Object System.Windows.Forms.Padding(3)
            $row.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                30
            )))
            $row.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                34
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Percent,
                100
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                84
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                150
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                130
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                125
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                125
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                60
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                60
            )))

            $nameLabel = New-Object System.Windows.Forms.Label
            $nameLabel.Text = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $nameLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $nameLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
            $nameLabel.AutoEllipsis = $true
            $nameLabel.Font = New-Object System.Drawing.Font(
                $nameLabel.Font,
                [System.Drawing.FontStyle]::Bold
            )
            $nameLabel.Margin = New-Object System.Windows.Forms.Padding(3)

            $statusLabel = New-Object System.Windows.Forms.Label
            $statusLabel.Text = ''
            $statusLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
            $statusLabel.Margin = New-Object System.Windows.Forms.Padding(3)
            if ($script:playbacks.ContainsKey($file.FullName)) {
                $statusLabel.Text = 'Playing...'
            }
            $script:trackStatusLabels[$file.FullName] = $statusLabel

            $trackDevicePicker = New-Object System.Windows.Forms.ComboBox
            $trackDevicePicker.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
            $trackDevicePicker.Dock = [System.Windows.Forms.DockStyle]::Fill
            $trackDevicePicker.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
            $trackDevicePicker.Tag = $file.FullName
            [void]$trackDevicePicker.Items.Add('Default')
            foreach ($device in $script:audioDevices) {
                [void]$trackDevicePicker.Items.Add($device.FriendlyName)
            }
            $selectedTrackDevice = 0
            if ($script:trackDeviceSelections.ContainsKey($file.FullName)) {
                $selectedTrackDevice = $script:trackDeviceSelections[$file.FullName]
            }
            if ($selectedTrackDevice -lt 0 -or $selectedTrackDevice -ge $trackDevicePicker.Items.Count) {
                $selectedTrackDevice = 0
            }
            $trackDevicePicker.SelectedIndex = $selectedTrackDevice
            $trackDevicePicker.Add_SelectedIndexChanged({
                $script:trackDeviceSelections[$this.Tag] = $this.SelectedIndex
            })

            $trackDeviceLabel = New-Object System.Windows.Forms.Label
            $trackDeviceLabel.Text = 'Playback Device'
            $trackDeviceLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $trackDeviceLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
            $trackDeviceLabel.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)

            $volumeSlider = New-Object System.Windows.Forms.TrackBar
            $volumeSlider.Minimum = 0
            $volumeSlider.Maximum = 100
            if ($script:trackVolumes.ContainsKey($file.FullName)) {
                $volumeSlider.Value = $script:trackVolumes[$file.FullName]
            } else {
                $volumeSlider.Value = 50
                $script:trackVolumes[$file.FullName] = 50
            }
            $volumeSlider.TickStyle = [System.Windows.Forms.TickStyle]::None
            $volumeSlider.Dock = [System.Windows.Forms.DockStyle]::Fill
            $volumeSlider.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)
            $volumeSlider.Tag = $file.FullName
            $volumeSlider.Add_ValueChanged({
                $path = $this.Tag
                $script:trackVolumes[$path] = $this.Value
                if ($script:playbacks.ContainsKey($path)) {
                    Update-TrackPlaybackVolume -Path $path -Playback $script:playbacks[$path]
                }
            })

            $volumeLabel = New-Object System.Windows.Forms.Label
            $volumeLabel.Text = 'Volume'
            $volumeLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $volumeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
            $volumeLabel.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)

            $resetVolumeLabel = New-Object System.Windows.Forms.LinkLabel
            $resetVolumeLabel.Text = 'Reset'
            $resetVolumeLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $resetVolumeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
            $resetVolumeLabel.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)
            $resetVolumeLabel.Tag = $volumeSlider
            $resetVolumeLabel.Add_LinkClicked({
                $this.Tag.Value = 50
            })

            if (-not $script:trackFades.ContainsKey($file.FullName)) {
                $script:trackFades[$file.FullName] = @{ FadeInMs = 0; FadeOutMs = 0 }
            }

            $fadeInLabel = New-Object System.Windows.Forms.Label
            $fadeInLabel.Text = 'Fade-in (ms)'
            $fadeInLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $fadeInLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
            $fadeInLabel.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)
            $fadeInInput = New-Object System.Windows.Forms.NumericUpDown
            $fadeInInput.Minimum = 0
            $fadeInInput.Maximum = 3600000
            $fadeInInput.Increment = 100
            $fadeInInput.DecimalPlaces = 0
            $fadeInInput.ThousandsSeparator = $true
            $fadeInInput.Value = $script:trackFades[$file.FullName].FadeInMs
            $fadeInInput.Dock = [System.Windows.Forms.DockStyle]::Fill
            $fadeInInput.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
            $fadeInInput.Tag = $file.FullName
            $fadeInInput.Add_ValueChanged({
                $script:trackFades[$this.Tag].FadeInMs = [int]$this.Value
                if ($script:playbacks.ContainsKey($this.Tag)) {
                    $script:playbacks[$this.Tag].FadeInMs = [int]$this.Value
                    Update-TrackPlaybackVolume -Path $this.Tag -Playback $script:playbacks[$this.Tag]
                }
            })
            $fadeOutLabel = New-Object System.Windows.Forms.Label
            $fadeOutLabel.Text = 'Fade-out (ms)'
            $fadeOutLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $fadeOutLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
            $fadeOutLabel.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)
            $fadeOutInput = New-Object System.Windows.Forms.NumericUpDown
            $fadeOutInput.Minimum = 0
            $fadeOutInput.Maximum = 3600000
            $fadeOutInput.Increment = 100
            $fadeOutInput.DecimalPlaces = 0
            $fadeOutInput.ThousandsSeparator = $true
            $fadeOutInput.Value = $script:trackFades[$file.FullName].FadeOutMs
            $fadeOutInput.Dock = [System.Windows.Forms.DockStyle]::Fill
            $fadeOutInput.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
            $fadeOutInput.Tag = $file.FullName
            $fadeOutInput.Add_ValueChanged({
                $script:trackFades[$this.Tag].FadeOutMs = [int]$this.Value
                if ($script:playbacks.ContainsKey($this.Tag)) {
                    $script:playbacks[$this.Tag].FadeOutMs = [int]$this.Value
                    Update-TrackPlaybackVolume -Path $this.Tag -Playback $script:playbacks[$this.Tag]
                }
            })
            $playButton = New-Object System.Windows.Forms.Button
            $playButton.Text = 'Play'
            $playButton.Dock = [System.Windows.Forms.DockStyle]::Fill
            $playButton.Tag = @{
                Path = $file.FullName
                DevicePicker = $trackDevicePicker
                VolumeSlider = $volumeSlider
                FadeInInput = $fadeInInput
                FadeOutInput = $fadeOutInput
            }
            $playButton.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 4)
            $playButton.Add_Click({
                $selectedIndex = $this.Tag.DevicePicker.SelectedIndex
                if ($selectedIndex -eq 0) {
                    $deviceIndex = $script:defaultDeviceIndex
                } else {
                    $deviceIndex = $selectedIndex - 1
                }
                Start-TrackPlayback `
                    -Path $this.Tag.Path `
                    -DeviceIndex $deviceIndex `
                    -Volume $this.Tag.VolumeSlider.Value `
                    -FadeInMs $this.Tag.FadeInInput.Value `
                    -FadeOutMs $this.Tag.FadeOutInput.Value
            })

            $stopButton = New-Object System.Windows.Forms.Button
            $stopButton.Text = 'Stop'
            $stopButton.Dock = [System.Windows.Forms.DockStyle]::Fill
            $stopButton.Tag = $file.FullName
            $stopButton.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 4)
            $stopButton.Add_Click({
                Stop-TrackPlayback -Path $this.Tag
            })

            $row.SetRowSpan($nameLabel, 2)
            $row.SetRowSpan($statusLabel, 2)
            $row.SetRowSpan($playButton, 2)
            $row.SetRowSpan($stopButton, 2)
            $row.Controls.Add($nameLabel, 0, 0)
            $row.Controls.Add($statusLabel, 1, 0)
            $row.Controls.Add($trackDeviceLabel, 2, 0)
            $row.Controls.Add($trackDevicePicker, 2, 1)
            $volumeHeader = New-Object System.Windows.Forms.TableLayoutPanel
            $volumeHeader.Dock = [System.Windows.Forms.DockStyle]::Fill
            $volumeHeader.ColumnCount = 2
            $volumeHeader.RowCount = 1
            $volumeHeader.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Percent,
                100
            )))
            $volumeHeader.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                48
            )))
            $volumeHeader.Controls.Add($volumeLabel, 0, 0)
            $volumeHeader.Controls.Add($resetVolumeLabel, 1, 0)
            $row.Controls.Add($volumeHeader, 3, 0)
            $row.Controls.Add($volumeSlider, 3, 1)
            $row.Controls.Add($fadeInLabel, 4, 0)
            $row.Controls.Add($fadeInInput, 4, 1)
            $row.Controls.Add($fadeOutLabel, 5, 0)
            $row.Controls.Add($fadeOutInput, 5, 1)
            $row.Controls.Add($playButton, 6, 0)
            $row.Controls.Add($stopButton, 7, 0)
            $row.Tag = @{
                Path = $file.FullName
                DevicePicker = $trackDevicePicker
                VolumeSlider = $volumeSlider
                FadeInInput = $fadeInInput
                FadeOutInput = $fadeOutInput
            }
            $script:trackPanel.Controls.Add($row)
        }
        Resize-TrackRows
    }
    finally {
        $script:trackPanel.ResumeLayout()
    }
}

function Resize-TrackRows {
    $rowWidth = [Math]::Max(200, $script:trackPanel.ClientSize.Width - 24)
    foreach ($row in $script:trackPanel.Controls) {
        $row.Width = $rowWidth
    }
}

function Resize-DeviceRows {
    $rowWidth = [Math]::Max(300, $script:devicePanel.ClientSize.Width - 24)
    foreach ($row in $script:devicePanel.Controls) {
        if ($row -is [System.Windows.Forms.TableLayoutPanel]) {
            $row.Width = $rowWidth
        }
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Track Player'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.ClientSize = New-Object System.Drawing.Size(1100, 700)
$form.MinimumSize = New-Object System.Drawing.Size(950, 400)

$script:devicePanel = New-Object System.Windows.Forms.FlowLayoutPanel
$script:devicePanel.Dock = [System.Windows.Forms.DockStyle]::Top
$script:devicePanel.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$script:devicePanel.WrapContents = $false
$script:devicePanel.AutoScroll = $true
$script:devicePanel.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)

$deviceDivider = New-Object System.Windows.Forms.Panel
$deviceDivider.Dock = [System.Windows.Forms.DockStyle]::Top
$deviceDivider.Height = 1
$deviceDivider.BackColor = [System.Drawing.SystemColors]::ControlDark

$tracksDivider = New-Object System.Windows.Forms.Panel
$tracksDivider.Dock = [System.Windows.Forms.DockStyle]::Bottom
$tracksDivider.Height = 1
$tracksDivider.BackColor = [System.Drawing.SystemColors]::ControlDark

$script:settingsPanel = New-Object System.Windows.Forms.TableLayoutPanel
$script:settingsPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
$script:settingsPanel.Height = 48
$script:settingsPanel.ColumnCount = 3
$script:settingsPanel.RowCount = 1
$script:settingsPanel.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
$script:settingsPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
    [System.Windows.Forms.SizeType]::Percent,
    100
)))
$script:settingsPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
    [System.Windows.Forms.SizeType]::Absolute,
    150
)))
$script:settingsPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
    [System.Windows.Forms.SizeType]::Absolute,
    150
)))

$resetSettingsButton = New-Object System.Windows.Forms.Button
$resetSettingsButton.Text = 'Reset to Defaults'
$resetSettingsButton.Dock = [System.Windows.Forms.DockStyle]::Left
$resetSettingsButton.AutoSize = $true
$resetSettingsButton.Margin = New-Object System.Windows.Forms.Padding(3)
$resetSettingsButton.Add_Click({ Reset-TrackSettings })
$saveSettingsButton = New-Object System.Windows.Forms.Button
$saveSettingsButton.Text = 'Save Settings...'
$saveSettingsButton.Dock = [System.Windows.Forms.DockStyle]::Fill
$saveSettingsButton.Margin = New-Object System.Windows.Forms.Padding(3)
$loadSettingsButton = New-Object System.Windows.Forms.Button
$loadSettingsButton.Text = 'Load Settings...'
$loadSettingsButton.Dock = [System.Windows.Forms.DockStyle]::Fill
$loadSettingsButton.Margin = New-Object System.Windows.Forms.Padding(3)
$script:settingsPanel.Controls.Add($resetSettingsButton, 0, 0)
$script:settingsPanel.Controls.Add($saveSettingsButton, 1, 0)
$script:settingsPanel.Controls.Add($loadSettingsButton, 2, 0)

$script:trackPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$script:trackPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:trackPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$script:trackPanel.WrapContents = $false
$script:trackPanel.AutoScroll = $true
$script:trackPanel.Padding = New-Object System.Windows.Forms.Padding(6)

$form.Controls.Add($script:trackPanel)
$form.Controls.Add($tracksDivider)
$form.Controls.Add($script:settingsPanel)
$form.Controls.Add($deviceDivider)
$form.Controls.Add($script:devicePanel)

try {
    $enumerator = New-Object NAudio.CoreAudioApi.MMDeviceEnumerator
    $script:audioDevices = @(
        $enumerator.EnumerateAudioEndPoints(
            [NAudio.CoreAudioApi.DataFlow]::Render,
            [NAudio.CoreAudioApi.DeviceState]::Active
        )
    )

    $script:defaultDeviceRadios = @()
    $script:deviceMasterSliders = @()
    $script:initialDeviceVolumes = @()
    $script:deviceMasterVolumes = @(for ($index = 0; $index -lt $script:audioDevices.Count; $index++) { 100 })
    for ($index = 0; $index -lt $script:audioDevices.Count; $index++) {
        $device = $script:audioDevices[$index]
        $deviceRow = New-Object System.Windows.Forms.TableLayoutPanel
        $deviceRow.Height = 48
        $deviceRow.ColumnCount = 2
        $deviceRow.RowCount = 1
        $deviceRow.Margin = New-Object System.Windows.Forms.Padding(2)
        $deviceRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
            [System.Windows.Forms.SizeType]::Percent,
            100
        )))
        $deviceRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
            [System.Windows.Forms.SizeType]::Absolute,
            220
        )))

        $radio = New-Object System.Windows.Forms.RadioButton
        $radio.Text = $device.FriendlyName
        $radio.Tag = $index
        $radio.Dock = [System.Windows.Forms.DockStyle]::Fill
        $radio.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $radio.Margin = New-Object System.Windows.Forms.Padding(4)
        if ($index -eq 0) {
            $radio.Checked = $true
            $script:defaultDeviceIndex = 0
        }
        $radio.Add_CheckedChanged({
            if ($this.Checked) {
                $selectedDeviceIndex = [int]$this.Tag
                $script:defaultDeviceIndex = $selectedDeviceIndex
                foreach ($otherRadio in $script:defaultDeviceRadios) {
                    if ($otherRadio -ne $this) {
                        $otherRadio.Checked = $false
                    }
                }
            }
        })
        $script:defaultDeviceRadios += $radio

        $masterSlider = New-Object System.Windows.Forms.TrackBar
        $masterSlider.Minimum = 0
        $masterSlider.Maximum = 100
        $masterSlider.Value = [int][Math]::Round(
            $device.AudioEndpointVolume.MasterVolumeLevelScalar * 100
        )
        $masterSlider.TickStyle = [System.Windows.Forms.TickStyle]::None
        $masterSlider.Dock = [System.Windows.Forms.DockStyle]::Fill
        $masterSlider.Margin = New-Object System.Windows.Forms.Padding(3)
        $masterSlider.Tag = $index
        $masterSlider.Add_ValueChanged({
            $deviceIndex = [int]$this.Tag
            $script:deviceMasterVolumes[$deviceIndex] = $this.Value
            foreach ($path in @($script:playbacks.Keys)) {
                $playback = $script:playbacks[$path]
                if ($playback.DeviceIndex -eq $deviceIndex) {
                    $playback.Output.Volume = [single]($this.Value / 100.0)
                }
            }
        })
        $script:deviceMasterVolumes[$index] = $masterSlider.Value
        $script:initialDeviceVolumes += $masterSlider.Value
        $script:deviceMasterSliders += $masterSlider
        $deviceRow.Controls.Add($radio, 0, 0)
        $deviceRow.Controls.Add($masterSlider, 1, 0)
        $script:devicePanel.Controls.Add($deviceRow)
    }

    if ($script:audioDevices.Count -eq 0) {
        $noDeviceLabel = New-Object System.Windows.Forms.Label
        $noDeviceLabel.Text = 'No active audio devices'
        $noDeviceLabel.AutoSize = $true
        $script:devicePanel.Controls.Add($noDeviceLabel)
    }
    $script:devicePanel.Height = [Math]::Min(250, [Math]::Max(56, ($script:audioDevices.Count * 52) + 8))
    Resize-DeviceRows
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Could not enumerate audio devices:`r`n$($_.Exception.Message)",
        'Audio initialization error',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    $form.Dispose()
    exit 1
}

$saveSettingsButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = 'Save track player settings'
    $dialog.Filter = 'JSON settings (*.json)|*.json|All files (*.*)|*.*'
    $dialog.DefaultExt = 'json'
    $dialog.AddExtension = $true
    $dialog.FileName = 'TrackPlayerSettings.json'
    try {
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $settings = Get-TrackSettingsSnapshot
            $json = ConvertTo-Json -InputObject $settings -Depth 6
            Set-Content -LiteralPath $dialog.FileName -Value $json -Encoding UTF8 -ErrorAction Stop
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not save settings:`r`n$($_.Exception.Message)",
            'Settings save error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        $dialog.Dispose()
    }
})

$loadSettingsButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Load track player settings'
    $dialog.Filter = 'JSON settings (*.json)|*.json|All files (*.*)|*.*'
    $dialog.CheckFileExists = $true
    try {
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $json = Get-Content -LiteralPath $dialog.FileName -Raw -ErrorAction Stop
            $settings = ConvertFrom-Json -InputObject $json -ErrorAction Stop
            Update-TrackButtons
            Apply-TrackSettings -Settings $settings
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not load settings:`r`n$($_.Exception.Message)",
            'Settings load error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        $dialog.Dispose()
    }
})

$refreshTimer = New-Object System.Windows.Forms.Timer
$refreshTimer.Interval = 1000
$refreshTimer.Add_Tick({
    try {
        Update-TrackButtons

        foreach ($path in @($script:playbacks.Keys)) {
            if ($script:playbacks[$path].Output.PlaybackState -eq [NAudio.Wave.PlaybackState]::Stopped) {
                Stop-TrackPlayback -Path $path
            }
        }
    }
    catch {
        $refreshTimer.Stop()
        [System.Windows.Forms.MessageBox]::Show(
            "Could not refresh the track list:`r`n$($_.Exception.Message)",
            'Track list error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$fadeTimer = New-Object System.Windows.Forms.Timer
$fadeTimer.Interval = 50
$fadeTimer.Add_Tick({
    try {
        foreach ($path in @($script:playbacks.Keys)) {
            Update-TrackPlaybackVolume -Path $path -Playback $script:playbacks[$path]
        }
    }
    catch {
        $fadeTimer.Stop()
        [System.Windows.Forms.MessageBox]::Show(
            "Could not update playback fades:`r`n$($_.Exception.Message)",
            'Playback fade error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$script:trackPanel.Add_Resize({ Resize-TrackRows })
$script:devicePanel.Add_Resize({ Resize-DeviceRows })
$form.Add_Shown({
    Update-TrackButtons
    $defaultSettingsPath = Join-Path $PSScriptRoot 'Play-Tracks.DefaultSettings.json'
    if (Test-Path -LiteralPath $defaultSettingsPath -PathType Leaf) {
        try {
            $json = Get-Content -LiteralPath $defaultSettingsPath -Raw -ErrorAction Stop
            $settings = ConvertFrom-Json -InputObject $json -ErrorAction Stop
            Apply-TrackSettings -Settings $settings
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not load default settings from '$defaultSettingsPath':`r`n$($_.Exception.Message)",
                'Default settings error',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    }
    Resize-TrackRows
    Resize-DeviceRows
    $refreshTimer.Start()
    $fadeTimer.Start()
})
$form.Add_FormClosed({
    $refreshTimer.Stop()
    $refreshTimer.Dispose()
    $fadeTimer.Stop()
    $fadeTimer.Dispose()
    foreach ($path in @($script:playbacks.Keys)) {
        Stop-TrackPlayback -Path $path
    }
    foreach ($device in $script:audioDevices) {
        $device.Dispose()
    }
})

[void]$form.ShowDialog()
