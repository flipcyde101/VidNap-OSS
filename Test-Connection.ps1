# A fixed non-media HTTPS check; does not test yt-dlp or any media website.
$ErrorActionPreference = 'Stop'
try {
    $response = Invoke-WebRequest -UseBasicParsing -Method Head -Uri 'https://www.microsoft.com/' -TimeoutSec 20
    Write-Output ('General Windows HTTPS check passed (HTTP {0}). This does not verify downloader or site-specific compatibility.' -f [int]$response.StatusCode)
} catch {
    Write-Output 'General Windows HTTPS check failed. This alone does not establish the cause of a downloader failure. No certificate or network settings were changed.'
    exit 1
}
