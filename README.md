# VidNap 0.3.2 (review build)

A Windows desktop app for saving video or audio that you own or are authorized to download.

## Project status

This repository contains a Windows desktop preview. Its download meter combines selected video and audio streams when their sizes are known. After verification and saving, it shows the file size on disk.

See [desktop preview setup and tests](docs/DESKTOP-PREVIEW.md). The preview requires a configured D: development environment. This source snapshot does not include an installable package, prebuilt launcher, or bundled offline transcription engine.

## License

VidNap's original source is licensed under the [MIT License](LICENSE). Third-party tools, libraries and models retain their own licenses. This license does not clear a bundle of those components for redistribution.

## Legacy Windows app

The legacy interface uses Windows PowerShell 5.1 and WPF. Build the launcher from the reviewed source as described below. Keep Windows protections enabled and use a build approved by your Windows application-control policy.

On first use, select **Install engine**. Setup and supported media downloads require an internet connection. Paste a media URL, choose Video or Audio and an export format, then select **Download**.

## Legacy quality and formats

| Choice | Behavior |
| --- | --- |
| Video: Best available | Keeps source codecs, merging best streams with FFmpeg. Without FFmpeg, selects a combined stream, which may be lower quality. |
| Video: MP4 compatible | Requires H.264/AAC sources and merges/remuxes to MP4. Fails clearly if unavailable. |
| Video: MKV | Merges or remuxes to MKV, retaining source codecs. |
| Video: WebM | Requires WebM source streams and produces WebM. Fails if unavailable. |
| Audio: Original codec | Downloads an audio-only source as provided, without extraction/transcoding. Fails if no audio-only source exists. |
| Audio: MP3, M4A/AAC, FLAC, WAV, Opus | Uses FFmpeg to extract/convert audio to your selected format. |

Conversion cannot restore detail missing from the source. FLAC lossless encoding does not make a lossy source lossless. Existing files are not overwritten. Partial files remain after cancellation for a later retry when supported.

In the legacy Windows release, the percentage describes the current stream. Separate audio/video streams and playlist items can restart that percentage; finishing and merging are shown separately.

Terminal status counts distinct output paths reported by the engine, including those reported before cancellation or failure. A reported file is not proof of a new download: it may already have been present. A successful exit with no reported file is shown explicitly rather than claiming media was saved.

VidNap escapes literal `%` characters in the destination portion of the engine's output-template argument, including names such as `%TEMP%`. This argument handling is unit/flow-tested, not live-download-tested. Folders containing `$` are rejected because the engine may expand dollar-sign variables.

## Legacy interface and alternate transfer

The activity card shows the actual phase, speed and ETA. Unknown values are labeled rather than guessed. **Reduce motion** disables the activity pulse and indeterminate animation, initially following your Windows animation preference. **Activity details** keeps diagnostics available without filling the main screen.

The optional **Alternate transfer** mode is a limited direct-file pilot using Windows curl. It accepts public HTTPS links directly to supported video files and saves the original bytes. It is not another webpage extractor or a universal fail-safe. Use Video / Best available, without browser sign-in, cookies, playlists or metadata embedding. FFprobe validates the downloaded file before completion. Redirects, local/private addresses, credentials and unsupported media are rejected; certificates are always verified. See [capabilities and limits](docs/FALLBACK-DESIGN.md).

Alternate attempts use a new isolated partial file rather than resuming a different engine's output. A cancellation can leave that attempt's partial file. No automatic engine switching occurs.

## Legacy browser sign-in

Open **Sign-in and download options** when needed. Select a browser and optionally enter a profile name/path. VidNap never force-closes a browser. If its database is locked, save your work and close it yourself before retrying. Chromium cookie protection may prevent access; keep browser security enabled. Firefox or a Netscape-format cookie file may work for supported sources.

A cookie file takes precedence over browser mode. The engine can update the selected cookie file. Treat it as a password. URLs, cookies, profile paths, and authentication enablement are not saved in preferences.

Changing the browser does not enable sign-in or clear a selected cookie file. Check **Use browser sign-in** explicitly to use the selected browser session.

With **Allow playlist** unchecked, VidNap limits the request to one item: the selected video, or the first entry for a playlist-only URL. Check it to allow the full playlist.

## Legacy storage and updates

Managed engines, preferences, and diagnostic logs live under `%LOCALAPPDATA%\VidNap`. **Update engine** installs yt-dlp nightly, FFmpeg release essentials, and Deno from their upstream release sources, verifies SHA256 digests before a staged update, and restores the previous directory if the commit fails. yt-dlp's release tag is resolved once; its checksum list and executable are fetched from that same tag. Unchanged FFmpeg is reused only after checking its upstream archive checksum and both installed binary hashes. Deno supplies the supported JavaScript runtime needed for YouTube; the official yt-dlp executable bundles its EJS scripts. No remote EJS component download is enabled.

Setup enables **Cancel** after acquiring its lock, resetting its decision file, and completing recovery. Cancel and install commit compete to create one decision file: if Cancel wins, setup can stop before replacing tools; if commit wins, the window waits for installation/rollback to finish. Temporary staging files left by cancellation are cleaned on the next setup through the guarded cleanup routine. Queued progress cannot override cancellation or finishing status.

On restart, setup restores missing `tools` only from exactly one backup whose tool files match its own manifest hashes. A hash-matching backup is a consistency check, not independent proof of authenticity. If backups are ambiguous or invalid, setup warns with their paths, preserves them untouched, and continues a fresh install. Keep retained backups for inspection. Interface or monitor errors cannot stop setup once install commit has won; the window keeps polling for completion.

The GUI prefers managed tools and otherwise resolves installed applications from PATH. Deno's selected path is passed explicitly to yt-dlp. A custom `Setup-VidNap.ps1 -ToolsDirectory` does not change the GUI's managed-tool root. See [v0.3.2 review-build changes](docs/RELEASE-0.3.2.md).

Logs are bounded and URL queries are redacted. Review diagnostics before sharing. The last destination, media type, format, and browser choice are saved locally. Development startup request files are no longer processed.

## Development and verification

The [Windows smoke workflow](.github/workflows/windows-smoke.yml) covers the legacy regression suites, launcher build and offscreen interface initialization on its CI runner. For local checks, follow your normal Windows execution policy and do not weaken protections to run a blocked test. These checks do not validate the current offline transcription package, live sites or a clean-machine setup.

Run `Build-Launcher.ps1` explicitly to build a local launcher. The Windows packaging workflow requires a separately reviewed release commit that includes the version-matched launcher. Run `Build-Release.ps1` on that clean commit to create the Windows ZIP, source archive, and checksums. It uses `git archive`, does not rebuild the launcher, and records exact file hashes. A local build is not a signed or Windows-trusted release. Keep all files in a Windows ZIP together.

Live-site compatibility, clean-PC installation, actual media codec checks, and interactive high-DPI/accessibility behavior need separate testing. Site support is provided by yt-dlp and can change independently. Some sites require additional supported dependencies; engine-ready status confirms available binaries, not every URL.

VidNap does not bypass DRM, subscriptions, access controls, or site permissions.
