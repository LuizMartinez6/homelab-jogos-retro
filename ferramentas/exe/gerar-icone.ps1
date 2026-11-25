# Gera jogos.ico (16 a 256 px) com o mesmo visual do cabecalho do instalador:
# quadrado arredondado em degrade roxo/azul com o controle do Segoe MDL2 Assets.
# Uso: powershell -File gerar-icone.ps1

Add-Type -AssemblyName System.Drawing
$Saida = Join-Path $PSScriptRoot 'jogos.ico'
$tamanhos = 16, 24, 32, 48, 64, 128, 256
$pngs = foreach ($t in $tamanhos) {
    $bmp = New-Object Drawing.Bitmap $t, $t
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $r = [math]::Max(3, [int]($t * 0.27)); $d = 2 * $r
    $caminho = New-Object Drawing.Drawing2D.GraphicsPath
    $caminho.AddArc(0, 0, $d, $d, 180, 90); $caminho.AddArc($t - $d - 1, 0, $d, $d, 270, 90)
    $caminho.AddArc($t - $d - 1, $t - $d - 1, $d, $d, 0, 90); $caminho.AddArc(0, $t - $d - 1, $d, $d, 90, 90); $caminho.CloseFigure()
    $fundo = New-Object Drawing.Drawing2D.LinearGradientBrush ((New-Object Drawing.Point 0, 0), (New-Object Drawing.Point $t, $t), [Drawing.Color]::FromArgb(0x8B, 0x5C, 0xF6), [Drawing.Color]::FromArgb(0x4C, 0xC9, 0xF0))
    $g.FillPath($fundo, $caminho)
    $fonte = New-Object Drawing.Font 'Segoe MDL2 Assets', ([single]($t * 0.5)), ([Drawing.FontStyle]::Regular), ([Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString([string][char]0xE7FC, $fonte, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF 0, ([single]($t * 0.03)), $t, $t), $fmt)
    $g.Dispose()
    $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    , $ms.ToArray()
}
# Formato ICO: cabecalho, uma entrada por tamanho e as imagens PNG em seguida.
$out = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $out
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$tamanhos.Count)
$pos = 6 + 16 * $tamanhos.Count
for ($i = 0; $i -lt $tamanhos.Count; $i++) {
    $t = $tamanhos[$i]; $b = if ($t -ge 256) { 0 } else { $t }
    $w.Write([byte]$b); $w.Write([byte]$b); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$pos)
    $pos += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
[IO.File]::WriteAllBytes($Saida, $out.ToArray())
"ok: $Saida ($((Get-Item $Saida).Length) bytes)"
