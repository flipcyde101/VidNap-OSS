# Download reliability: secondary transport design

Status: a bounded direct-file pilot is implemented in `VidNap.Alternate.ps1`; broader extracted-media fallback remains a design. No dependency is installed by this feature. This is general reliability for media the user owns or is authorized to download, not a promise to restore any particular website. Access restrictions, DRM and unsupported sources remain stop conditions.

Implemented pilot: the user explicitly selects Alternate transfer and supplies a public direct HTTPS video URL ending in `.mp4`, `.webm`, `.mkv` or `.mov`. It does not fetch website pages or extract metadata. It rejects query strings, fragments, embedded credentials, redirects and non-public IPv4 results, pins the selected address, disables curl configuration/proxy inheritance and URL globbing, and requires system curl 8.4.0 or newer plus installed FFprobe. Transfers are limited to 1 GB and ten minutes, with a 1.125 GB free-space preflight. Progress reports bytes with unknown total. FFprobe checks a local standalone video stream before a unique output is committed. This preserves source bytes; it does not discover a higher-quality version. Cancelled/failed attempt-owned partial files can remain and are never silently resumed by another engine.

## Future extracted-media extension (not implemented)

Keep yt-dlp as the extractor and primary downloader. First improve recovery visibility and bounded retry. Pilot **curl as an optional direct-HTTPS transport** only after successful extraction, using a verified executable and public, unencrypted, single-file fixtures. Do not advertise a universal fail-safe.

Extraction discovers metadata and playable formats from a page; transport retrieves selected bytes; processing merges/remuxes/converts those bytes. A different transport cannot repair a webpage extraction failure. A different TLS implementation might behave differently, but no improvement is established until tested on an authorized source.

| Candidate | Practical role | Decision |
| --- | --- | --- |
| yt-dlp native retry | Retry transient extraction/transfer failures using the existing integration | First phase; retain finite attempt budgets and cancellation |
| curl | Alternate transfer of a resolved direct HTTPS file; not a website extractor | Smallest proposed pilot; capability/version check required |
| aria2c | Another transfer backend, including segmented downloading | Defer: extra installation, resume metadata and concurrency surface; not independent extraction |
| FFmpeg | Network media input and existing merge/remux/conversion role | Keep current processing role; defer alternate streaming transport until protocol/quality tests exist |

yt-dlp documents protocol-selective external downloader support and retry settings. That makes retaining its extraction and format selection preferable to introducing an unrelated site-support stack. [Official yt-dlp options](https://github.com/yt-dlp/yt-dlp#download-options)

curl supports URL transfers, finite retries, redirect/protocol limits and certificate verification controls. The design must capability-check the installed version rather than assume the latest manual matches Windows' bundled executable. [Official curl manual](https://curl.se/docs/manpage.html)

aria2 documents segmented transfers and its own control files; FFmpeg documents stream copying separately from transcoding. Neither is a drop-in guarantee of identical resume, progress or output behavior. [Official aria2 manual](https://aria2.github.io/manual/en/html/aria2c.html), [Official FFmpeg documentation](https://ffmpeg.org/ffmpeg.html#Streamcopy)

## Proposed extension eligibility and user experience

- Default remains **Standard download**. No silent engine switch, background dependency install, or automatic repeated downloads.
- After a classified transfer failure, show **Retry standard** and, only when capability checks pass, **Try alternate transfer**. Explain that it retries the same selected source; it does not find a lower-quality substitute.
- Disable alternate transfer for extraction/TLS-before-extraction failures, access-denied responses, authentication challenges, DRM, unsupported formats, HLS/DASH, live streams, playlists, separate audio/video streams, and processing failures in the pilot. Unknown stage means ineligible.
- Pilot accepts only a previously resolved, public, single-file HTTPS source without credentials, cookies, custom headers, or redirects. Later authenticated or redirected support requires separate privacy/security review and fixture coverage.
- Show stage, attempt number, actual engine, bytes, speed and ETA when known. Unknown length uses an indeterminate bar, never an invented percentage. Label per-stream progress accurately. Processing is not “100% complete”; completion requires validated output.
- Keep motion decorative: short transitions only; reduced-motion setting and keyboard/screen-reader-readable text remain available. Error explanation and retry actions must not depend on hovering.

## Adapter contract

Separate capability policy from process invocation. A future `DownloadRequest` carries an attempt ID, explicit consent, selected format identity, destination, transient resolved URL, retry/time budgets and output constraints. It must not contain an arbitrary shell command. Treat URL material as sensitive memory-only state.

An adapter provides `ProbeCapabilities`, `CanHandle(request)`, `Start(request)`, `Cancel(attemptId)` and bounded `DrainEvents`. Events contain attempt ID, monotonic sequence, engine, stage, byte counts, nullable total/speed/ETA, output path or sanitized error category. Ignore stale events from an older attempt. Use the existing process-tree runner rather than UI-thread waits.

State sequence:

`Idle -> Validating -> Extracting -> Transferring -> Processing -> Verifying -> Completed`

Failure moves to `Failed`; explicit retry moves through `Validating` with a new attempt ID. `Cancelling -> Cancelled` is terminal for that attempt. No automatic loop between engines. App-level retries must count engine-internal retries toward a documented maximum; never use infinite retry settings.

## Safety, quality and file handling

- Keep certificate verification enabled. No insecure flags, proxy rotation, fingerprint impersonation, credential harvesting, or access-control workarounds.
- Invoke verified absolute executable paths with tested argument quoting, no shell interpolation and no ambient downloader config/plugins. Restrict URL protocols; reject embedded credentials, local/private-network destinations, and redirects in the initial pilot. Validate DNS/address policy consistently at connection time before expanding this capability.
- Do not log resolved URLs, cookies, authorization headers or query tokens; record sanitized categories and engine versions. No persistent “history” of private URLs. No extra telemetry.
- Use separate attempt-owned partial files; never resume another engine's partial file blindly. Preserve originals. Commit the completed file without overwriting existing output, only after exit-code, file-size and media validation. Low disk space fails before starting when the required size is known; unknown size still needs a reserve check and clear disk-full recovery.
- Transfer must retain the exact selected bytes. Original-codec modes must not transcode. A requested container or codec incompatibility fails clearly rather than silently substituting another quality. Any future multi-stream pilot must compare selected stream IDs/codecs and verify final tracks with FFprobe.

## Acceptance gates and phases

1. **Recovery UI and policy (small, low risk):** stage-aware errors, explicit retry consent, engine badge and disabled alternate explanation. Unit tests cover eligibility/unknown stage, attempt budgets and stale-event rejection. Do not imply the alternate engine exists yet.
2. **Direct-file pilot (medium, medium risk):** implement the adapter behind a feature flag using controlled non-explicit fixtures. Test known/unknown length, interrupted transfer, failed certificate, HTTP errors, expired URL, redirect rejection, cancel/close descendant cleanup, existing destination, disk full, hostile arguments and secret redaction. Successful byte hash must match the fixture; errors must never appear as complete.
3. **Quality/runtime gate (medium, medium risk):** compare output hashes, FFprobe tracks and exact export promises; test Windows minimum version, missing/old tool, fresh install and actual keyboard/high-DPI/reduced-motion behavior. Independent Reviewer checks artifacts and Supervisor approves installation/publication evidence.
4. **Broader support only after evidence:** assess authenticated requests, redirects, multiple streams or aria2 separately. Publish an explicit capability matrix and tested engine versions. Do not relax eligibility merely to make a retry button available.

Initial evidence: 36 offline alternate policy/argument checks passed. Live-fixture results and independent review must be recorded separately; these unit checks do not establish site compatibility or a TLS fix. The extracted-media architecture described here is a future extension, not a capability of the direct-file pilot.
