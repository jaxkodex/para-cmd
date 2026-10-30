param(
  [string] $RunSlug,
  [switch] $NoCloneMissing,
  [switch] $NoPretty,
  [switch] $Help
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$registry = Join-Path $root 'repos.yml'
$cloneRoot = '.repo'
$runId = $null
$runDir = $null
$nativeSsh = Join-Path $env:SystemRoot 'System32/OpenSSH/ssh.exe'
if (-not $env:GIT_SSH -and (Test-Path -LiteralPath $nativeSsh -PathType Leaf)) { $env:GIT_SSH = $nativeSsh }

function Stop-Refresh([string] $Message) {
  [Console]::Error.WriteLine("refresh-repos: $Message")
  exit 1
}

if ($Help) {
  @'
refresh-repos.ps1 — refresh registered repository clones and reserve a run namespace.

Usage: scripts/refresh-repos.ps1 [-RunSlug <slug>] [-NoCloneMissing] [-NoPretty]
  -RunSlug         mint <normalized-slug>-<6 random lowercase alphanumerics>
                   and reserve .repo/worktrees/<run-id>/
  -NoCloneMissing  report absent clones without cloning them
  -NoPretty        emit minified JSON
'@ | Write-Output
  exit 0
}

if (-not (Test-Path -LiteralPath $registry -PathType Leaf)) {
  Stop-Refresh "repos.yml not found at $registry"
}

if ($PSBoundParameters.ContainsKey('RunSlug')) {
  if ([string]::IsNullOrWhiteSpace($RunSlug)) { Stop-Refresh '--run needs a slug' }
  $slug = [regex]::Replace($RunSlug.ToLowerInvariant(), '[^a-z0-9]+', '-').Trim('-')
  if (-not $slug) { Stop-Refresh '--run slug is empty after normalization' }
  $worktreeRoot = Join-Path $root '.repo/worktrees'
  [void][System.IO.Directory]::CreateDirectory($worktreeRoot)
  $chars = 'abcdefghijklmnopqrstuvwxyz0123456789'
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $reserved = $false
  for ($attempt = 0; $attempt -lt 10; $attempt++) {
    $suffixChars = [System.Collections.Generic.List[char]]::new()
    while ($suffixChars.Count -lt 6) {
      $byte = New-Object byte[] 1
      $rng.GetBytes($byte)
      if ($byte[0] -lt 252) { $suffixChars.Add($chars[[int]($byte[0] % 36)]) }
    }
    $suffix = -join $suffixChars
    $runId = "$slug-$suffix"
    $runDir = Join-Path $worktreeRoot $runId
    try {
      [void](New-Item -ItemType Directory -Path $runDir -ErrorAction Stop)
      $reserved = $true
      break
    } catch {
      [Console]::Error.WriteLine("refresh-repos: run id $runId already taken, retrying")
    }
  }
  $rng.Dispose()
  if (-not $reserved) { Stop-Refresh "could not reserve a run id for '$slug' after 10 attempts" }
  $marker = [ordered]@{ run_id = $runId; feature = $slug; created = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
  [System.IO.File]::WriteAllText((Join-Path $runDir '.factory-run.json'), ($marker | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
  [Console]::Error.WriteLine("refresh-repos: run id $runId (reserved .repo/worktrees/$runId)")
}

# Parse the registry's deliberately simple, two-space repo list without a YAML dependency.
try { $lines = Get-Content -LiteralPath $registry } catch { Stop-Refresh "could not read $registry : $($_.Exception.Message)" }
$repos = [System.Collections.Generic.List[object]]::new()
$current = $null
foreach ($line in $lines) {
  if ($line -match '^clone_root:\s*([^#]+?)\s*(?:#.*)?$') { $cloneRoot = $Matches[1].Trim().Trim('"', "'"); continue }
  if ($line -match '^  - name:\s*([^#]+?)\s*(?:#.*)?$') {
    if ($current) { $repos.Add($current) }
    $current = [ordered]@{ name = $Matches[1].Trim().Trim('"', "'"); url = ''; path = ''; default_branch = 'main' }
    continue
  }
  if ($current -and $line -match '^    (url|path|default_branch):\s*([^#]*?)(?:\s+#.*)?$') {
    $current[$Matches[1]] = $Matches[2].Trim().Trim('"', "'")
  }
}
if ($current) { $repos.Add($current) }
if ($repos.Count -eq 0) { Stop-Refresh "could not parse any repos from $registry" }

function Invoke-Git([string] $Path, [string[]] $GitArgs) {
  $out = @(& git -C $Path @GitArgs 2>&1)
  $code = $LASTEXITCODE
  return [pscustomobject]@{ ExitCode = $code; Text = (($out | ForEach-Object { "$_" }) -join "`n").Trim() }
}
function Get-ShortSha([string] $Path, [string] $Ref) {
  $r = Invoke-Git $Path @('rev-parse', '--short', $Ref)
  if ($r.ExitCode -eq 0) { return $r.Text }
  return ''
}

$states = @('cloned','refreshed','clean','dirty','wrong_branch','diverged','remote_mismatch','missing','error')
$summary = [ordered]@{ total = 0 }
foreach ($stateName in $states) { $summary[$stateName] = 0 }
$repoReports = [System.Collections.Generic.List[object]]::new()
foreach ($repo in $repos) {
  $rel = if ($repo.path) { $repo.path } else { "$cloneRoot/$($repo.name)" }
  $path = Join-Path $root $rel
  $expected = $repo.url
  $defaultBranch = $repo.default_branch
  $state = ''
  $errorText = $null
  $oldSha = ''
  $newSha = ''
  $branch = ''
  $actualRemote = ''
  $dirty = $false
  $justCloned = $false
  $worktrees = @()
  $factoryBranches = @()
  $summary.total++

  if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) {
    if (-not $NoCloneMissing) {
      [Console]::Error.WriteLine("refresh-repos: cloning $($repo.name) -> $rel")
      $cloneOutput = @(& git clone $expected $path 2>&1)
      if ($LASTEXITCODE -eq 0) { $justCloned = $true }
      else { $state = 'error'; $errorText = "clone failed: $((($cloneOutput | ForEach-Object { "$_" }) -join ' ').Trim())" }
    }
    if (-not $state -and -not $justCloned) {
      $state = 'missing'
      [Console]::Error.WriteLine("refresh-repos: $($repo.name): missing clone ($rel), not cloned: -NoCloneMissing")
    }
  }

  if ((Test-Path -LiteralPath (Join-Path $path '.git')) -and -not $state) {
    $remoteResult = Invoke-Git $path @('remote','get-url','origin')
    if ($remoteResult.ExitCode -eq 0) { $actualRemote = $remoteResult.Text }
    $headResult = Invoke-Git $path @('rev-parse','HEAD')
    if ($headResult.ExitCode -eq 0) { $oldSha = $headResult.Text }
    $newSha = $oldSha
    $branchResult = Invoke-Git $path @('rev-parse','--abbrev-ref','HEAD')
    if ($branchResult.ExitCode -eq 0) { $branch = $branchResult.Text }
    $statusResult = Invoke-Git $path @('status','--porcelain')
    $dirty = $statusResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($statusResult.Text)

    if ($expected -and $actualRemote -ne $expected) {
      $state = 'remote_mismatch'; $errorText = "origin is $actualRemote, registry says $expected"
    } else {
      $fetchResult = Invoke-Git $path @('fetch','origin','--quiet')
      if ($fetchResult.ExitCode -ne 0) { $state = 'error'; $errorText = "git fetch origin failed: $(($fetchResult.Text -replace '\s+', ' ').Trim())" }
      elseif ($dirty) { $state = 'dirty' }
      elseif ($branch -ne $defaultBranch) { $state = 'wrong_branch' }
      else {
        $mergeResult = Invoke-Git $path @('merge','--ff-only',"origin/$defaultBranch")
        if ($mergeResult.ExitCode -eq 0) {
          $headResult = Invoke-Git $path @('rev-parse','HEAD')
          if ($headResult.ExitCode -eq 0) { $newSha = $headResult.Text }
          if ($justCloned) { $state = 'cloned' }
          elseif ($newSha -eq $oldSha) { $state = 'clean' }
          else { $state = 'refreshed' }
        } else { $state = 'diverged'; $errorText = ($mergeResult.Text -replace '\s+', ' ').Trim() }
      }
    }

    $wtResult = Invoke-Git $path @('worktree','list','--porcelain')
    $wtPath = ''; $wtSha = ''; $wtBranch = ''
    foreach ($entry in ($wtResult.Text -split "`n")) {
      $entry = $entry.TrimEnd("`r")
      if ($entry.StartsWith('worktree ')) { $wtPath = $entry.Substring(9) }
      elseif ($entry.StartsWith('HEAD ')) { $wtSha = $entry.Substring(5) }
      elseif ($entry.StartsWith('branch refs/heads/')) {
        $wtBranch = $entry.Substring(18)
        $worktrees += [ordered]@{ path = $wtPath; branch = $wtBranch; sha = $wtSha }
        $wtPath = ''; $wtSha = ''; $wtBranch = ''
      } elseif ($entry -eq 'detached') {
        $worktrees += [ordered]@{ path = $wtPath; branch = '(detached)'; sha = $wtSha }
        $wtPath = ''; $wtSha = ''; $wtBranch = ''
      }
    }

    $refsResult = Invoke-Git $path @('for-each-ref','--format=%(refname:short)','refs/heads/factory/')
    foreach ($ref in ($refsResult.Text -split "`n" | Where-Object { $_ })) {
      $ref = $ref.TrimEnd("`r")
      $parts = $ref -split '/'
      $factoryRun = if ($parts.Length -gt 1) { $parts[1] } else { '' }
      $markerPath = if ($factoryRun) { Join-Path $root ".repo/worktrees/$factoryRun/.factory-run.json" } else { '' }
      $feature = ''
      if ($markerPath -and (Test-Path -LiteralPath $markerPath)) {
        try { $feature = (Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json).feature } catch { $feature = '' }
      }
      $factoryBranches += [ordered]@{ name = $ref; commit = (Get-ShortSha $path $ref); run_id = $factoryRun; marker = $markerPath; feature = $feature }
    }
  }

  $summary[$state]++
  [Console]::Error.WriteLine(('refresh-repos: {0,-20} {1,-14} {2} -> {3}' -f $repo.name,$state,$oldSha.Substring(0,[Math]::Min(7,$oldSha.Length)),$newSha.Substring(0,[Math]::Min(7,$newSha.Length))))
  $repoReports.Add([ordered]@{ name=$repo.name; path=$rel; expected_remote=$expected; actual_remote=$actualRemote; default_branch=$defaultBranch; state=$state; old_sha=$oldSha; new_sha=$newSha; branch=$branch; dirty=$dirty; worktrees=$worktrees; factory_branches=$factoryBranches; error=$errorText })
}

$report = [ordered]@{
  generated_at = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
  registry = 'repos.yml'
  clone_root = $cloneRoot
  run_id = $runId
  run_dir = if ($runId) { ".repo/worktrees/$runId" } else { $null }
  summary = $summary
  repos = $repoReports
}
if ($NoPretty) { $json = ConvertTo-Json -InputObject $report -Depth 30 -Compress }
else { $json = ConvertTo-Json -InputObject $report -Depth 30 }
[Console]::Out.WriteLine($json)
