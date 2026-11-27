# VidNap 0.3.2 review build

Status: draft review only. No release publication or installed-copy update is implied.

- Evidence-based terminal status, literal percent output paths, and explicit browser sign-in consent.
- Setup Cancel and install commit use a first-writer-wins decision file. Cancellation stops only before commit; a committed install finishes safely.
- yt-dlp executable and checksums use one resolved release tag.
- Interrupted-install recovery restores missing tools only from one backup matching its own manifest hashes; ambiguous or invalid backups are retained.
- Packaging uses an exact Git commit and portable forward-slash ZIP entries; ignored local files stay excluded.
- UI title, packaging default, and rebuilt launcher identify version 0.3.2 (launcher 0.3.2.0).

Validation uses isolated fixtures, mocked downloads, offscreen UI, process lifecycle tests, and Git archive tests. This does not certify live-site compatibility, a clean-PC install, or interactive GUI behavior. Keep all runtime files together; the launcher does not work by itself.
