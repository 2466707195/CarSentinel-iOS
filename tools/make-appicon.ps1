$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$out  = "C:\Users\24667\Documents\deepseek-harness\default-workspace\CarSentinel360\ios\CarSentinel\Resources\Assets.xcassets\AppIcon.appiconset\AppIcon-1024.png"
$size = 1024
$bmp  = New-Object System.Drawing.Bitmap($size, $size)
$g    = [System.Drawing.Graphics]::FromImage($bmp)

$g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

# --- 1) 品牌渐变底：逐行插值，只用 SolidBrush，避开 LinearGradientBrush 的解析坑 ---
$top = [System.Drawing.ColorTranslator]::FromHtml("#5B54F0")
$bot = [System.Drawing.ColorTranslator]::FromHtml("#8B5CF6")
for ($y = 0; $y -lt $size; $y++) {
    $t = $y / ($size - 1)
    $r = [int]($top.R + ($bot.R - $top.R) * $t)
    $gg = [int]($top.G + ($bot.G - $top.G) * $t)
    $b = [int]($top.B + ($bot.B - $top.B) * $t)
    $line = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, $r, $gg, $b))
    $g.FillRectangle($line, 0, $y, $size, 1)
    $line.Dispose()
}

$white = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
$cx = $size / 2.0
$cy = $size / 2.0

# --- 2) 外环：360 度环视，右上留缺口 ---
$ringPen = New-Object System.Drawing.Pen($white, 74.0)
$ringPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$ringPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
$ringRect = New-Object System.Drawing.RectangleF([float]($cx - 330), [float]($cy - 330), 660, 660)
$g.DrawArc($ringPen, $ringRect, -50, 320)
$ringPen.Dispose()

# --- 3) 内环：镜头 ---
$innerPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, 255, 255, 255), 16.0)
$innerRect = New-Object System.Drawing.RectangleF([float]($cx - 208), [float]($cy - 208), 416, 416)
$g.DrawEllipse($innerPen, $innerRect)
$innerPen.Dispose()

# --- 4) 中心镜头光点 ---
$dot = New-Object System.Drawing.SolidBrush($white)
$g.FillEllipse($dot, [float]($cx - 190), [float]($cy - 4), 124, 124)
$dot.Dispose()

# --- 5) 四个方位小点：前 / 右 / 后 / 左 四路摄像头 ---
$angles = @(-90, 0, 90, 180)
$r = 428.0
foreach ($a in $angles) {
    $rad = $a * [Math]::PI / 180.0
    $px = $cx + $r * [Math]::Cos($rad)
    $py = $cy + $r * [Math]::Sin($rad)
    $d = 46.0
    $sb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 255, 255, 255))
    $g.FillEllipse($sb, [float]($px - $d / 2), [float]($py - $d / 2), [float]$d, [float]$d)
    $sb.Dispose()
}

$g.Dispose()

$dir = Split-Path -Parent $out
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$fi = Get-Item -LiteralPath $out
"written: $out"
"size   : $([math]::Round($fi.Length/1KB,1)) KB"
