# Draws the app icons into /icons. Run: powershell -ExecutionPolicy Bypass -File tools\make-icons.ps1
Add-Type -AssemblyName System.Drawing
$out = Join-Path $PSScriptRoot '..\icons'
New-Item -ItemType Directory -Force $out | Out-Null

function Draw-Icon([int]$size, [string]$name, [double]$inset) {
  $bmp = New-Object System.Drawing.Bitmap $size, $size
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'AntiAliasGridFit'
  $rect = New-Object System.Drawing.Rectangle 0, 0, $size, $size
  $c1 = [System.Drawing.Color]::FromArgb(255, 52, 214, 104)
  $c2 = [System.Drawing.Color]::FromArgb(255, 10, 150, 120)
  $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, $c1, $c2, 45
  $g.FillRectangle($brush, $rect)

  # Progress ring (open arc) in white
  $pad = $size * (0.18 + $inset)
  $penW = $size * 0.075
  $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(70, 255, 255, 255)), $penW
  $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
  $g.DrawEllipse($pen, $pad, $pad, $size - 2 * $pad, $size - 2 * $pad)
  $pen2 = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), $penW
  $pen2.StartCap = 'Round'; $pen2.EndCap = 'Round'
  $g.DrawArc($pen2, $pad, $pad, $size - 2 * $pad, $size - 2 * $pad, -90, 270)

  # "5K" label
  $font = New-Object System.Drawing.Font 'Segoe UI Black', ($size * 0.2), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $rf = New-Object System.Drawing.RectangleF 0, ($size * 0.01), $size, $size
  $g.DrawString('5K', $font, [System.Drawing.Brushes]::White, $rf, $sf)

  $bmp.Save((Join-Path $out $name), [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  "wrote $name"
}

Draw-Icon 180 'apple-touch-icon.png' 0
Draw-Icon 192 'icon-192.png' 0
Draw-Icon 512 'icon-512.png' 0
Draw-Icon 512 'icon-maskable-512.png' 0.06
