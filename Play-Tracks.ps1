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
$script:mainForm = $null
$script:audioDevices = @()
$script:deviceMasterVolumes = @()
$script:defaultDeviceRadios = @()
$script:defaultDeviceIndex = -1
$script:playbacks = @{}
$script:trackPlayButtons = @{}
$script:trackOffsetNowLinks = @{}
$script:trackVolumes = @{}
$script:trackFades = @{}
$script:trackOffsets = @{}
$script:trackDeviceSelections = @{}
$script:initialDeviceVolumes = @()
$script:trackProgressSliders = @{}
$script:trackProgressMarkerPanels = @{}
$script:trackTimeLabels = @{}
$script:trackDurations = @{}
$script:deviceMasterSliders = @()
$script:lastTrackPaths = @()
$script:lastSettingsPath = $null

if (-not (Test-Path -LiteralPath $script:tracksPath -PathType Container)) {
    New-Item -ItemType Directory -Path $script:tracksPath -ErrorAction Stop | Out-Null
}

function Stop-TrackPlayback {
    param([Parameter(Mandatory = $true)][string]$Path)

    $duration = $null
    if ($script:playbacks.ContainsKey($Path)) {
        $playback = $script:playbacks[$Path]
        $duration = $playback.Duration
        $script:playbacks.Remove($Path)
        try {
            $playback.Output.Stop()
        }
        finally {
            try {
                $playback.Output.Dispose()
            }
            finally {
                try {
                    $playback.VolumeProvider.Dispose()
                }
                finally {
                    Set-TrackPlaybackButtonState -Path $Path -IsPlaying $false
                    Set-TrackOffsetNowLinksState -Path $Path -Enabled $false
                    Reset-TrackPlaybackProgress -Path $Path -Duration $duration
                }
            }
        }
    } else {
        Set-TrackPlaybackButtonState -Path $Path -IsPlaying $false
        Set-TrackOffsetNowLinksState -Path $Path -Enabled $false
        if ($script:trackProgressSliders.ContainsKey($Path)) {
            $slider = $script:trackProgressSliders[$Path]
            if (-not $slider.IsDisposed) {
                $duration = [TimeSpan]::FromMilliseconds($slider.Maximum)
            }
        }
        Reset-TrackPlaybackProgress -Path $Path -Duration $duration
    }
}

function Reset-TrackPlaybackProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$Duration = $null
    )

    if ($script:trackProgressSliders.ContainsKey($Path)) {
        $slider = $script:trackProgressSliders[$Path]
        if (-not $slider.IsDisposed) {
            $slider.Enabled = $false
            $slider.Minimum = 0
            if ($null -ne $Duration -and ([TimeSpan]$Duration).TotalMilliseconds -le [int]::MaxValue) {
                $durationMs = [int]([TimeSpan]$Duration).TotalMilliseconds
            } else {
                $durationMs = [Math]::Max(1, $slider.Maximum)
            }
            $slider.Maximum = [Math]::Max(1, $durationMs)
            $slider.Value = 0
        }
    }
    if ($script:trackTimeLabels.ContainsKey($Path)) {
        $label = $script:trackTimeLabels[$Path]
        if (-not $label.IsDisposed) {
            if ($null -eq $Duration) {
                if ($script:trackProgressSliders.ContainsKey($Path)) {
                    $Duration = [TimeSpan]::FromMilliseconds($script:trackProgressSliders[$Path].Maximum)
                } else {
                    $Duration = [TimeSpan]::Zero
                }
            }
            $label.Text = '0:00 / {0}' -f (Format-TrackTime -Time ([TimeSpan]$Duration))
        }
    }
}

function Set-TrackPlaybackButtonState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$IsPlaying
    )

    if ($script:trackPlayButtons.ContainsKey($Path)) {
        $button = $script:trackPlayButtons[$Path]
        if (-not $button.IsDisposed) {
            $button.Checked = $IsPlaying
            $button.Text = if ($IsPlaying) { 'Pause' } else { 'Play' }
        }
    }
}

function Set-TrackOffsetNowLinksState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    if ($script:trackOffsetNowLinks.ContainsKey($Path)) {
        foreach ($link in $script:trackOffsetNowLinks[$Path]) {
            if (-not $link.IsDisposed) {
                $link.Enabled = $Enabled
            }
        }
    }
}

function Set-TrackOffsetToNow {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OffsetType,
        [Parameter(Mandatory = $true)][object]$OffsetControl
    )

    if (-not $script:playbacks.ContainsKey($Path)) {
        return
    }

    $playback = $script:playbacks[$Path]
    if ($OffsetType -ne 'Start' -and $OffsetType -ne 'End') {
        throw "Unsupported track offset type '$OffsetType'."
    }

    $timestampMs = [long][Math]::Floor($playback.Reader.CurrentTime.TotalMilliseconds)
    Set-TrackTimestampControl `
        -Path $Path `
        -TimestampType $OffsetType `
        -TimestampControl $OffsetControl `
        -TimestampMs $timestampMs
}

function Pause-TrackPlayback {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($script:playbacks.ContainsKey($Path)) {
        $playback = $script:playbacks[$Path]
        if (-not $playback.IsPaused) {
            $playback.Output.Pause()
            $playback.IsPaused = $true
        }
        Set-TrackPlaybackButtonState -Path $Path -IsPlaying $false
    }
}

function Resume-TrackPlayback {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($script:playbacks.ContainsKey($Path)) {
        $playback = $script:playbacks[$Path]
        if ($playback.IsPaused) {
            $playback.Output.Play()
            $playback.IsPaused = $false
        }
        Set-TrackPlaybackButtonState -Path $Path -IsPlaying $true
    }
}

function Format-TrackTime {
    param([Parameter(Mandatory = $true)][TimeSpan]$Time)

    '{0}:{1:00}' -f [int][Math]::Floor($Time.TotalMinutes), $Time.Seconds
}

function Format-TrackTimestamp {
    param([Parameter(Mandatory = $true)][TimeSpan]$Time)

    $totalMilliseconds = [long][Math]::Floor($Time.TotalMilliseconds)
    if ($totalMilliseconds -lt 0) {
        throw 'Track timestamps cannot be negative.'
    }

    $hours = [long][Math]::Floor($totalMilliseconds / 3600000)
    $minutes = [int][Math]::Floor(($totalMilliseconds % 3600000) / 60000)
    $seconds = [int][Math]::Floor(($totalMilliseconds % 60000) / 1000)
    $milliseconds = [int]($totalMilliseconds % 1000)
    if ($hours -gt 0) {
        $formatted = '{0:00}:{1:00}:{2:00}' -f $hours, $minutes, $seconds
    } else {
        $formatted = '{0:00}:{1:00}' -f $minutes, $seconds
    }
    if ($milliseconds -gt 0) {
        $formatted += '.{0:000}' -f $milliseconds
    }
    $formatted
}

function ConvertFrom-TrackTimestamp {
    param([Parameter(Mandatory = $true)][string]$Timestamp)

    if ($Timestamp -notmatch '^(?:(?<hours>\d{1,2}):)?(?<minutes>\d{1,2}):(?<seconds>\d{1,2})(?:\.(?<milliseconds>\d{1,3}))?$') {
        throw "Invalid track timestamp '$Timestamp'. Use mm:ss[.fff] or hh:mm:ss[.fff]."
    }

    $hours = 0
    if ($Matches.hours) {
        $hours = [int]$Matches.hours
    }
    $minutes = [int]$Matches.minutes
    $seconds = [int]$Matches.seconds
    if ($minutes -gt 59 -or $seconds -gt 59) {
        throw "Invalid track timestamp '$Timestamp'. Minutes and seconds must be less than 60."
    }

    $milliseconds = 0
    if ($Matches.milliseconds) {
        $fraction = $Matches.milliseconds.PadRight(3, '0')
        $milliseconds = [int]$fraction
    }

    [long](($hours * 3600000) + ($minutes * 60000) + ($seconds * 1000) + $milliseconds)
}

function Set-TrackTimestampControl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Start', 'End')][string]$TimestampType,
        [Parameter(Mandatory = $true)][object]$TimestampControl,
        [long]$TimestampMs = -1
    )

    if ($TimestampMs -lt 0) {
        $TimestampMs = ConvertFrom-TrackTimestamp -Timestamp $TimestampControl.Text
    }
    if ($script:trackDurations.ContainsKey($Path)) {
        $durationMs = [long][Math]::Floor($script:trackDurations[$Path].TotalMilliseconds)
        if ($TimestampMs -gt $durationMs) {
            throw 'The timestamp cannot be later than the end of the track.'
        }
    }

    $propertyName = '{0}TimeMs' -f $TimestampType
    $script:trackOffsets[$Path][$propertyName] = $TimestampMs
    $TimestampControl.Text = Format-TrackTimestamp -Time ([TimeSpan]::FromMilliseconds($TimestampMs))
    if ($script:trackProgressMarkerPanels.ContainsKey($Path)) {
        $script:trackProgressMarkerPanels[$Path].Invalidate()
    }
}

function Get-TrackDuration {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [scriptblock]$ReaderFactory = {
            param($ReaderPath)
            New-Object NAudio.Wave.MediaFoundationReader -ArgumentList $ReaderPath
        }
    )

    $reader = $null
    try {
        $reader = & $ReaderFactory $Path
        [TimeSpan]$reader.TotalTime
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }
}

function Set-TrackDurationControls {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][TimeSpan]$Duration,
        [Parameter(Mandatory = $true)][object]$TimeLabel,
        [Parameter(Mandatory = $true)][object]$ProgressSlider
    )

    $script:trackDurations[$Path] = $Duration
    $TimeLabel.Text = '0:00 / {0}' -f (Format-TrackTime -Time $Duration)
    if ($Duration.TotalMilliseconds -le [int]::MaxValue) {
        $ProgressSlider.Minimum = 0
        $ProgressSlider.Maximum = [Math]::Max(1, [int][Math]::Floor($Duration.TotalMilliseconds))
        $ProgressSlider.Value = 0
    }
}

function Update-TrackPlaybackProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Playback
    )

    $currentTime = $Playback.Reader.CurrentTime
    if ($script:trackProgressSliders.ContainsKey($Path)) {
        $slider = $script:trackProgressSliders[$Path]
        if (-not $slider.IsDisposed) {
            $endPosition = [int]$Playback.Duration.TotalMilliseconds
            $Playback.UpdatingProgress = $true
            try {
                if ($slider.Minimum -ne 0) {
                    $slider.Minimum = 0
                }
                if ($slider.Maximum -ne $endPosition) {
                    $slider.Maximum = $endPosition
                }
                $position = [int][Math]::Min(
                    $slider.Maximum,
                    [Math]::Max($slider.Minimum, [Math]::Floor($currentTime.TotalMilliseconds))
                )
                $slider.Enabled = $true
                $slider.Value = $position
            }
            finally {
                $Playback.UpdatingProgress = $false
            }
        }
    }
    if ($script:trackProgressMarkerPanels.ContainsKey($Path)) {
        $markerPanel = $script:trackProgressMarkerPanels[$Path]
        if (-not $markerPanel.IsDisposed) {
            $markerPanel.Invalidate()
        }
    }

    if ($script:trackTimeLabels.ContainsKey($Path)) {
        $label = $script:trackTimeLabels[$Path]
        if (-not $label.IsDisposed) {
            $label.Text = '{0} / {1}' -f (Format-TrackTime -Time $currentTime), (
                Format-TrackTime -Time $Playback.Duration
            )
        }
    }
}

function Seek-TrackPlayback {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$PositionMs
    )

    if (-not $script:playbacks.ContainsKey($Path)) {
        return
    }

    $playback = $script:playbacks[$Path]
    $position = [TimeSpan]::FromMilliseconds($PositionMs)
    if ($position -lt $playback.StartTime -or $position -gt $playback.ConfiguredEndTime) {
        $playback.EndTime = $playback.Duration
    } else {
        $playback.EndTime = $playback.ConfiguredEndTime
    }
    $playback.Reader.CurrentTime = $position
    Update-TrackPlaybackVolume -Path $Path -Playback $playback
    Update-TrackPlaybackProgress -Path $Path -Playback $playback
}

function Update-TrackPlaybackVolume {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Playback
    )

    $elapsedMs = ($Playback.Reader.CurrentTime - $Playback.StartTime).TotalMilliseconds
    $elapsedMs = [Math]::Max(0, $elapsedMs)
    $fadeFactor = 1.0
    if ($Playback.FadeInMs -gt 0) {
        $fadeFactor *= [Math]::Min(1.0, [Math]::Max(0.0, $elapsedMs / $Playback.FadeInMs))
    }

    $remainingMs = ($Playback.EndTime - $Playback.Reader.CurrentTime).TotalMilliseconds
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
        [Parameter(Mandatory = $true)][int]$FadeOutMs,
        [Parameter(Mandatory = $true)][long]$StartTimeMs,
        [Parameter(Mandatory = $true)][long]$EndTimeMs
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
        $duration = $reader.TotalTime
        if ($StartTimeMs -lt 0 -or $EndTimeMs -lt 0) {
            throw 'Track timestamps cannot be negative.'
        }
        if ($duration.TotalMilliseconds -gt [int]::MaxValue) {
            throw 'This track is too long to display in the progress slider.'
        }
        if ($StartTimeMs -ge $EndTimeMs -or $EndTimeMs -gt $duration.TotalMilliseconds) {
            throw 'The start timestamp must be before the end timestamp, and both must be within the track.'
        }
        $startTime = [TimeSpan]::FromMilliseconds($StartTimeMs)
        $endTime = [TimeSpan]::FromMilliseconds($EndTimeMs)
        $reader.CurrentTime = $startTime
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
            Reader = $reader
            Output = $output
            DeviceIndex = $DeviceIndex
            Duration = $duration
            StartTime = $startTime
            ConfiguredEndTime = $endTime
            EndTime = $endTime
            FadeInMs = $FadeInMs
            FadeOutMs = $FadeOutMs
            UpdatingProgress = $false
            IsPaused = $false
        }
        $script:trackDurations[$Path] = $duration
        Update-TrackPlaybackVolume -Path $Path -Playback $script:playbacks[$Path]
        Update-TrackPlaybackProgress -Path $Path -Playback $script:playbacks[$Path]
        Set-TrackPlaybackButtonState -Path $Path -IsPlaying $true
        Set-TrackOffsetNowLinksState -Path $Path -Enabled $true
    }
    catch {
        Set-TrackPlaybackButtonState -Path $Path -IsPlaying $false
        Set-TrackOffsetNowLinksState -Path $Path -Enabled $false
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

            $startTimeMs = ConvertFrom-TrackTimestamp -Timestamp $track.StartTimeInput.Text
            $endTimeMs = ConvertFrom-TrackTimestamp -Timestamp $track.EndTimeInput.Text
            $trackSettingsEntry = [ordered]@{
                FileName = [System.IO.Path]::GetFileName($track.Path)
                Sha256 = (Get-FileHash -LiteralPath $track.Path -Algorithm SHA256 -ErrorAction Stop).Hash
                DeviceId = $deviceId
                Volume = $track.VolumeSlider.Value
                FadeInMs = [int]$track.FadeInInput.Value
                FadeOutMs = [int]$track.FadeOutInput.Value
                StartTimeMs = $startTimeMs
            }
            if (
                -not $script:trackDurations.ContainsKey($track.Path) -or
                $endTimeMs -lt [long][Math]::Floor($script:trackDurations[$track.Path].TotalMilliseconds)
            ) {
                $trackSettingsEntry.EndTimeMs = $endTimeMs
            }
            [pscustomobject]$trackSettingsEntry
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
        Version = 2
        WindowWidth = $script:mainForm.ClientSize.Width
        WindowHeight = $script:mainForm.ClientSize.Height
        DefaultDeviceId = $defaultDeviceId
        DeviceVolumes = $deviceVolumes
        Tracks = $trackSettings
    }
}

function Save-TrackSettings {
    param([Parameter(Mandatory = $true)][string]$Path)

    $settings = Get-TrackSettingsSnapshot
    $json = ConvertTo-Json -InputObject $settings -Depth 6
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8 -ErrorAction Stop
    $script:lastSettingsPath = $Path
}

function Refresh-AudioDevices {
    $previousDevices = @($script:audioDevices)
    $previousDevicesById = @{}
    $previousVolumesById = @{}
    $previousInitialVolumesById = @{}
    for ($index = 0; $index -lt $previousDevices.Count; $index++) {
        $deviceId = [string]$previousDevices[$index].ID
        $previousDevicesById[$deviceId] = $previousDevices[$index]
        if ($index -lt $script:deviceMasterSliders.Count) {
            $previousVolumesById[$deviceId] = $script:deviceMasterSliders[$index].Value
        }
        if ($index -lt $script:initialDeviceVolumes.Count) {
            $previousInitialVolumesById[$deviceId] = $script:initialDeviceVolumes[$index]
        }
    }

    $previousDefaultDeviceId = $null
    if ($script:defaultDeviceIndex -ge 0 -and $script:defaultDeviceIndex -lt $previousDevices.Count) {
        $previousDefaultDeviceId = [string]$previousDevices[$script:defaultDeviceIndex].ID
    }

    $previousTrackSelectionsByPath = @{}
    foreach ($row in $script:trackPanel.Controls) {
        $track = $row.Tag
        if ($null -eq $track -or $null -eq $track.DevicePicker) {
            continue
        }
        $selectedIndex = $track.DevicePicker.SelectedIndex
        if ($selectedIndex -gt 0 -and $selectedIndex -le $previousDevices.Count) {
            $previousTrackSelectionsByPath[$track.Path] = [string]$previousDevices[$selectedIndex - 1].ID
        }
    }

    $enumerator = New-Object NAudio.CoreAudioApi.MMDeviceEnumerator
    try {
        $enumeratedDevices = @(
            $enumerator.EnumerateAudioEndPoints(
                [NAudio.CoreAudioApi.DataFlow]::Render,
                [NAudio.CoreAudioApi.DeviceState]::Active
            )
        )
    }
    finally {
        $enumerator.Dispose()
    }

    $newDevices = New-Object 'System.Collections.Generic.List[object]'
    foreach ($device in $enumeratedDevices) {
        $deviceId = [string]$device.ID
        if ($previousDevicesById.ContainsKey($deviceId)) {
            $newDevices.Add($previousDevicesById[$deviceId])
            $device.Dispose()
        } else {
            $newDevices.Add($device)
        }
    }

    $newIndexesById = @{}
    for ($index = 0; $index -lt $newDevices.Count; $index++) {
        $newIndexesById[[string]$newDevices[$index].ID] = $index
    }

    foreach ($path in @($script:playbacks.Keys)) {
        $playback = $script:playbacks[$path]
        $oldDeviceId = $null
        if ($playback.DeviceIndex -ge 0 -and $playback.DeviceIndex -lt $previousDevices.Count) {
            $oldDeviceId = [string]$previousDevices[$playback.DeviceIndex].ID
        }
        if ($null -eq $oldDeviceId -or -not $newIndexesById.ContainsKey($oldDeviceId)) {
            Stop-TrackPlayback -Path $path
        } else {
            $playback.DeviceIndex = $newIndexesById[$oldDeviceId]
        }
    }

    foreach ($device in $previousDevices) {
        if (-not $newIndexesById.ContainsKey([string]$device.ID)) {
            $device.Dispose()
        }
    }

    $script:audioDevices = @($newDevices.ToArray())
    $script:defaultDeviceRadios = @()
    $script:deviceMasterSliders = @()
    $script:initialDeviceVolumes = @()
    $script:deviceMasterVolumes = @()
    $script:defaultDeviceIndex = -1

    $oldDeviceRows = @($script:devicePanel.Controls)
    $script:devicePanel.Controls.Clear()
    foreach ($oldDeviceRow in $oldDeviceRows) {
        $oldDeviceRow.Dispose()
    }

    $selectedDefaultIndex = 0
    if ($previousDefaultDeviceId -and $newIndexesById.ContainsKey($previousDefaultDeviceId)) {
        $selectedDefaultIndex = $newIndexesById[$previousDefaultDeviceId]
    }

    for ($index = 0; $index -lt $script:audioDevices.Count; $index++) {
        $device = $script:audioDevices[$index]
        $deviceId = [string]$device.ID
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
        if ($index -eq $selectedDefaultIndex) {
            $radio.Checked = $true
            $script:defaultDeviceIndex = $index
        }

        $masterSlider = New-Object System.Windows.Forms.TrackBar
        $masterSlider.Minimum = 0
        $masterSlider.Maximum = 100
        $currentVolume = [int][Math]::Round($device.AudioEndpointVolume.MasterVolumeLevelScalar * 100)
        $masterSlider.Value = if ($previousVolumesById.ContainsKey($deviceId)) {
            [int]$previousVolumesById[$deviceId]
        } else {
            $currentVolume
        }
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
        $script:deviceMasterVolumes += $masterSlider.Value
        if ($previousInitialVolumesById.ContainsKey($deviceId)) {
            $script:initialDeviceVolumes += $previousInitialVolumesById[$deviceId]
        } else {
            $script:initialDeviceVolumes += $currentVolume
        }
        $script:deviceMasterSliders += $masterSlider
        $deviceRow.Controls.Add($radio, 0, 0)
        $deviceRow.Controls.Add($masterSlider, 1, 0)
        $script:devicePanel.Controls.Add($deviceRow)
    }

    if ($script:audioDevices.Count -eq 0) {
        $script:defaultDeviceIndex = -1
        $noDeviceLabel = New-Object System.Windows.Forms.Label
        $noDeviceLabel.Text = 'No active audio devices'
        $noDeviceLabel.AutoSize = $true
        $script:devicePanel.Controls.Add($noDeviceLabel)
    }

    foreach ($row in $script:trackPanel.Controls) {
        $track = $row.Tag
        if ($null -eq $track -or $null -eq $track.DevicePicker) {
            continue
        }
        $track.DevicePicker.Items.Clear()
        [void]$track.DevicePicker.Items.Add('Default')
        foreach ($device in $script:audioDevices) {
            [void]$track.DevicePicker.Items.Add($device.FriendlyName)
        }
        $selectedIndex = 0
        if ($previousTrackSelectionsByPath.ContainsKey($track.Path)) {
            $selectedDeviceId = $previousTrackSelectionsByPath[$track.Path]
            if ($newIndexesById.ContainsKey($selectedDeviceId)) {
                $selectedIndex = $newIndexesById[$selectedDeviceId] + 1
            }
        }
        $track.DevicePicker.SelectedIndex = $selectedIndex
        $script:trackDeviceSelections[$track.Path] = $selectedIndex
    }

    $script:devicePanel.Height = [Math]::Min(250, [Math]::Max(56, ($script:audioDevices.Count * 52) + 8))
    Resize-DeviceRows
}

function Apply-TrackSettings {
    param([Parameter(Mandatory = $true)][object]$Settings)

    if ($Settings.Version -ne 2 -or $null -eq $Settings.Tracks) {
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
        $startTimeMs = [long]$savedTrack.StartTimeMs
        $endTimeMs = [long]$savedTrack.EndTimeMs
        if (
            $startTimeMs -ge 0 -and
            $endTimeMs -gt $startTimeMs -and
            $script:trackDurations.ContainsKey($path) -and
            $endTimeMs -le $script:trackDurations[$path].TotalMilliseconds
        ) {
            $track.StartTimeInput.Text = Format-TrackTimestamp -Time ([TimeSpan]::FromMilliseconds($startTimeMs))
            $track.EndTimeInput.Text = Format-TrackTimestamp -Time ([TimeSpan]::FromMilliseconds($endTimeMs))
            $script:trackOffsets[$path].StartTimeMs = $startTimeMs
            $script:trackOffsets[$path].EndTimeMs = $endTimeMs
        }

        if ($savedTrack.DeviceId -and $deviceIndexes.ContainsKey([string]$savedTrack.DeviceId)) {
            $track.DevicePicker.SelectedIndex = $deviceIndexes[[string]$savedTrack.DeviceId] + 1
        } else {
            $track.DevicePicker.SelectedIndex = 0
        }
        $script:trackDeviceSelections[$path] = $track.DevicePicker.SelectedIndex
    }

    $windowWidth = [int]$Settings.WindowWidth
    $windowHeight = [int]$Settings.WindowHeight
    if ($windowWidth -gt 0 -and $windowWidth -le 10000 -and $windowHeight -gt 0 -and $windowHeight -le 10000) {
        $script:mainForm.ClientSize = New-Object System.Drawing.Size($windowWidth, $windowHeight)
    }
}

function Reset-TrackSettings {
    foreach ($row in $script:trackPanel.Controls) {
        $track = $row.Tag
        $track.VolumeSlider.Value = 50
        $track.FadeInInput.Value = 0
        $track.FadeOutInput.Value = 0
        $track.StartTimeInput.Text = '00:00'
        $endTimeMs = 0
        if ($script:trackDurations.ContainsKey($track.Path)) {
            $endTimeMs = [long][Math]::Floor($script:trackDurations[$track.Path].TotalMilliseconds)
        }
        $track.EndTimeInput.Text = Format-TrackTimestamp -Time ([TimeSpan]::FromMilliseconds($endTimeMs))
        $script:trackOffsets[$track.Path].StartTimeMs = 0
        $script:trackOffsets[$track.Path].EndTimeMs = $endTimeMs
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
    $script:trackProgressSliders = @{}
    $script:trackTimeLabels = @{}
    $script:trackPlayButtons = @{}
    $script:trackOffsetNowLinks = @{}
    $script:trackPanel.SuspendLayout()
    try {
        foreach ($oldRow in @($script:trackPanel.Controls)) {
            $oldRow.Dispose()
        }
        $script:trackPanel.Controls.Clear()
        foreach ($file in $files) {
            if (-not $script:trackDurations.ContainsKey($file.FullName)) {
                try {
                    $script:trackDurations[$file.FullName] = Get-TrackDuration -Path $file.FullName
                }
                catch {
                    $script:trackDurations.Remove($file.FullName)
                }
            }

            $row = New-Object System.Windows.Forms.TableLayoutPanel
            $row.Height = 112
            $row.ColumnCount = 9
            $row.RowCount = 3
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
            $row.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                52
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Percent,
                100
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                140
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                110
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                100
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                100
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                150
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                150
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                55
            )))
            $row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                55
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
            if (-not $script:trackOffsets.ContainsKey($file.FullName)) {
                $endTimeMs = 0
                if ($script:trackDurations.ContainsKey($file.FullName)) {
                    $endTimeMs = [long][Math]::Floor($script:trackDurations[$file.FullName].TotalMilliseconds)
                }
                $script:trackOffsets[$file.FullName] = @{ StartTimeMs = 0; EndTimeMs = $endTimeMs }
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

            $startOffsetLabel = New-Object System.Windows.Forms.Label
            $startOffsetLabel.Text = 'Start time'
            $startOffsetLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $startOffsetLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
            $startOffsetLabel.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)
            $startOffsetNowLink = New-Object System.Windows.Forms.LinkLabel
            $startOffsetNowLink.Text = 'Set to Now'
            $startOffsetNowLink.Dock = [System.Windows.Forms.DockStyle]::Fill
            $startOffsetNowLink.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
            $startOffsetNowLink.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)
            $startOffsetNowLink.Enabled = $script:playbacks.ContainsKey($file.FullName)
            $startOffsetNowLink.Tag = @{
                Path = $file.FullName
                TimestampControl = $null
                OffsetType = 'Start'
            }
            $startOffsetNowLink.Add_LinkClicked({
                Set-TrackOffsetToNow `
                    -Path $this.Tag.Path `
                    -OffsetType $this.Tag.OffsetType `
                    -OffsetControl $this.Tag.TimestampControl
            })
            $startOffsetInput = New-Object System.Windows.Forms.TextBox
            $startOffsetInput.Text = Format-TrackTimestamp -Time ([TimeSpan]::FromMilliseconds(
                $script:trackOffsets[$file.FullName].StartTimeMs
            ))
            $startOffsetInput.Dock = [System.Windows.Forms.DockStyle]::Fill
            $startOffsetInput.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
            $startOffsetInput.Tag = @{ Path = $file.FullName; TimestampType = 'Start' }
            $startOffsetInput.Add_Validated({
                try {
                    Set-TrackTimestampControl `
                        -Path $this.Tag.Path `
                        -TimestampType $this.Tag.TimestampType `
                        -TimestampControl $this
                }
                catch {
                    $fieldPath = $this.Tag.Path
                    $fieldKey = '{0}TimeMs' -f $this.Tag.TimestampType
                    $this.Text = Format-TrackTimestamp -Time ([TimeSpan]::FromMilliseconds(
                        $script:trackOffsets[$fieldPath][$fieldKey]
                    ))
                }
            })
            $startOffsetNowLink.Tag.TimestampControl = $startOffsetInput

            $endOffsetLabel = New-Object System.Windows.Forms.Label
            $endOffsetLabel.Text = 'End time'
            $endOffsetLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $endOffsetLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
            $endOffsetLabel.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)
            $endOffsetNowLink = New-Object System.Windows.Forms.LinkLabel
            $endOffsetNowLink.Text = 'Set to Now'
            $endOffsetNowLink.Dock = [System.Windows.Forms.DockStyle]::Fill
            $endOffsetNowLink.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
            $endOffsetNowLink.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)
            $endOffsetNowLink.Enabled = $script:playbacks.ContainsKey($file.FullName)
            $endOffsetNowLink.Tag = @{
                Path = $file.FullName
                TimestampControl = $null
                OffsetType = 'End'
            }
            $endOffsetNowLink.Add_LinkClicked({
                Set-TrackOffsetToNow `
                    -Path $this.Tag.Path `
                    -OffsetType $this.Tag.OffsetType `
                    -OffsetControl $this.Tag.TimestampControl
            })
            $endOffsetInput = New-Object System.Windows.Forms.TextBox
            $endOffsetInput.Text = Format-TrackTimestamp -Time ([TimeSpan]::FromMilliseconds(
                $script:trackOffsets[$file.FullName].EndTimeMs
            ))
            $endOffsetInput.Dock = [System.Windows.Forms.DockStyle]::Fill
            $endOffsetInput.Margin = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
            $endOffsetInput.Tag = @{ Path = $file.FullName; TimestampType = 'End' }
            $endOffsetInput.Add_Validated({
                try {
                    Set-TrackTimestampControl `
                        -Path $this.Tag.Path `
                        -TimestampType $this.Tag.TimestampType `
                        -TimestampControl $this
                }
                catch {
                    $fieldPath = $this.Tag.Path
                    $fieldKey = '{0}TimeMs' -f $this.Tag.TimestampType
                    $this.Text = Format-TrackTimestamp -Time ([TimeSpan]::FromMilliseconds(
                        $script:trackOffsets[$fieldPath][$fieldKey]
                    ))
                }
            })
            $endOffsetNowLink.Tag.TimestampControl = $endOffsetInput

            $progressPanel = New-Object System.Windows.Forms.TableLayoutPanel
            $progressPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $progressPanel.ColumnCount = 2
            $progressPanel.RowCount = 2
            $progressPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                38
            )))
            $progressPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                12
            )))
            $progressPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                120
            )))
            $progressPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Percent,
                100
            )))

            $timeLabel = New-Object System.Windows.Forms.Label
            $timeLabel.Text = '0:00 / --:--'
            $timeLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $timeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
            $timeLabel.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)
            $script:trackTimeLabels[$file.FullName] = $timeLabel

            $progressSlider = New-Object System.Windows.Forms.TrackBar
            $progressSlider.Minimum = 0
            $progressSlider.Maximum = 1
            $progressSlider.TickStyle = [System.Windows.Forms.TickStyle]::None
            $progressSlider.Dock = [System.Windows.Forms.DockStyle]::Fill
            $progressSlider.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)
            $progressSlider.Tag = $file.FullName
            $progressSlider.Enabled = $script:playbacks.ContainsKey($file.FullName)
            $script:trackProgressSliders[$file.FullName] = $progressSlider
            $trackDuration = $null
            try {
                if (-not $script:trackDurations.ContainsKey($file.FullName)) {
                    $script:trackDurations[$file.FullName] = Get-TrackDuration -Path $file.FullName
                }
                $trackDuration = [TimeSpan]$script:trackDurations[$file.FullName]
            }
            catch {
                $script:trackDurations.Remove($file.FullName)
            }
            if ($null -ne $trackDuration) {
                Set-TrackDurationControls `
                    -Path $file.FullName `
                    -Duration $trackDuration `
                    -TimeLabel $timeLabel `
                    -ProgressSlider $progressSlider
            }
            if ($script:playbacks.ContainsKey($file.FullName)) {
                $playback = $script:playbacks[$file.FullName]
                $progressSlider.Minimum = 0
                $progressSlider.Maximum = [int]$playback.Duration.TotalMilliseconds
            }
            $progressSlider.Add_ValueChanged({
                $path = $this.Tag
                if ($script:playbacks.ContainsKey($path)) {
                    $playback = $script:playbacks[$path]
                    if (-not $playback.UpdatingProgress) {
                        Seek-TrackPlayback -Path $path -PositionMs $this.Value
                    }
                }
            })
            $progressPanel.Controls.Add($timeLabel, 0, 0)
            $progressPanel.Controls.Add($progressSlider, 1, 0)

            $markerPanel = New-Object System.Windows.Forms.Panel
            $markerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
            $markerPanel.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0)
            $markerPanel.Tag = $file.FullName
            $markerPanel.Add_Paint({
                param($sender, $eventArgs)

                $path = $sender.Tag
                if (-not $script:trackDurations.ContainsKey($path)) {
                    return
                }

                $durationMs = $script:trackDurations[$path].TotalMilliseconds
                if ($durationMs -le 0 -or $sender.ClientSize.Width -le 16) {
                    return
                }

                $offsets = $script:trackOffsets[$path]
                $trackWidth = $sender.ClientSize.Width - 16
                $startTimeMs = [Math]::Min(
                    $durationMs,
                    [Math]::Max(0, [double]$offsets.StartTimeMs)
                )
                $startX = 8 + [int][Math]::Round(
                    ($startTimeMs / $durationMs) * $trackWidth
                )
                $endTimeMs = [Math]::Min(
                    $durationMs,
                    [Math]::Max(0, [double]$offsets.EndTimeMs)
                )
                $endX = 8 + [int][Math]::Round(
                    ($endTimeMs / $durationMs) * $trackWidth
                )
                $startPen = New-Object System.Drawing.Pen(
                    [System.Drawing.Color]::DodgerBlue,
                    2
                )
                $endPen = New-Object System.Drawing.Pen(
                    [System.Drawing.Color]::DarkOrange,
                    2
                )
                try {
                    $eventArgs.Graphics.DrawLine($startPen, $startX, 0, $startX, $sender.ClientSize.Height)
                    $eventArgs.Graphics.DrawLine($endPen, $endX, 0, $endX, $sender.ClientSize.Height)
                }
                finally {
                    $startPen.Dispose()
                    $endPen.Dispose()
                }
            })
            $script:trackProgressMarkerPanels[$file.FullName] = $markerPanel
            $progressPanel.Controls.Add($markerPanel, 1, 1)

            $playButton = New-Object System.Windows.Forms.CheckBox
            $playButton.Appearance = [System.Windows.Forms.Appearance]::Button
            $playButton.AutoCheck = $false
            $playButton.Text = 'Play'
            $playButton.Dock = [System.Windows.Forms.DockStyle]::Fill
            $playButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
            $playButton.Tag = @{
                Path = $file.FullName
                DevicePicker = $trackDevicePicker
                VolumeSlider = $volumeSlider
                FadeInInput = $fadeInInput
                FadeOutInput = $fadeOutInput
                StartTimeInput = $startOffsetInput
                EndTimeInput = $endOffsetInput
            }
            $playButton.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 9)
            $script:trackPlayButtons[$file.FullName] = $playButton
            if ($script:playbacks.ContainsKey($file.FullName)) {
                $isPlaying = -not $script:playbacks[$file.FullName].IsPaused
                $playButton.Checked = $isPlaying
                if ($isPlaying) {
                    $playButton.Text = 'Pause'
                }
            }
            $playButton.Add_Click({
                $path = $this.Tag.Path
                if ($script:playbacks.ContainsKey($path)) {
                    if ($script:playbacks[$path].IsPaused) {
                        Resume-TrackPlayback -Path $path
                    } else {
                        Pause-TrackPlayback -Path $path
                    }
                } else {
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
                        -FadeOutMs $this.Tag.FadeOutInput.Value `
                        -StartTimeMs $script:trackOffsets[$path].StartTimeMs `
                        -EndTimeMs $script:trackOffsets[$path].EndTimeMs
                }
            })

            $stopButton = New-Object System.Windows.Forms.Button
            $stopButton.Text = 'Stop'
            $stopButton.Dock = [System.Windows.Forms.DockStyle]::Fill
            $stopButton.Tag = $file.FullName
            $stopButton.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 9)
            $stopButton.Add_Click({
                Stop-TrackPlayback -Path $this.Tag
            })

            $row.SetRowSpan($nameLabel, 3)
            $row.SetRowSpan($playButton, 3)
            $row.SetRowSpan($stopButton, 3)
            $row.Controls.Add($nameLabel, 0, 0)
            $row.Controls.Add($trackDeviceLabel, 1, 0)
            $row.Controls.Add($trackDevicePicker, 1, 1)
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
            $row.Controls.Add($volumeHeader, 2, 0)
            $row.Controls.Add($volumeSlider, 2, 1)
            $row.Controls.Add($fadeInLabel, 3, 0)
            $row.Controls.Add($fadeInInput, 3, 1)
            $row.Controls.Add($fadeOutLabel, 4, 0)
            $row.Controls.Add($fadeOutInput, 4, 1)
            $startOffsetHeader = New-Object System.Windows.Forms.TableLayoutPanel
            $startOffsetHeader.Dock = [System.Windows.Forms.DockStyle]::Fill
            $startOffsetHeader.ColumnCount = 2
            $startOffsetHeader.RowCount = 1
            $startOffsetHeader.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Percent,
                100
            )))
            $startOffsetHeader.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                72
            )))
            $startOffsetHeader.Controls.Add($startOffsetLabel, 0, 0)
            $startOffsetHeader.Controls.Add($startOffsetNowLink, 1, 0)
            $endOffsetHeader = New-Object System.Windows.Forms.TableLayoutPanel
            $endOffsetHeader.Dock = [System.Windows.Forms.DockStyle]::Fill
            $endOffsetHeader.ColumnCount = 2
            $endOffsetHeader.RowCount = 1
            $endOffsetHeader.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Percent,
                100
            )))
            $endOffsetHeader.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
                [System.Windows.Forms.SizeType]::Absolute,
                72
            )))
            $endOffsetHeader.Controls.Add($endOffsetLabel, 0, 0)
            $endOffsetHeader.Controls.Add($endOffsetNowLink, 1, 0)
            $row.Controls.Add($startOffsetHeader, 5, 0)
            $row.Controls.Add($startOffsetInput, 5, 1)
            $row.Controls.Add($endOffsetHeader, 6, 0)
            $row.Controls.Add($endOffsetInput, 6, 1)
            $row.Controls.Add($progressPanel, 1, 2)
            $row.SetColumnSpan($progressPanel, 6)
            $row.Controls.Add($playButton, 7, 0)
            $row.Controls.Add($stopButton, 8, 0)
            $row.Tag = @{
                Path = $file.FullName
                DevicePicker = $trackDevicePicker
                VolumeSlider = $volumeSlider
                FadeInInput = $fadeInInput
                FadeOutInput = $fadeOutInput
                StartTimeInput = $startOffsetInput
                EndTimeInput = $endOffsetInput
            }
            $script:trackOffsetNowLinks[$file.FullName] = @(
                $startOffsetNowLink,
                $endOffsetNowLink
            )
            if ($script:playbacks.ContainsKey($file.FullName)) {
                Update-TrackPlaybackProgress -Path $file.FullName -Playback $script:playbacks[$file.FullName]
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
$script:mainForm = $form
$form.Text = 'Track Player'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.ClientSize = New-Object System.Drawing.Size(1450, 700)
$form.MinimumSize = New-Object System.Drawing.Size(1250, 400)

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
$script:settingsPanel.ColumnCount = 2
$script:settingsPanel.RowCount = 1
$script:settingsPanel.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
$script:settingsPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
    [System.Windows.Forms.SizeType]::Percent,
    100
)))
$script:settingsPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle(
    [System.Windows.Forms.SizeType]::Absolute,
    410
)))

$settingsActionsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$settingsActionsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$settingsActionsPanel.WrapContents = $false
$settingsActionsPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$settingsActionsPanel.Padding = New-Object System.Windows.Forms.Padding(0)

$settingsFileActionsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$settingsFileActionsPanel.Dock = [System.Windows.Forms.DockStyle]::Right
$settingsFileActionsPanel.AutoSize = $true
$settingsFileActionsPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$settingsFileActionsPanel.WrapContents = $false
$settingsFileActionsPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$settingsFileActionsPanel.Padding = New-Object System.Windows.Forms.Padding(0)

$refreshDevicesButton = New-Object System.Windows.Forms.Button
$refreshDevicesButton.Text = 'Refresh Devices'
$refreshDevicesButton.AutoSize = $true
$refreshDevicesButton.Margin = New-Object System.Windows.Forms.Padding(3)

$resetSettingsButton = New-Object System.Windows.Forms.Button
$resetSettingsButton.Text = 'Reset to Defaults'
$resetSettingsButton.AutoSize = $true
$resetSettingsButton.Margin = New-Object System.Windows.Forms.Padding(3)
$resetSettingsButton.Add_Click({ Reset-TrackSettings })

$saveSettingsButton = New-Object System.Windows.Forms.Button
$saveSettingsButton.Text = 'Save Settings'
$saveSettingsButton.AutoSize = $true
$saveSettingsButton.Margin = New-Object System.Windows.Forms.Padding(3)
$saveSettingsButton.Enabled = $false
$saveAsSettingsButton = New-Object System.Windows.Forms.Button
$saveAsSettingsButton.Text = 'Save Settings As...'
$saveAsSettingsButton.AutoSize = $true
$saveAsSettingsButton.Margin = New-Object System.Windows.Forms.Padding(3)
$loadSettingsButton = New-Object System.Windows.Forms.Button
$loadSettingsButton.Text = 'Load Settings...'
$loadSettingsButton.AutoSize = $true
$loadSettingsButton.Margin = New-Object System.Windows.Forms.Padding(3)
$settingsActionsPanel.Controls.Add($refreshDevicesButton)
$settingsActionsPanel.Controls.Add($resetSettingsButton)
$settingsFileActionsPanel.Controls.Add($loadSettingsButton)
$settingsFileActionsPanel.Controls.Add($saveAsSettingsButton)
$settingsFileActionsPanel.Controls.Add($saveSettingsButton)
$script:settingsPanel.Controls.Add($settingsActionsPanel, 0, 0)
$script:settingsPanel.Controls.Add($settingsFileActionsPanel, 1, 0)

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

$refreshDevicesButton.Add_Click({
    try {
        Refresh-AudioDevices
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not refresh audio devices:`r`n$($_.Exception.Message)",
            'Audio device error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$saveAsSettingsButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = 'Save track player settings'
    $dialog.Filter = 'JSON settings (*.json)|*.json|All files (*.*)|*.*'
    $dialog.DefaultExt = 'json'
    $dialog.AddExtension = $true
    $dialog.FileName = if ($script:lastSettingsPath) {
        [System.IO.Path]::GetFileName($script:lastSettingsPath)
    } else {
        'TrackPlayerSettings.json'
    }
    if ($script:lastSettingsPath) {
        $dialog.InitialDirectory = [System.IO.Path]::GetDirectoryName($script:lastSettingsPath)
    }
    try {
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            Save-TrackSettings -Path $dialog.FileName
            $saveSettingsButton.Enabled = $true
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

$saveSettingsButton.Add_Click({
    if ($script:lastSettingsPath) {
        try {
            Save-TrackSettings -Path $script:lastSettingsPath
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not save settings:`r`n$($_.Exception.Message)",
                'Settings save error',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
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
            if (
                $script:playbacks[$path].Output.PlaybackState -eq [NAudio.Wave.PlaybackState]::Stopped -or
                $script:playbacks[$path].Reader.CurrentTime -ge $script:playbacks[$path].EndTime
            ) {
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
            $playback = $script:playbacks[$path]
            if ($playback.Reader.CurrentTime -ge $playback.EndTime) {
                Stop-TrackPlayback -Path $path
                continue
            }
            Update-TrackPlaybackVolume -Path $path -Playback $playback
            Update-TrackPlaybackProgress -Path $path -Playback $playback
        }
    }
    catch {
        $fadeTimer.Stop()
        [System.Windows.Forms.MessageBox]::Show(
            "Could not update playback controls:`r`n$($_.Exception.Message)",
            'Playback update error',
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
