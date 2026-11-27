# Security policy

## Reporting a vulnerability

Please report security vulnerabilities privately through GitHub's **Security advisories** tab instead of opening a public issue. Include the affected VidNap version, reproduction steps, and expected impact.

## Security boundaries

VidNap delegates supported-site extraction to yt-dlp and local media processing to FFmpeg. It does not bypass DRM, subscriptions, regional controls, CAPTCHAs, or site permissions.

Cookie files and browser-session data are credentials. VidNap passes a selected cookie-file path to yt-dlp; yt-dlp may update that file. VidNap does not save cookie paths or browser profiles in preferences. Never attach cookies or account credentials to an issue.

The engine ignores ambient yt-dlp configuration and plugins. Startup request-file automation is disabled. Downloads use HTTPS upstream checksums; these are integrity checks, not independent protection against an upstream compromise. Engine binaries are trusted code run with the user's permissions.

Setup also installs Deno from the official denoland/deno GitHub release, requiring the exact Windows x64 archive URL and the release API's SHA256 digest before extraction. The selected Deno path is passed explicitly to yt-dlp; remote EJS downloads are not enabled. The official yt-dlp executable bundles EJS. Deno's challenge-execution permissions are controlled by yt-dlp, not a VidNap-wide sandbox.

The Windows Job Object runner manages a trusted process tree and is not a sandbox. There is a brief process-start-to-job-assignment race. Logs are bounded and redact URL queries, but users should inspect diagnostics before sharing. Local paths and error context may remain.

The alternate transfer pilot is opt-in and does not extract webpages. It uses the system curl executable with ambient configuration/proxies disabled and public DNS addresses pinned, refuses redirects and credential-bearing URLs, and verifies certificates. It downloads into an attempt-owned partial file, validates supported video content with the installed FFprobe, and only then promotes the output without replacing existing files. This is a limited direct-file transport, not a browser, access-control workaround or universal fallback. Parser/tool dependencies remain trusted native code; keep them updated and do not treat the process runner as a security sandbox.
