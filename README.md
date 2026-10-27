# Track Player

Track Player is a Windows PowerShell desktop application for playing MP3 tracks from a local `Tracks` folder. It uses a Windows Forms interface and NAudio for playback.

## Requirements

- Windows with Windows PowerShell 5.1
- An active Windows audio playback device
- `NAudio.dll` beside `Play-Tracks.ps1` (NAudio 1.10.0, `lib\net35\NAudio.dll`)

The NAudio package is available from [NuGet](https://www.nuget.org/packages/NAudio/1.10.0). If the DLL is not already beside the script, download the package, extract it, and copy `lib\net35\NAudio.dll` into the application folder.

## Start the application

Keep the files together in one folder:

```text
Play-Tracks.ps1
Play-Tracks.DefaultSettings.json (optional, to load default settings at application start-up)
NAudio.dll
Tracks\
```

Add `.mp3` files directly inside `Tracks` (not in nested folders), then start the app from Windows PowerShell:

```powershell
powershell.exe -STA -File .\Play-Tracks.ps1
```

The application creates the `Tracks` sub-folder if it does not exist. It sorts tracks by filename and checks the folder periodically, adding new MP3s and removing buttons for files that have been deleted.

## Playback controls

- Each track has its own **Play** and **Stop** buttons. Different tracks can play at the same time; replaying a track stops and restarts that same track.
- Select **Default** on a track to route it to the playback device selected by the global radio button, or select a specific device for that track.
- The track volume slider defaults to 50%. It can be adjusted while the track is playing.
- **Fade-in (ms)** and **Fade-out (ms)** control the start and end volume ramps. Both default to zero (no fade).
- Each audio device has a master playback-volume slider. Its initial value is read from the device's current Windows endpoint volume; moving it controls the app's playback routed to that device.
- **Playing...** is shown while a track is playing.

## Settings

Use **Save Settings...** to write the current selections to a JSON file. The saved settings include:

- The selected default audio device and per-device master playback volumes
- Each track's device selection, track volume, fade-in, and fade-out values
- The track filename and SHA-256 hash

Use **Load Settings...** to apply a saved JSON file. Tracks are matched by content hash first, which allows settings to follow a track when it is renamed; the filename is used as a fallback. Settings for tracks that are not found are ignored. Audio devices are matched by their Windows device IDs; unavailable devices are skipped, and tracks whose selected device is unavailable use **Default**.

On startup, the app automatically applies `Play-Tracks.DefaultSettings.json` if it exists next to the script. If this file cannot be read or applied, the app displays an error.

**Reset to Defaults** restores track volumes to 50%, fade times to zero, track routing to **Default**, the first available device as the default, and device sliders to their levels from application startup.

## Tests

The Pester tests are in `Play-Tracks.Test.ps1`. Run them from this folder:

```powershell
Invoke-Pester -Script .\Play-Tracks.Test.ps1
```

The tests cover track discovery and ordering, playback volume and fade calculations, stopping individual tracks, settings save/load and renamed-track matching, missing tracks, reset behavior, and invalid settings.

When adding a feature or changing behavior, add or update tests and this documentation alongside the change. Follow the Chicago school of testing: focus tests on observable behavior and resulting state, using real collaborators where practical and test doubles only where external systems such as audio devices or the UI need isolation.
