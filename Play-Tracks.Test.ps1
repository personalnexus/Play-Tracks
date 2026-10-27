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
        $script:trackVolumes = @{}
        $script:trackFades = @{}
        $script:trackDeviceSelections = @{}
        $script:initialDeviceVolumes = @()
        $script:trackStatusLabels = @{}
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
            StartedAt = [DateTime]::UtcNow.AddMilliseconds(-250)
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
            StartedAt = [DateTime]::UtcNow.AddMilliseconds(-9500)
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

    It 'stops and disposes only the requested track playback and clears its status' {
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
        $script:trackStatusLabels['first.mp3'] = [pscustomobject]@{ Text = 'Playing...' }

        Stop-TrackPlayback -Path 'first.mp3'

        $script:playbacks.ContainsKey('first.mp3') | Should Be $false
        $script:playbacks.ContainsKey('second.mp3') | Should Be $true
        $output.StopCount | Should Be 1
        $output.DisposeCount | Should Be 1
        $provider.DisposeCount | Should Be 1
        $script:trackStatusLabels['first.mp3'].Text | Should Be ''
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
            })
        }

        Apply-TrackSettings -Settings $settings

        $track.VolumeSlider.Value | Should Be 33
        $track.FadeInInput.Value | Should Be 800
        $track.FadeOutInput.Value | Should Be 900
        $track.DevicePicker.SelectedIndex | Should Be 1
        $script:trackDeviceSelections[$trackPath] | Should Be 1
        $script:deviceMasterSliders[0].Value | Should Be 42
        $script:defaultDeviceRadios[0].Checked | Should Be $true
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
