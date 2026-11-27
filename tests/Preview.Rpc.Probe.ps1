param([string]$Configuration)
$ErrorActionPreference='Stop'
[Console]::Out.WriteLine('{"event":"ready"}')
while($null -ne ($line=[Console]::In.ReadLine())){
    $request=ConvertFrom-Json $line
    try {
        Get-Acl -LiteralPath $PSScriptRoot|Out-Null
        $value=@{loaded=$true;moduleBase=(Get-Module Microsoft.PowerShell.Security).ModuleBase}
    }catch{$value=@{loaded=$false;moduleBase=''}}
    [Console]::Out.WriteLine((@{id=$request.id;ok=$true;result=$value}|ConvertTo-Json -Compress))
}
