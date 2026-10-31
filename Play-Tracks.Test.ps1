$sourcePath = Join-Path $PSScriptRoot 'Play-Tracks.ps1'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Play-Tracks.ps1 was not found at '$sourcePath'."
}

$tokens = $null
$parseErrors = $null
$sourceAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $sourcePath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "Play-Tracks.ps1 has PowerShell parse errors: $($parseErrors -join '; ')"
}

$functionsUnderTest = @(
    'Stop-TrackPlayback',
    'Reset-TrackPlaybackProgress',
    'Set-TrackPlaybackButtonState',
    'Set-TrackOffsetNowLinksState',
    'Set-TrackOffsetToNow',
    'Pause-TrackPlayback',
    'Resume-TrackPlayback',
    'Format-TrackTime',
    'Format-TrackTimestamp',
    'ConvertFrom-TrackTimestamp',
    'Set-TrackTimestampControl',
    'Get-TrackDuration',
    'Set-TrackDurationControls',
    'Update-TrackPlaybackProgress',
    'Seek-TrackPlayback',
    'Update-TrackPlaybackVolume',
    'Get-TrackFiles',
    'Get-TrackSettingsSnapshot',
    'Save-TrackSettings',
    'Apply-TrackSettings',
    'Reset-TrackSettings'
)
foreach ($functionName in $functionsUnderTest) {
    $functionAst = $sourceAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    if (-not $functionAst) {
        throw "Function '$functionName' was not found in Play-Tracks.ps1."
    }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

Describe 'Play-Tracks regression tests' {
    BeforeEach {
        $script:testRoot = Join-Path $env:TEMP ("Play-Tracks.Tests-" + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:testRoot -ErrorAction Stop)
        $script:tracksPath = Join-Path $script:testRoot 'Tracks'
        [void](New-Item -ItemType Directory -Path $script:tracksPath -ErrorAction Stop)

        $script:trackPanel = [pscustomobject]@{ Controls = @() }
        $script:mainForm = [pscustomobject]@{
            ClientSize = [pscustomobject]@{ Width = 1450; Height = 700 }
        }
        $script:audioDevices = @()
        $script:deviceMasterSliders = @()
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
        $script:lastTrackPaths = @()
        $script:lastSettingsPath = $null
    }

    AfterEach {
        if ($script:testRoot -and (Test-Path -LiteralPath $script:testRoot)) {
            Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        }
    }

    It 'lists MP3 files in case-insensitive filename order and excludes other files' {
        Set-Content -LiteralPath (Join-Path $script:tracksPath 'zeta.mp3') -Value 'z'
        Set-Content -LiteralPath (Join-Path $script:tracksPath 'Alpha.MP3') -Value 'a'
        Set-Content -LiteralPath (Join-Path $script:tracksPath 'notes.txt') -Value 'not audio'

        $files = @(Get-TrackFiles)

        $files.Count | Should Be 2
        $files[0].Name | Should Be 'Alpha.MP3'
        $files[1].Name | Should Be 'zeta.mp3'
    }

    It 'applies the requested track volume multiplied by the fade-in envelope' {
        $script:trackVolumes['track.mp3'] = 80
        $playback = @{
            Reader = [pscustomobject]@{ CurrentTime = [TimeSpan]::FromMilliseconds(250) }
            StartTime = [TimeSpan]::Zero
            EndTime = [TimeSpan]::FromSeconds(10)
            Duration = [TimeSpan]::FromSeconds(10)
            FadeInMs = 1000
            FadeOutMs = 0
            VolumeProvider = [pscustomobject]@{ Volume = 0.0 }
        }

        Update-TrackPlaybackVolume -Path 'track.mp3' -Playback $playback

        [Math]::Abs($playback.VolumeProvider.Volume - 0.2) | Should BeLessThan 0.06
    }

    It 'applies the fade-out envelope and returns to the requested volume when fades are disabled' {
        $script:trackVolumes['track.mp3'] = 60
        $playback = @{
            Reader = [pscustomobject]@{ CurrentTime = [TimeSpan]::FromMilliseconds(9500) }
            StartTime = [TimeSpan]::Zero
            EndTime = [TimeSpan]::FromSeconds(10)
            Duration = [TimeSpan]::FromSeconds(10)
            FadeInMs = 0
            FadeOutMs = 2000
            VolumeProvider = [pscustomobject]@{ Volume = 0.0 }
        }

        Update-TrackPlaybackVolume -Path 'track.mp3' -Playback $playback
        [Math]::Abs($playback.VolumeProvider.Volume - 0.15) | Should BeLessThan 0.06

        $playback.FadeOutMs = 0
        Update-TrackPlaybackVolume -Path 'track.mp3' -Playback $playback
        [Math]::Abs($playback.VolumeProvider.Volume - 0.6) | Should BeLessThan 0.001
    }

    It 'calculates fade envelopes relative to the configured playback offsets' {
        $script:trackVolumes['track.mp3'] = 80
        $playback = @{
            Reader = [pscustomobject]@{ CurrentTime = [TimeSpan]::FromMilliseconds(65500) }
            StartTime = [TimeSpan]::FromMilliseconds(65000)
            EndTime = [TimeSpan]::FromMilliseconds(70000)
            Duration = [TimeSpan]::FromSeconds(90)
            FadeInMs = 1000
            FadeOutMs = 1000
            VolumeProvider = [pscustomobject]@{ Volume = 0.0 }
        }

        Update-TrackPlaybackVolume -Path 'track.mp3' -Playback $playback

        [Math]::Abs($playback.VolumeProvider.Volume - 0.4) | Should BeLessThan 0.02
    }

    It 'stops and disposes only the requested track playback and disables its progress slider' {
        $output = [pscustomobject]@{ StopCount = 0; DisposeCount = 0 }
        $output | Add-Member ScriptMethod Stop { $this.StopCount++ }
        $output | Add-Member ScriptMethod Dispose { $this.DisposeCount++ }
        $provider = [pscustomobject]@{ DisposeCount = 0 }
        $provider | Add-Member ScriptMethod Dispose { $this.DisposeCount++ }
        $otherPlayback = @{ Output = 'still playing' }
        $script:playbacks['first.mp3'] = @{
            Output = $output
            VolumeProvider = $provider
        }
        $script:playbacks['second.mp3'] = $otherPlayback
        $script:trackProgressSliders['first.mp3'] = [pscustomobject]@{
            IsDisposed = $false
            Enabled = $true
            Minimum = 0
            Maximum = 10000
            Value = 5000
        }

        Stop-TrackPlayback -Path 'first.mp3'

        $script:playbacks.ContainsKey('first.mp3') | Should Be $false
        $script:playbacks.ContainsKey('second.mp3') | Should Be $true
        $output.StopCount | Should Be 1
        $output.DisposeCount | Should Be 1
        $provider.DisposeCount | Should Be 1
        $script:trackProgressSliders['first.mp3'].Enabled | Should Be $false
        $script:trackProgressSliders['first.mp3'].Value | Should Be 0
    }

    It 'resets the finished track controls even when audio output disposal fails' {
        $output = [pscustomobject]@{ DisposeCount = 0 }
        $output | Add-Member ScriptMethod Stop {}
        $output | Add-Member ScriptMethod Dispose {
            $this.DisposeCount++
            throw 'dispose failed'
        }
        $provider = [pscustomobject]@{ DisposeCount = 0 }
        $provider | Add-Member ScriptMethod Dispose { $this.DisposeCount++ }
        $button = [pscustomobject]@{ IsDisposed = $false; Checked = $true; Text = 'Pause' }
        $slider = [pscustomobject]@{
            IsDisposed = $false
            Enabled = $true
            Minimum = 0
            Maximum = 10000
            Value = 10000
        }
        $script:trackPlayButtons['finished.mp3'] = $button
        $script:trackProgressSliders['finished.mp3'] = $slider
        $script:playbacks['finished.mp3'] = @{
            Output = $output
            VolumeProvider = $provider
            Duration = [TimeSpan]::FromSeconds(10)
        }

        $disposeFailed = $false
        try {
            Stop-TrackPlayback -Path 'finished.mp3'
        }
        catch {
            $disposeFailed = $true
        }

        $disposeFailed | Should Be $true
        $button.Checked | Should Be $false
        $button.Text | Should Be 'Play'
        $slider.Value | Should Be 0
        $slider.Enabled | Should Be $false
        $provider.DisposeCount | Should Be 1
    }

    It 'pauses and resumes playback without changing the current position' {
        $output = [pscustomobject]@{ PauseCount = 0; PlayCount = 0 }
        $output | Add-Member ScriptMethod Pause { $this.PauseCount++ }
        $output | Add-Member ScriptMethod Play { $this.PlayCount++ }
        $button = [pscustomobject]@{ IsDisposed = $false; Checked = $true; Text = 'Pause' }
        $script:trackPlayButtons['track.mp3'] = $button
        $script:playbacks['track.mp3'] = @{
            Output = $output
            IsPaused = $false
            Reader = [pscustomobject]@{ CurrentTime = [TimeSpan]::FromSeconds(42) }
        }

        Pause-TrackPlayback -Path 'track.mp3'

        $script:playbacks['track.mp3'].IsPaused | Should Be $true
        $button.Checked | Should Be $false
        $button.Text | Should Be 'Play'
        $script:playbacks['track.mp3'].Reader.CurrentTime.TotalSeconds | Should Be 42

        Resume-TrackPlayback -Path 'track.mp3'

        $script:playbacks['track.mp3'].IsPaused | Should Be $false
        $button.Checked | Should Be $true
        $button.Text | Should Be 'Pause'
        $script:playbacks['track.mp3'].Reader.CurrentTime.TotalSeconds | Should Be 42
        $output.PauseCount | Should Be 1
        $output.PlayCount | Should Be 1
    }

    It 'sets the start offset to the current track position' {
        $script:playbacks['track.mp3'] = @{
            Reader = [pscustomobject]@{ CurrentTime = [TimeSpan]::FromMilliseconds(65042) }
            Duration = [TimeSpan]::FromSeconds(180)
        }
        $script:trackDurations['track.mp3'] = [TimeSpan]::FromSeconds(180)
        $script:trackOffsets['track.mp3'] = @{ StartTimeMs = 0; EndTimeMs = 180000 }
        $timestamp = [pscustomobject]@{ Text = '00:00' }

        Set-TrackOffsetToNow -Path 'track.mp3' -OffsetType Start -OffsetControl $timestamp

        $script:trackOffsets['track.mp3'].StartTimeMs | Should Be 65042
        $timestamp.Text | Should Be '01:05.042'
    }

    It 'sets the end timestamp to the current track position' {
        $script:playbacks['track.mp3'] = @{
            Reader = [pscustomobject]@{ CurrentTime = [TimeSpan]::FromMilliseconds(125300) }
            Duration = [TimeSpan]::FromSeconds(180)
        }
        $script:trackDurations['track.mp3'] = [TimeSpan]::FromSeconds(180)
        $script:trackOffsets['track.mp3'] = @{ StartTimeMs = 0; EndTimeMs = 180000 }
        $timestamp = [pscustomobject]@{ Text = '03:00' }

        Set-TrackOffsetToNow -Path 'track.mp3' -OffsetType End -OffsetControl $timestamp

        $script:trackOffsets['track.mp3'].EndTimeMs | Should Be 125300
        $timestamp.Text | Should Be '02:05.300'
    }

    It 'formats and parses mm:ss, hh:mm:ss, and optional milliseconds' {
        (Format-TrackTimestamp -Time ([TimeSpan]::FromMinutes(1))) | Should Be '01:00'
        (Format-TrackTimestamp -Time ([TimeSpan]::FromMilliseconds(125300))) | Should Be '02:05.300'
        (Format-TrackTimestamp -Time ([TimeSpan]::FromMilliseconds(3723004))) | Should Be '01:02:03.004'
        (ConvertFrom-TrackTimestamp -Timestamp '02:05.3') | Should Be 125300
        (ConvertFrom-TrackTimestamp -Timestamp '01:02:03.004') | Should Be 3723004
    }

    It 'normalizes an edited timestamp and stores its absolute position' {
        $script:trackDurations['track.mp3'] = [TimeSpan]::FromMinutes(3)
        $script:trackOffsets['track.mp3'] = @{ StartTimeMs = 0; EndTimeMs = 180000 }
        $timestamp = [pscustomobject]@{ Text = '2:5.3' }

        Set-TrackTimestampControl `
            -Path 'track.mp3' `
            -TimestampType End `
            -TimestampControl $timestamp

        $timestamp.Text | Should Be '02:05.300'
        $script:trackOffsets['track.mp3'].EndTimeMs | Should Be 125300
    }

    It 'updates the seek range and current-versus-total time display' {
        $slider = [pscustomobject]@{
            IsDisposed = $false
            Minimum = 0
            Maximum = 1
            Value = 0
            Enabled = $false
        }
        $label = [pscustomobject]@{ IsDisposed = $false; Text = '' }
        $script:trackProgressSliders['track.mp3'] = $slider
        $script:trackTimeLabels['track.mp3'] = $label
        $playback = @{
            Reader = [pscustomobject]@{ CurrentTime = [TimeSpan]::FromSeconds(90) }
            StartTime = [TimeSpan]::FromSeconds(65)
            EndTime = [TimeSpan]::FromSeconds(150)
            Duration = [TimeSpan]::FromSeconds(180)
            UpdatingProgress = $false
        }

        Update-TrackPlaybackProgress -Path 'track.mp3' -Playback $playback

        $slider.Minimum | Should Be 0
        $slider.Maximum | Should Be 180000
        $slider.Value | Should Be 90000
        $slider.Enabled | Should Be $true
        $label.Text | Should Be '1:30 / 3:00'
    }

    It 'loads and displays track duration before playback and disposes the reader' {
        $reader = [pscustomobject]@{
            TotalTime = [TimeSpan]::FromSeconds(125)
            DisposeCount = 0
        }
        $reader | Add-Member ScriptMethod Dispose { $this.DisposeCount++ }
        $script:testDurationReader = $reader
        $script:requestedReaderPath = $null
        $readerFactory = {
            param($ReaderPath)
            $script:requestedReaderPath = $ReaderPath
            $script:testDurationReader
        }
        $label = [pscustomobject]@{ Text = '' }
        $slider = [pscustomobject]@{ Minimum = 0; Maximum = 1; Value = 0 }

        $duration = Get-TrackDuration -Path 'track.mp3' -ReaderFactory $readerFactory
        Set-TrackDurationControls `
            -Path 'track.mp3' `
            -Duration $duration `
            -TimeLabel $label `
            -ProgressSlider $slider

        $script:requestedReaderPath | Should Be 'track.mp3'
        $reader.DisposeCount | Should Be 1
        $label.Text | Should Be '0:00 / 2:05'
        $slider.Maximum | Should Be 125000
        $slider.Value | Should Be 0
        $script:trackDurations['track.mp3'] | Should Be ([TimeSpan]::FromSeconds(125))
    }

    It 'allows seeking outside configured offsets while retaining the full-track progress range' {
        $script:trackVolumes['track.mp3'] = 100
        $slider = [pscustomobject]@{
            IsDisposed = $false
            Minimum = 0
            Maximum = 180000
            Value = 65000
            Enabled = $true
        }
        $label = [pscustomobject]@{ IsDisposed = $false; Text = '' }
        $script:trackProgressSliders['track.mp3'] = $slider
        $script:trackTimeLabels['track.mp3'] = $label
        $playback = @{
            Reader = [pscustomobject]@{ CurrentTime = [TimeSpan]::FromSeconds(65) }
            StartTime = [TimeSpan]::FromSeconds(65)
            ConfiguredEndTime = [TimeSpan]::FromSeconds(150)
            EndTime = [TimeSpan]::FromSeconds(150)
            Duration = [TimeSpan]::FromSeconds(180)
            FadeInMs = 0
            FadeOutMs = 0
            UpdatingProgress = $false
            VolumeProvider = [pscustomobject]@{ Volume = 0.0 }
        }
        $script:playbacks['track.mp3'] = $playback

        Seek-TrackPlayback -Path 'track.mp3' -PositionMs 165000

        $playback.Reader.CurrentTime.TotalMilliseconds | Should Be 165000
        $playback.EndTime | Should Be ([TimeSpan]::FromSeconds(180))
        $slider.Minimum | Should Be 0
        $slider.Maximum | Should Be 180000
        $slider.Value | Should Be 165000

        Seek-TrackPlayback -Path 'track.mp3' -PositionMs 120000

        $playback.Reader.CurrentTime.TotalMilliseconds | Should Be 120000
        $playback.EndTime | Should Be ([TimeSpan]::FromSeconds(150))

        Seek-TrackPlayback -Path 'track.mp3' -PositionMs 30000

        $playback.Reader.CurrentTime.TotalMilliseconds | Should Be 30000
        $playback.EndTime | Should Be ([TimeSpan]::FromSeconds(180))
    }

    It 'saves per-track settings with a SHA-256 hash and device IDs' {
        $trackPath = Join-Path $script:tracksPath 'renamed.mp3'
        Set-Content -LiteralPath $trackPath -Value 'audio bytes'
        $script:audioDevices = @(
            [pscustomobject]@{ ID = 'device-default' },
            [pscustomobject]@{ ID = 'device-specific' }
        )
        $script:deviceMasterSliders = @(
            [pscustomobject]@{ Value = 75 },
            [pscustomobject]@{ Value = 40 }
        )
        $script:defaultDeviceIndex = 0
        $track = [pscustomobject]@{
            Path = $trackPath
            DevicePicker = [pscustomobject]@{ SelectedIndex = 2 }
            VolumeSlider = [pscustomobject]@{ Value = 35 }
            FadeInInput = [pscustomobject]@{ Value = 500 }
            FadeOutInput = [pscustomobject]@{ Value = 1200 }
            StartTimeInput = [pscustomobject]@{ Text = '01:05' }
            EndTimeInput = [pscustomobject]@{ Text = '02:05.300' }
        }
        $script:trackDurations[$trackPath] = [TimeSpan]::FromSeconds(180)
        $script:trackPanel.Controls = @([pscustomobject]@{ Tag = $track })

        $settings = Get-TrackSettingsSnapshot
        $savedTrack = $settings.Tracks[0]

        $settings.Version | Should Be 2
        $settings.WindowWidth | Should Be 1450
        $settings.WindowHeight | Should Be 700
        $settings.DefaultDeviceId | Should Be 'device-default'
        $settings.DeviceVolumes.Count | Should Be 2
        $settings.DeviceVolumes[1].Volume | Should Be 40
        $savedTrack.FileName | Should Be 'renamed.mp3'
        $savedTrack.Sha256 | Should Be (Get-FileHash -LiteralPath $trackPath -Algorithm SHA256).Hash
        $savedTrack.DeviceId | Should Be 'device-specific'
        $savedTrack.Volume | Should Be 35
        $savedTrack.FadeInMs | Should Be 500
        $savedTrack.FadeOutMs | Should Be 1200
        $savedTrack.StartTimeMs | Should Be 65000
        $savedTrack.EndTimeMs | Should Be 125300
    }

    It 'omits the end timestamp when it matches the track duration' {
        $trackPath = Join-Path $script:tracksPath 'full-length.mp3'
        Set-Content -LiteralPath $trackPath -Value 'audio bytes'
        $duration = [TimeSpan]::FromMilliseconds(125300)
        $script:trackDurations[$trackPath] = $duration
        $track = [pscustomobject]@{
            Path = $trackPath
            DevicePicker = [pscustomobject]@{ SelectedIndex = 0 }
            VolumeSlider = [pscustomobject]@{ Value = 50 }
            FadeInInput = [pscustomobject]@{ Value = 0 }
            FadeOutInput = [pscustomobject]@{ Value = 0 }
            StartTimeInput = [pscustomobject]@{ Text = '00:00' }
            EndTimeInput = [pscustomobject]@{ Text = '02:05.300' }
        }
        $script:trackPanel.Controls = @([pscustomobject]@{ Tag = $track })

        $savedTrack = (Get-TrackSettingsSnapshot).Tracks[0]

        $savedTrack.StartTimeMs | Should Be 0
        $savedTrack.PSObject.Properties['EndTimeMs'] | Should Be $null
    }

    It 'writes settings to the selected path and remembers that path for future saves' {
        $script:trackPanel.Controls = @()
        $script:audioDevices = @()
        $script:deviceMasterSliders = @()
        $script:defaultDeviceIndex = -1
        $path = Join-Path $script:testRoot 'custom-settings.json'

        Save-TrackSettings -Path $path

        $script:lastSettingsPath | Should Be $path
        (Test-Path -LiteralPath $path -PathType Leaf) | Should Be $true
        $savedSettings = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $path -Raw)
        $savedSettings.Version | Should Be 2
        $savedSettings.Tracks.Count | Should Be 0
    }

    It 'restores settings to a renamed track by matching its hash' {
        $trackPath = Join-Path $script:tracksPath 'current-name.mp3'
        Set-Content -LiteralPath $trackPath -Value 'same audio content'
        $hash = (Get-FileHash -LiteralPath $trackPath -Algorithm SHA256).Hash
        $script:audioDevices = @([pscustomobject]@{ ID = 'device-one' })
        $script:deviceMasterSliders = @([pscustomobject]@{ Value = 100 })
        $script:defaultDeviceRadios = @([pscustomobject]@{ Checked = $false })
        $script:trackDeviceSelections = @{}
        $track = [pscustomobject]@{
            Path = $trackPath
            DevicePicker = [pscustomobject]@{ SelectedIndex = 0 }
            VolumeSlider = [pscustomobject]@{ Value = 50 }
            FadeInInput = [pscustomobject]@{ Value = 0 }
            FadeOutInput = [pscustomobject]@{ Value = 0 }
            StartTimeInput = [pscustomobject]@{ Text = '00:00' }
            EndTimeInput = [pscustomobject]@{ Text = '03:00' }
        }
        $script:trackDurations[$trackPath] = [TimeSpan]::FromSeconds(180)
        $script:trackOffsets[$trackPath] = @{ StartTimeMs = 0; EndTimeMs = 180000 }
        $script:trackPanel.Controls = @([pscustomobject]@{ Tag = $track })
        $settings = [pscustomobject]@{
            Version = 2
            DefaultDeviceId = 'device-one'
            DeviceVolumes = @([pscustomobject]@{ DeviceId = 'device-one'; Volume = 42 })
            Tracks = @([pscustomobject]@{
                FileName = 'old-name.mp3'
                Sha256 = $hash
                DeviceId = 'device-one'
                Volume = 33
                FadeInMs = 800
                FadeOutMs = 900
                StartTimeMs = 65000
                EndTimeMs = 150000
            })
        }

        Apply-TrackSettings -Settings $settings

        $track.VolumeSlider.Value | Should Be 33
        $track.FadeInInput.Value | Should Be 800
        $track.FadeOutInput.Value | Should Be 900
        $track.StartTimeInput.Text | Should Be '01:05'
        $track.EndTimeInput.Text | Should Be '02:30'
        $track.DevicePicker.SelectedIndex | Should Be 1
        $script:trackDeviceSelections[$trackPath] | Should Be 1
        $script:deviceMasterSliders[0].Value | Should Be 42
        $script:defaultDeviceRadios[0].Checked | Should Be $true
    }

    It 'ignores saved tracks that are not present' {
        $script:trackPanel.Controls = @()
        $settings = [pscustomobject]@{
            Version = 2
            DefaultDeviceId = $null
            DeviceVolumes = @()
            Tracks = @([pscustomobject]@{
                FileName = 'missing.mp3'
                Sha256 = 'not-a-current-hash'
                DeviceId = $null
                Volume = 20
                FadeInMs = 10
                FadeOutMs = 10
            })
        }

        { Apply-TrackSettings -Settings $settings } | Should Not Throw
    }

    It 'restores valid window dimensions from settings' {
        $settings = [pscustomobject]@{
            Version = 2
            Tracks = @()
            WindowWidth = 1600
            WindowHeight = 900
        }

        Apply-TrackSettings -Settings $settings

        $script:mainForm.ClientSize.Width | Should Be 1600
        $script:mainForm.ClientSize.Height | Should Be 900
    }

    It 'resets track controls and device master levels to startup defaults' {
        $track = [pscustomobject]@{
            VolumeSlider = [pscustomobject]@{ Value = 8 }
            FadeInInput = [pscustomobject]@{ Value = 100 }
            FadeOutInput = [pscustomobject]@{ Value = 200 }
            Path = 'track.mp3'
            StartTimeInput = [pscustomobject]@{ Text = '00:00.300' }
            EndTimeInput = [pscustomobject]@{ Text = '00:00.400' }
            DevicePicker = [pscustomobject]@{ SelectedIndex = 2 }
        }
        $script:trackDurations['track.mp3'] = [TimeSpan]::FromMinutes(3)
        $script:trackOffsets['track.mp3'] = @{ StartTimeMs = 300; EndTimeMs = 400 }
        $script:trackPanel.Controls = @([pscustomobject]@{ Tag = $track })
        $script:deviceMasterSliders = @([pscustomobject]@{ Tag = 0; Value = 10 })
        $script:initialDeviceVolumes = @(64)
        $script:defaultDeviceRadios = @(
            [pscustomobject]@{ Checked = $false },
            [pscustomobject]@{ Checked = $true }
        )

        Reset-TrackSettings

        $track.VolumeSlider.Value | Should Be 50
        $track.FadeInInput.Value | Should Be 0
        $track.FadeOutInput.Value | Should Be 0
        $track.StartTimeInput.Text | Should Be '00:00'
        $track.EndTimeInput.Text | Should Be '03:00'
        $track.DevicePicker.SelectedIndex | Should Be 0
        $script:deviceMasterSliders[0].Value | Should Be 64
        $script:defaultDeviceRadios[0].Checked | Should Be $true
    }

    It 'rejects settings with an unsupported version or missing track list' {
        $unsupported = [pscustomobject]@{ Version = 99; Tracks = @() }
        $unsupportedRejected = $false
        try {
            Apply-TrackSettings -Settings $unsupported
        }
        catch {
            $unsupportedRejected = $true
        }
        $unsupportedRejected | Should Be $true

        $legacySettings = [pscustomobject]@{ Version = 1; Tracks = @() }
        $legacyRejected = $false
        try {
            Apply-TrackSettings -Settings $legacySettings
        }
        catch {
            $legacyRejected = $true
        }
        $legacyRejected | Should Be $true

        $missingTracks = [pscustomobject]@{ Version = 2 }
        $missingTrackListRejected = $false
        try {
            Apply-TrackSettings -Settings $missingTracks
        }
        catch {
            $missingTrackListRejected = $true
        }
        $missingTrackListRejected | Should Be $true
    }
}
