# Contributing to VidNap

Keep VidNap focused on media that users own or are authorized to download. Preserve source quality unless the user chooses conversion. Do not add DRM circumvention, access-control bypasses, credential collection, or cookie persistence.

The [Windows smoke workflow](.github/workflows/windows-smoke.yml) runs regression tests and builds the legacy launcher in CI. Test locally under your normal Windows PowerShell policy. If a legacy runner or launcher is blocked, do not change policy to run it; report which checks could not run.

Legacy tests use fixtures and offscreen XAML rendering. Follow the [desktop preview guide](docs/DESKTOP-PREVIEW.md) for its separate development prerequisites. Interactive app, installer, speech and live download tests need a separate controlled session. Describe which validation actually ran.

Keep pure format/progress functions in VidNap.Core.ps1 and process lifetime management in VidNap.ProcessRunner.cs. UI code must not wait synchronously for engines.

Submit focused changes for review. Never include cookies, browser profiles, downloaded media, local runtime state, model weights, or logs in a contribution. Review third-party licenses and provenance before adding dependencies. Build-Release.ps1 uses explicit inclusion lists for legacy packages. Merging source and publishing a package are separate decisions.
Develop in a local, non-synced workspace. Keep private files out of Git; ignored working-tree files are excluded from packages. Build-Release.ps1 archives a resolved Git commit and uses an explicit inclusion list for the Windows package.
