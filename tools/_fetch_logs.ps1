
$ErrorActionPreference = 'Stop'
$tok = $env:GITHUB_TOKEN
$h = @{ Authorization = "Bearer $tok"; Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28"; "User-Agent" = "cs-fetch" }
$RepoApi = "https://api.github.com/repos/2466707195/CarSentinel-iOS"
$runId  = 40317109543
$outRoot = "C:\Users\24667\Documents\deepseek-harness\default-workspace\CarSentinel360\build"

$arts = Invoke-RestMethod -Uri "$RepoApi/actions/runs/$runId/artifacts" -Headers $h -UseBasicParsing -TimeoutSec 120
"artifact 数: $($arts.total_count)"
foreach ($a in $arts.artifacts) { "  {0,-22} {1,7:N1} KB" -f $a.name, ($a.size_in_bytes/1KB) }

foreach ($a in $arts.artifacts) {
    $dest = Join-Path $outRoot ("logs\" + $a.name)
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $zip = Join-Path $env:TEMP ("cs-" + $a.name + ".zip")
    Invoke-WebRequest -Uri "$RepoApi/actions/artifacts/$($a.id)/zip" -Headers $h -OutFile $zip -UseBasicParsing -TimeoutSec 300 -MaximumRedirection 5
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    Get-ChildItem -LiteralPath $dest -File | ForEach-Object {
        Write-Host ("   -> {0}  ({1:N1} KB)" -f $_.Name, ($_.Length/1KB))
    }
    Remove-Item -LiteralPath $zip -Force
}
