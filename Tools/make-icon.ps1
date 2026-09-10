# Regenerates AutoItemMacro's artwork, so the icon is source rather than an
# opaque binary someone has to redraw by hand.
#
#     .\Tools\make-icon.ps1 .\Media
#
# Produces:
#   Media/Icon.png  512x512, for the CurseForge project avatar (min 400x400).
#                   Uploaded on the website; excluded from the addon zip.
#   Media/Icon.tga  64x64, referenced by ## IconTexture in the .toc. WoW cannot
#                   load PNG, so this is the one that actually ships.
#
# Two variants are kept alongside the shipped one ("stack" and "bolt"): change
# the Render calls at the bottom to switch. Uses only System.Drawing, so it
# runs on a stock Windows box with no image tooling installed.

Add-Type -AssemblyName System.Drawing

$OutDir = $args[0]
if (-not $OutDir) { throw "usage: make-icon.ps1 <outdir>" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }

function Col([string]$hex, [int]$a = 255) {
    $r = [Convert]::ToInt32($hex.Substring(0,2), 16)
    $g = [Convert]::ToInt32($hex.Substring(2,2), 16)
    $b = [Convert]::ToInt32($hex.Substring(4,2), 16)
    return [System.Drawing.Color]::FromArgb($a, $r, $g, $b)
}

function RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x,           $y,           $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y,           $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d,   0, 90)
    $p.AddArc($x,           $y + $h - $d, $d, $d,  90, 90)
    $p.CloseFigure()
    return $p
}

function VGrad([float]$x, [float]$y, [float]$w, [float]$h, $c1, $c2) {
    $r = New-Object System.Drawing.RectangleF($x, ($y - 1), $w, ($h + 2))
    return New-Object System.Drawing.Drawing2D.LinearGradientBrush($r, $c1, $c2, 90.0)
}

# Builds a GraphicsPath for $text scaled to fit inside the target box, centred.
function TextPath([string]$text, [string]$family, [int]$style, [float]$cx, [float]$cy, [float]$maxW, [float]$maxH) {
    $p  = New-Object System.Drawing.Drawing2D.GraphicsPath
    $sf = [System.Drawing.StringFormat]::GenericTypographic
    $ff = New-Object System.Drawing.FontFamily($family)
    $p.AddString($text, $ff, $style, 200.0, (New-Object System.Drawing.PointF(0,0)), $sf)
    $b = $p.GetBounds()
    if ($b.Width -le 0 -or $b.Height -le 0) { return $p }
    $s = [Math]::Min($maxW / $b.Width, $maxH / $b.Height)
    $m = New-Object System.Drawing.Drawing2D.Matrix
    $m.Translate($cx, $cy)
    $m.Scale($s, $s)
    $m.Translate(-($b.X + $b.Width / 2), -($b.Y + $b.Height / 2))
    $p.Transform($m)
    return $p
}

function Poly([float[][]]$pts, [float]$x, [float]$y, [float]$w, [float]$h) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $arr = New-Object 'System.Drawing.PointF[]' $pts.Length
    for ($i = 0; $i -lt $pts.Length; $i++) {
        $arr[$i] = New-Object System.Drawing.PointF(($x + $pts[$i][0] * $w), ($y + $pts[$i][1] * $h))
    }
    $p.AddPolygon($arr)
    return $p
}

# ── Shared chrome: the WoW item-slot frame every variant sits in ──────────────
function DrawFrame($g, [float]$S) {
    $u = $S / 512.0
    $pad = 8 * $u
    $rad = 92 * $u

    # drop shadow / dark seat
    $sh = RoundRect $pad $pad ($S - 2*$pad) ($S - 2*$pad) $rad
    $g.FillPath((New-Object System.Drawing.SolidBrush((Col "000000" 200))), $sh)

    # body
    $inset = 14 * $u
    $body = RoundRect $inset $inset ($S - 2*$inset) ($S - 2*$inset) ($rad - 6*$u)
    $g.FillPath((VGrad $inset $inset ($S - 2*$inset) ($S - 2*$inset) (Col "2A3450") (Col "0B0E15")), $body)

    # gold bevel: bright outer ring, dark inner ring
    $penOuter = New-Object System.Drawing.Pen((Col "E8CE8E"), (13 * $u))
    $penOuter.Alignment = [System.Drawing.Drawing2D.PenAlignment]::Inset
    $g.DrawPath($penOuter, $body)

    $ring = RoundRect ($inset + 13*$u) ($inset + 13*$u) ($S - 2*$inset - 26*$u) ($S - 2*$inset - 26*$u) ($rad - 18*$u)
    $penDark = New-Object System.Drawing.Pen((Col "6B4E1C"), (7 * $u))
    $penDark.Alignment = [System.Drawing.Drawing2D.PenAlignment]::Inset
    $g.DrawPath($penDark, $ring)

    # soft top-left sheen inside the frame
    $sheen = RoundRect ($inset + 20*$u) ($inset + 20*$u) ($S - 2*$inset - 40*$u) ($S * 0.42) ($rad - 26*$u)
    $g.FillPath((VGrad ($inset + 20*$u) ($inset + 20*$u) ($S - 2*$inset - 40*$u) ($S * 0.42) (Col "FFFFFF" 26) (Col "FFFFFF" 0)), $sheen)
}

function GoldPen($w) { return New-Object System.Drawing.Pen((Col "F3DFA6"), $w) }

# One bar of the priority stack. $hot = the winning (top-priority) entry.
function DrawBar($g, [float]$x, [float]$y, [float]$w, [float]$h, [float]$u, [bool]$hot) {
    $r = $h * 0.34
    $p = RoundRect $x $y $w $h $r
    if ($hot) {
        # outer glow
        for ($i = 5; $i -ge 1; $i--) {
            $gp = New-Object System.Drawing.Pen((Col "FFD97A" (10 + 6 * (5 - $i))), ($i * 7 * $u))
            $g.DrawPath($gp, $p)
        }
        $g.FillPath((VGrad $x $y $w $h (Col "FFF0C4") (Col "D2A345")), $p)
        $pen = New-Object System.Drawing.Pen((Col "7A5A18"), (3 * $u))
        $pen.Alignment = [System.Drawing.Drawing2D.PenAlignment]::Inset
        $g.DrawPath($pen, $p)
    } else {
        $g.FillPath((VGrad $x $y $w $h (Col "3B4463") (Col "222939")), $p)
        $pen = New-Object System.Drawing.Pen((Col "59648A"), (3 * $u))
        $pen.Alignment = [System.Drawing.Drawing2D.PenAlignment]::Inset
        $g.DrawPath($pen, $p)
    }
}

$BOLT = @(
    @(0.60, 0.00), @(0.10, 0.57), @(0.40, 0.57),
    @(0.32, 1.00), @(0.90, 0.40), @(0.58, 0.40)
)

function DrawBolt($g, [float]$x, [float]$y, [float]$w, [float]$h, [float]$u) {
    $p = Poly $BOLT $x $y $w $h
    $pen = New-Object System.Drawing.Pen((Col "0A0D13"), (14 * $u))
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPath($pen, $p)
    $g.FillPath((VGrad $x $y $w $h (Col "FFF3CB") (Col "E0A93A")), $p)
}

# ── Variants ─────────────────────────────────────────────────────────────────

function Variant-Stack($g, [float]$S) {
    # Pure priority-list glyph: the winning entry lit, the rest waiting below.
    $u = $S / 512.0
    $bw = 316 * $u
    $bh = 74  * $u
    $bx = ($S - $bw) / 2
    $y  = 138 * $u
    DrawBar $g $bx $y $bw $bh $u $true
    DrawBar $g ($bx + 26*$u) ($y + 104*$u) ($bw - 52*$u) ($bh * 0.80) $u $false
    DrawBar $g ($bx + 52*$u) ($y + 188*$u) ($bw - 104*$u) ($bh * 0.66) $u $false
}

function Variant-Word($g, [float]$S) {
    # Wordmark: the /aim slash command over its priority list.
    $u = $S / 512.0
    $tp = TextPath "aim" "Georgia" 1 ($S / 2) (198 * $u) (296 * $u) (162 * $u)
    $pen = New-Object System.Drawing.Pen((Col "0A0D13"), (18 * $u))
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPath($pen, $tp)
    $b = $tp.GetBounds()
    $g.FillPath((VGrad $b.Y $b.Y $b.Height $b.Height (Col "FFF4D2") (Col "CE9C39")), $tp)

    # the aim_ underscore, doubling as the top-priority entry
    $rw = 296 * $u
    DrawBar $g (($S - $rw) / 2) (300 * $u) $rw (32 * $u) $u $true

    # the rest of the list
    DrawBar $g (($S - $rw * 0.78) / 2) (352 * $u) ($rw * 0.78) (26 * $u) $u $false
    DrawBar $g (($S - $rw * 0.56) / 2) (396 * $u) ($rw * 0.56) (22 * $u) $u $false
}

function Variant-Bolt($g, [float]$S) {
    # Item slots with a bolt through them: "auto-use the right item".
    $u = $S / 512.0
    $bw = 268 * $u
    $bh = 62  * $u
    $bx = 122 * $u
    $y  = 130 * $u
    DrawBar $g $bx $y $bw $bh $u $false
    DrawBar $g ($bx + 16*$u) ($y + 86*$u)  ($bw - 32*$u) $bh $u $false
    DrawBar $g ($bx + 32*$u) ($y + 172*$u) ($bw - 64*$u) $bh $u $false
    DrawBolt $g (116 * $u) (86 * $u) (290 * $u) (346 * $u) $u
}

# ── Render ───────────────────────────────────────────────────────────────────

# WoW cannot load PNG. Write an uncompressed 32-bit BGRA TGA, top-left origin,
# which is what the client wants for an addon-supplied texture.
function SaveTga($bmp, [string]$path) {
    $w = $bmp.Width
    $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = [Math]::Abs($data.Stride)
    $buf = New-Object byte[] ($stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
    $bmp.UnlockBits($data)

    $fs = [System.IO.File]::Create($path)
    try {
        # 18-byte header: no id, no colour map, type 2 (uncompressed true-colour)
        $hdr = New-Object byte[] 18
        $hdr[2]  = 2
        $hdr[12] = [byte]($w -band 0xFF); $hdr[13] = [byte](($w -shr 8) -band 0xFF)
        $hdr[14] = [byte]($h -band 0xFF); $hdr[15] = [byte](($h -shr 8) -band 0xFF)
        $hdr[16] = 32    # bits per pixel
        $hdr[17] = 0x28  # 8 alpha bits, origin top-left
        $fs.Write($hdr, 0, 18)
        # Format32bppArgb is already BGRA in memory, matching TGA's byte order.
        for ($row = 0; $row -lt $h; $row++) { $fs.Write($buf, ($row * $stride), ($w * 4)) }
    } finally {
        $fs.Close()
    }
    Write-Output $path
}

function Render([string]$variant, [int]$S, [string]$path) {
    $bmp = New-Object System.Drawing.Bitmap($S, $S, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    DrawFrame $g ([float]$S)
    switch ($variant) {
        "stack" { Variant-Stack $g ([float]$S) }
        "word"  { Variant-Word  $g ([float]$S) }
        "bolt"  { Variant-Bolt  $g ([float]$S) }
    }

    $g.Dispose()
    if ($path.EndsWith(".tga")) {
        SaveTga $bmp $path | Out-Null
    } else {
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    $bmp.Dispose()
    Write-Output $path
}

# The shipped artwork: a 512px PNG for the CurseForge project avatar (their
# minimum is 400x400) and a 64px TGA for the in-game AddOn list, which is the
# only one of the two the game itself can load.
Render "word" 512 (Join-Path $OutDir "Icon.png")
Render "word" 64  (Join-Path $OutDir "Icon.tga")
