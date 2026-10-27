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
    'Update-TrackPlaybackProgress',
    'Seek-TrackPlayback',
    'Update-TrackPlaybackVolume',
    'Get-TrackFiles',
    'Get-TrackSettingsSnapshot',
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
            StartOffset = [TimeSpan]::Zero
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
            StartOffset = [TimeSpan]::Zero
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
            StartOffset = [TimeSpan]::FromMilliseconds(65000)
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
        $offset = [pscustomobject]@{ Minimum = 0; Maximum = 3600000; Value = 0 }

        Set-TrackOffsetToNow -Path 'track.mp3' -OffsetType Start -OffsetControl $offset

        $offset.Value | Should Be 65042
    }

    It 'sets the end offset to the remaining time from the current track position' {
        $script:playbacks['track.mp3'] = @{
            Reader = [pscustomobject]@{ CurrentTime = [TimeSpan]::FromSeconds(65) }
            Duration = [TimeSpan]::FromSeconds(180)
        }
        $offset = [pscustomobject]@{ Minimum = 0; Maximum = 3600000; Value = 0 }

        Set-TrackOffsetToNow -Path 'track.mp3' -OffsetType End -OffsetControl $offset

        $offset.Value | Should Be 115000
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
            StartOffset = [TimeSpan]::FromSeconds(65)
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
            StartOffset = [TimeSpan]::FromSeconds(65)
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
            StartOffsetInput = [pscustomobject]@{ Value = 65000 }
            EndOffsetInput = [pscustomobject]@{ Value = 3000 }
        }
        $script:trackPanel.Controls = @([pscustomobject]@{ Tag = $track })

        $settings = Get-TrackSettingsSnapshot
        $savedTrack = $settings.Tracks[0]

        $settings.Version | Should Be 1
        $settings.DefaultDeviceId | Should Be 'device-default'
        $settings.DeviceVolumes.Count | Should Be 2
        $settings.DeviceVolumes[1].Volume | Should Be 40
        $savedTrack.FileName | Should Be 'renamed.mp3'
        $savedTrack.Sha256 | Should Be (Get-FileHash -LiteralPath $trackPath -Algorithm SHA256).Hash
        $savedTrack.DeviceId | Should Be 'device-specific'
        $savedTrack.Volume | Should Be 35
        $savedTrack.FadeInMs | Should Be 500
        $savedTrack.FadeOutMs | Should Be 1200
        $savedTrack.StartOffsetMs | Should Be 65000
        $savedTrack.EndOffsetMs | Should Be 3000
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
            StartOffsetInput = [pscustomobject]@{ Value = 0 }
            EndOffsetInput = [pscustomobject]@{ Value = 0 }
        }
        $script:trackPanel.Controls = @([pscustomobject]@{ Tag = $track })
        $settings = [pscustomobject]@{
            Version = 1
            DefaultDeviceId = 'device-one'
            DeviceVolumes = @([pscustomobject]@{ DeviceId = 'device-one'; Volume = 42 })
            Tracks = @([pscustomobject]@{
                FileName = 'old-name.mp3'
                Sha256 = $hash
                DeviceId = 'device-one'
                Volume = 33
                FadeInMs = 800
                FadeOutMs = 900
                StartOffsetMs = 65000
                EndOffsetMs = 3000
            })
        }

        Apply-TrackSettings -Settings $settings

        $track.VolumeSlider.Value | Should Be 33
        $track.FadeInInput.Value | Should Be 800
        $track.FadeOutInput.Value | Should Be 900
        $track.StartOffsetInput.Value | Should Be 65000
        $track.EndOffsetInput.Value | Should Be 3000
        $track.DevicePicker.SelectedIndex | Should Be 1
        $script:trackDeviceSelections[$trackPath] | Should Be 1
        $script:deviceMasterSliders[0].Value | Should Be 42
        $script:defaultDeviceRadios[0].Checked | Should Be $true
    }

    It 'loads older track settings without offset fields as zero offsets' {
        $trackPath = Join-Path $script:tracksPath 'legacy.mp3'
        Set-Content -LiteralPath $trackPath -Value 'legacy audio content'
        $hash = (Get-FileHash -LiteralPath $trackPath -Algorithm SHA256).Hash
        $track = [pscustomobject]@{
            Path = $trackPath
            DevicePicker = [pscustomobject]@{ SelectedIndex = 0 }
            VolumeSlider = [pscustomobject]@{ Value = 50 }
            FadeInInput = [pscustomobject]@{ Value = 0 }
            FadeOutInput = [pscustomobject]@{ Value = 0 }
            StartOffsetInput = [pscustomobject]@{ Value = 300 }
            EndOffsetInput = [pscustomobject]@{ Value = 400 }
        }
        $script:trackPanel.Controls = @([pscustomobject]@{ Tag = $track })
        $settings = [pscustomobject]@{
            Version = 1
            Tracks = @([pscustomobject]@{
                FileName = 'legacy.mp3'
                Sha256 = $hash
                Volume = 50
                FadeInMs = 0
                FadeOutMs = 0
            })
        }

        Apply-TrackSettings -Settings $settings

        $track.StartOffsetInput.Value | Should Be 0
        $track.EndOffsetInput.Value | Should Be 0
    }

    It 'ignores saved tracks that are not present' {
        $script:trackPanel.Controls = @()
        $settings = [pscustomobject]@{
            Version = 1
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

    It 'resets track controls and device master levels to startup defaults' {
        $track = [pscustomobject]@{
            VolumeSlider = [pscustomobject]@{ Value = 8 }
            FadeInInput = [pscustomobject]@{ Value = 100 }
            FadeOutInput = [pscustomobject]@{ Value = 200 }
            StartOffsetInput = [pscustomobject]@{ Value = 300 }
            EndOffsetInput = [pscustomobject]@{ Value = 400 }
            DevicePicker = [pscustomobject]@{ SelectedIndex = 2 }
        }
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
        $track.StartOffsetInput.Value | Should Be 0
        $track.EndOffsetInput.Value | Should Be 0
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

        $missingTracks = [pscustomobject]@{ Version = 1 }
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
