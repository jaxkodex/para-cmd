$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\refresh-repos.ps1'
$scriptPath = (Resolve-Path -LiteralPath $scriptPath).Path
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Assert([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw "FAIL: $Message" }
  Write-Output "PASS: $Message"
}

function Quote-Argument([string] $Value) {
  return '"' + $Value + '"'
}

function Invoke-PowerShellFile([string] $File, [string[]] $Arguments) {
  $engine = (Get-Process -Id $PID).Path
  $allArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $File) + $Arguments
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $engine
  $startInfo.Arguments = (($allArguments | ForEach-Object { Quote-Argument "$_" }) -join ' ')
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  [void]$process.Start()
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  return [pscustomobject]@{
    ExitCode = $process.ExitCode
    Stdout = $stdoutTask.GetAwaiter().GetResult()
    Stderr = $stderrTask.GetAwaiter().GetResult()
  }
}

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
Assert ($parseErrors.Count -eq 0) "PowerShell parser accepts refresh-repos.ps1 ($($parseErrors.Count) errors)"

$help = Invoke-PowerShellFile $scriptPath @('-Help')
Assert ($help.ExitCode -eq 0) '-Help exits successfully'
Assert ($help.Stdout -match 'Usage: scripts/refresh-repos\.ps1' -and $help.Stdout -match '-NoCloneMissing') '-Help documents the Windows switches'

$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("refresh-repos-test-" + [guid]::NewGuid().ToString('N'))
try {
  $fixtureScripts = Join-Path $fixture 'scripts'
  [void][System.IO.Directory]::CreateDirectory($fixtureScripts)
  Copy-Item -LiteralPath $scriptPath -Destination (Join-Path $fixtureScripts 'refresh-repos.ps1')
  @'
clone_root: .repo
repos:
  - name: absent-fixture
    url: git@github.com:fixture/absent-fixture.git
    path: .repo/absent-fixture
    default_branch: main
'@ | Set-Content -LiteralPath (Join-Path $fixture 'repos.yml') -Encoding utf8

  $before = @(Get-ChildItem -LiteralPath $fixture -Force -Recurse | ForEach-Object FullName)
  $smoke = Invoke-PowerShellFile (Join-Path $fixtureScripts 'refresh-repos.ps1') @('-NoCloneMissing', '-NoPretty')
  Assert ($smoke.ExitCode -eq 0) '-NoCloneMissing smoke exits successfully'
  $report = $smoke.Stdout | ConvertFrom-Json
  Assert ($report.summary.total -eq 1 -and $report.summary.missing -eq 1) '-NoCloneMissing reports the absent fixture clone'
  Assert ($report.repos[0].state -eq 'missing' -and $report.repos[0].name -eq 'absent-fixture') '-NoCloneMissing identifies the fixture repo as missing'
  Assert ($smoke.Stderr -match 'not cloned: -NoCloneMissing') '-NoCloneMissing explains that cloning was skipped'
  Assert (-not (Test-Path -LiteralPath (Join-Path $fixture '.repo'))) '-NoCloneMissing creates no clone or worktree paths'
  $after = @(Get-ChildItem -LiteralPath $fixture -Force -Recurse | ForEach-Object FullName)
  $beforeText = ($before | Sort-Object) -join "`n"
  $afterText = ($after | Sort-Object) -join "`n"
  Assert ($beforeText -ceq $afterText) '-NoCloneMissing leaves the fixture filesystem unchanged'
} finally {
  Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

$docFiles = @(
  (Join-Path $repoRoot '.pi\prompts\feature-review.md'),
  (Join-Path $repoRoot '.pi\prompts\bug-fix.md'),
  (Join-Path $repoRoot '.pi\workflows\feature-review.yml'),
  (Join-Path $repoRoot '.pi\workflows\bug-fix.yml')
)
foreach ($docFile in $docFiles) {
  $content = Get-Content -LiteralPath $docFile -Raw
  Assert ($content -match 'refresh-repos\.ps1 -RunSlug <[^>]+>') "$(Split-Path $docFile -Leaf) documents -RunSlug"
}
$agentGuide = Get-Content -LiteralPath (Join-Path $repoRoot 'AGENTS.md') -Raw
Assert ($agentGuide -match 'dry-run switch is `--no-clone-missing`\s+on macOS/Linux') 'AGENTS.md documents the Bash dry-run switch for macOS/Linux'
Assert ($agentGuide -match 'and `-NoCloneMissing` on Windows') 'AGENTS.md documents the PowerShell dry-run switch for Windows'

Write-Output 'All refresh-repos Windows checks passed.'
