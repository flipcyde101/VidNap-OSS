param([Parameter(Mandatory=$true)][string]$Configuration)
$stop=Join-Path ([IO.Path]::GetDirectoryName($Configuration)) 'fixture-worker-stop'
[IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($Configuration)) 'fixture-worker-started'),'started')
while(-not [IO.File]::Exists($stop)){[Threading.Thread]::Sleep(50)}
