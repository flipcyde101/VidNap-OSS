# VidNap desktop preview

The desktop preview runs a Windows PowerShell worker behind a loopback-only Node.js interface. It keeps application data, temporary media, logs, downloads, and transcript exports in explicit private folders on D:. It does not fall back to C: or OneDrive.

- Analyze links before downloading. Up to two queue items can run independently.
- The meter shows the combined video and audio transfer when both totals are known. Estimated and unknown totals do not produce an exact percentage. If only current-stream counters can be identified, the display labels them accordingly.
- A download is marked saved only after output verification and the final no-overwrite move. The saved size comes from the file on disk. Export selection and source-quality behavior are unchanged by the progress update.
- Browser sign-in is off by default and requires consent for each operation. Source captions and local transcript generation are separate operations; generation requires a configured and approved local transcription engine and model.

## Development prerequisites

- Windows with Windows PowerShell 5.1 and an existing Node.js runtime.
- An existing, private, owner-approved D: QA folder with a `vidnap-qa-root.json` marker.
- Existing managed engine files on D: with a schema 3 `install-manifest.json` and matching hashes. The preview does not install or update the tools.
- An existing development signer approved for use on the test machine. Supply its public certificate thumbprint and SHA-256 certificate digest. The harness does not create certificates, enroll trust, or change Windows policy.

From a PowerShell development session, replace the example paths and public certificate identifiers with approved values:

```powershell
$qa = 'D:\VidNap-QA'
$tools = 'D:\VidNap-Tools'
$signer = @{ SignerThumbprint = '<40 hex characters>'; SignerCertificateSha256 = '<64 hex characters>' }
Import-Module Microsoft.PowerShell.Security
$env:PSModulePath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules'
.\Prepare-Preview.ps1 -SourceRoot $PWD.Path -QaRoot $qa -EngineDirectory $tools @signer
```

The command writes an isolated signed app and prints the path to `preview-config.json`. Start the prepared `app\preview\server.mjs` with Node.js and that configuration path as its argument. Open only the loopback address printed by the server. This does not provision a Windows shortcut or expose the worker to a phone or network.

## Verification

Use the same approved D: folders and development session:

```powershell
.\Test-Backend.ps1 -SourceRoot $PWD.Path -Suite All -IncludeEngine -EngineDirectory $tools -QaRoot $qa @signer
.\Prepare-Preview.ps1 -SourceRoot $PWD.Path -QaRoot $qa -EngineDirectory $tools -TestOnly @signer
node --test tests/preview-model.test.mjs tests/preview-offline.test.mjs tests/preview-server.test.mjs
```

The backend engine checks transfer and merge generated media over loopback. They do not download from an external site or read browser sign-in. The manager tests use synthetic transcription fixtures and do not establish real inference. The legacy WPF release and its published downloads are separate from this branch.
