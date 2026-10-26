<#
.SYNOPSIS
    在 Windows 上检查一个未签名 .ipa 是否正常（不用 Mac / 不用 Xcode）。
    用途：云端构建产物下载后，先本地验一遍再传到手机上。

.DESCRIPTION
    检查项：
      1. zip 结构是否为标准 ipa（Payload/xxx.app/）
      2. Info.plist 里的 BundleID / 版本号 / 最低系统版本
         （Xcode 产物的 Info.plist 是二进制 plist，这里优先读同目录的 Info.json
           —— 那是构建机上用 plutil 转出来的；没有的话退回 ASCII 扫描）
      3. 主可执行文件是不是 Mach-O、CPU 架构是不是 arm64（真机）
      4. 是否确实「未签名」（没有 _CodeSignature / embedded.mobileprovision）
         —— 这一条要是不通过，全能签可能签不上

.PARAMETER IpaPath
    .ipa 文件路径。省略则自动找工程 build 目录下的 ipa。
#>
[CmdletBinding()]
param(
    [string]$IpaPath
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not $IpaPath) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $Root = (Resolve-Path (Join-Path $ScriptDir "..")).Path
    $found = Get-ChildItem -Path (Join-Path $Root "build") -Filter *.ipa -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $found) { throw "no .ipa found in $Root\build - pass -IpaPath explicitly" }
    $IpaPath = $found.FullName
}
if (-not (Test-Path $IpaPath)) { throw "not found: $IpaPath" }

$size = [math]::Round((Get-Item $IpaPath).Length / 1MB, 2)
Write-Host ""
Write-Host "=== IPA inspection ===" -ForegroundColor Cyan
Write-Host ("file : {0}" -f $IpaPath)
Write-Host ("size : {0} MB" -f $size)

$tmp = Join-Path $env:TEMP ("ipa-inspect-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($IpaPath, $tmp)

    # --- 1. 找 .app ---
    $appDir = Get-ChildItem -Path $tmp -Recurse -Directory -Filter *.app | Select-Object -First 1
    if (-not $appDir) {
        Write-Host "  [!!] no *.app inside - this is not a valid ipa" -ForegroundColor Red
        exit 1
    }
    Write-Host ("  [ok] app bundle             : {0}" -f $appDir.Name) -ForegroundColor Green

    # --- 2. Info.plist ---
    $plistPath = Join-Path $appDir.FullName "Info.plist"
    if (-not (Test-Path $plistPath)) {
        Write-Host "  [!!] Info.plist missing" -ForegroundColor Red
        exit 1
    }
    $raw = [System.IO.File]::ReadAllBytes($plistPath)
    $isBinary = ($raw.Length -gt 8 -and [System.Text.Encoding]::ASCII.GetString($raw, 0, 8) -eq "bplist00")

    $sidecar = Join-Path (Split-Path -Parent $IpaPath) "Info.json"
    $info = $null
    if (Test-Path $sidecar) {
        try { $info = Get-Content -Raw -Encoding UTF8 $sidecar | ConvertFrom-Json } catch { $info = $null }
    }

    if ($info) {
        Write-Host "  [ok] CFBundleIdentifier      : $($info.CFBundleIdentifier)" -ForegroundColor Green
        Write-Host "  [ok] CFBundleDisplayName    : $($info.CFBundleDisplayName)"
        Write-Host ("  [ok] Version                : {0} (build {1})" -f $info.CFBundleShortVersionString, $info.CFBundleVersion)
        Write-Host ("  [ok] MinimumOSVersion       : {0}" -f $info.MinimumOSVersion)
        Write-Host ("  [ok] CFBundleExecutable     : {0}" -f $info.CFBundleExecutable)
        Write-Host ("  [ok] CFBundleSupportedPlatforms : {0}" -f ($info.CFBundleSupportedPlatforms -join ", "))
        $execName = $info.CFBundleExecutable
    } else {
        # 退路：二进制 plist 里把可读 ASCII 串抽出来，挑几个关键值看看
        Write-Host "  [--] Info.plist is a binary plist and no Info.json sidecar was found" -ForegroundColor Yellow
        Write-Host "       (build via CI to get build\Info.json, or read the values on a Mac)" -ForegroundColor DarkGray
        $strings = New-Object System.Collections.Generic.List[string]
        $sb = New-Object System.Text.StringBuilder
        foreach ($b in $raw) {
            if ($b -ge 32 -and $b -lt 127) { [void]$sb.Append([char]$b) }
            else { if ($sb.Length -ge 4) { $strings.Add($sb.ToString()) }; [void]$sb.Clear() }
        }
        if ($sb.Length -ge 4) { $strings.Add($sb.ToString()) }
        $hits = $strings | Where-Object { $_ -match "com\.hyperdown|^Hyperdown$|^\d+\.\d+(\.\d+)?$|iPhone|^\d{1,2}\.\d$" } |
                Select-Object -Unique -First 12
        if ($hits) { Write-Host ("       strings found: " + ($hits -join " | ")) -ForegroundColor DarkGray }
        $execName = $appDir.BaseName
    }

    # --- 3. Mach-O 架构 ---
    $binPath = Join-Path $appDir.FullName $execName
    if (-not (Test-Path $binPath)) { $binPath = Join-Path $appDir.FullName $appDir.BaseName }
    if (Test-Path $binPath) {
        $bytes = [System.IO.File]::ReadAllBytes($binPath)
        # Mach-O magic 按字节判断。
        # 注意：不能写成 0xFEEDFACF 这样的十六进制字面量比较 ——
        #       PowerShell 会把超过 Int32 的值解析成负数，比较永远为 false。
        $m = @($bytes[0], $bytes[1], $bytes[2], $bytes[3])
        $isMachO = ($m[0] -eq 0xCF -and $m[1] -eq 0xFA -and $m[2] -eq 0xED -and $m[3] -eq 0xFE) -or
                   ($m[0] -eq 0xCE -and $m[1] -eq 0xFA -and $m[2] -eq 0xED -and $m[3] -eq 0xFE) -or
                   ($m[0] -eq 0xCA -and $m[1] -eq 0xFE -and $m[2] -eq 0xBA -and $m[3] -eq 0xBE) -or
                   ($m[0] -eq 0xBE -and $m[1] -eq 0xBA -and $m[2] -eq 0xFE -and $m[3] -eq 0xCA)
        if (-not $isMachO) {
            Write-Host ("  [!!] executable is not Mach-O (bytes {0:X2} {1:X2} {2:X2} {3:X2})" -f $m[0], $m[1], $m[2], $m[3]) -ForegroundColor Red
        } else {
            Write-Host ("  [ok] Mach-O binary           : {0:N1} MB" -f ($bytes.Length / 1MB)) -ForegroundColor Green
            $cpu = [BitConverter]::ToUInt32($bytes, 4)
            $cpuName = switch ($cpu) {
                16777228 { "arm64  (真机可用)" }
                12       { "armv7" }
                16777223 { "x86_64 (仅模拟器, 装到手机会闪退!)" }
                default  { "0x{0:X8}" -f $cpu }
            }
            if ($cpu -eq 16777228) {
                Write-Host ("  [ok] CPU arch                : {0}" -f $cpuName) -ForegroundColor Green
            } else {
                Write-Host ("  [!!] CPU arch                : {0}" -f $cpuName) -ForegroundColor Red
            }
        }
    } else {
        Write-Host ("  [!!] executable not found in bundle" -f $execName) -ForegroundColor Red
    }

    # --- 4. 签名状态 ---
    $hasSig  = Test-Path (Join-Path $appDir.FullName "_CodeSignature")
    $hasProf = Test-Path (Join-Path $appDir.FullName "embedded.mobileprovision")
    if ($hasSig -or $hasProf) {
        Write-Host "  [!!] this ipa IS signed - it was meant to be unsigned" -ForegroundColor Yellow
    } else {
        Write-Host "  [ok] unsigned (no _CodeSignature / no embedded.mobileprovision)" -ForegroundColor Green
        Write-Host "       -> ready for QuanNengSign / ESign / AltStore to re-sign" -ForegroundColor DarkGray
    }

    # --- 5. 资源抽查 ---
    $assets = Get-ChildItem -Path $appDir.FullName -Filter "Assets.car" -ErrorAction SilentlyContinue
    $appIcon = Get-ChildItem -Path $appDir.FullName -Filter "AppIcon*" -ErrorAction SilentlyContinue
    Write-Host ("  [ok] Assets.car              : {0}" -f $(if ($assets) { "present" } else { "MISSING" }))
    Write-Host ("  [ok] AppIcon                 : {0}" -f $(if ($appIcon) { ($appIcon | ForEach-Object { $_.Name }) -join ", " } else { "none (用 Assets.car 里的)" }))

    # --- 6. 包内文件一览 ---
    $all = Get-ChildItem -Path $appDir.FullName -Recurse -File
    Write-Host ("  [ok] files in bundle         : {0}  (total {1:N1} MB uncompressed)" -f $all.Count, (($all | Measure-Object Length -Sum).Sum / 1MB))

    Write-Host ""
    Write-Host "=== verdict ===" -ForegroundColor Cyan
    if (-not $hasSig -and -not $hasProf) {
        Write-Host "  GOOD - upload this ipa to your signing tool." -ForegroundColor Green
    } else {
        Write-Host "  Check the signature warning above." -ForegroundColor Yellow
    }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
