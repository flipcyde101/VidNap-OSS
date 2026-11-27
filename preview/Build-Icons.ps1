[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
if($Destination -notmatch '^D:\\' -or -not [IO.Directory]::Exists($Destination)){throw 'Existing D: icon output is required.'}
Add-Type -AssemblyName System.Drawing
foreach($spec in @(@('icon-192.png',192),@('icon-512.png',512),@('apple-touch-icon.png',180))){
    $target=Join-Path $Destination $spec[0]
    if([IO.File]::Exists($target)){throw 'Generated icon output already exists; it was preserved.'}
    $size=[int]$spec[1];$bitmap=[Drawing.Bitmap]::new($size,$size);$g=[Drawing.Graphics]::FromImage($bitmap)
    $pen=[Drawing.Pen]::new([Drawing.Color]::White,[single]($size/16))
    try {
        $g.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias;$g.Clear([Drawing.ColorTranslator]::FromHtml('#0068d9'))
        $pen.StartCap=[Drawing.Drawing2D.LineCap]::Round;$pen.EndCap=[Drawing.Drawing2D.LineCap]::Round;$pen.LineJoin=[Drawing.Drawing2D.LineJoin]::Round
        $s=$size/64.0
        $g.DrawLine($pen,[single](32*$s),[single](15*$s),[single](32*$s),[single](42*$s))
        $g.DrawLines($pen,[Drawing.PointF[]]@([Drawing.PointF]::new(21*$s,31*$s),[Drawing.PointF]::new(32*$s,42*$s),[Drawing.PointF]::new(43*$s,31*$s)))
        $g.DrawLines($pen,[Drawing.PointF[]]@([Drawing.PointF]::new(17*$s,46*$s),[Drawing.PointF]::new(17*$s,51*$s),[Drawing.PointF]::new(47*$s,51*$s),[Drawing.PointF]::new(47*$s,46*$s)))
        $bitmap.Save($target,[Drawing.Imaging.ImageFormat]::Png)
    }finally{$pen.Dispose();$g.Dispose();$bitmap.Dispose()}
}
# Provenance: deterministic rasterization of the project's authored geometric
# download mark, matching preview/web/icons/icon.svg. No stock or generated image.
