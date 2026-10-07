<#
.SYNOPSIS
    Runs the spamoor load tests listed in test-plan.json. For each run it streams one
    validator's logs, samples pod CPU/memory, runs spamoor for the set duration, lets the
    txpool drain, then zips everything and pushes it to the repo's runs/ folder.

.EXAMPLE
    git pull
    .\scripts\Run-SpamoorTests.ps1

.EXAMPLE
    .\scripts\Run-SpamoorTests.ps1 -NoPush      # keep results local only
#>
[CmdletBinding()]
param(
    [string]$PlanFile     = (Join-Path $PSScriptRoot 'test-plan.json'),
    [string]$TemplateFile = (Join-Path $PSScriptRoot 'spamoor-run.template.yml'),
    [string]$RepoRoot     = (Split-Path $PSScriptRoot -Parent),
    [string]$WorkRoot     = (Join-Path $HOME 'spamoor-runs'),
    [string]$PrivKeyFile  = (Join-Path $HOME 'spamoor-privkey.txt'),   # kept outside the repo on purpose
    [string]$Registry     = $env:IMAGE_REGISTRY,                       # registry + path prefix, kept outside the repo
    [int]$MaxZipMB        = 95,                                        # GitHub rejects files over 100 MB
    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'
$kubectl = (Get-Command kubectl).Source
$git     = (Get-Command git).Source
$script:LastExit = 0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Runs a native command and returns its output as strings; throws on non-zero exit
# unless -AllowFailure. Windows PowerShell turns native stderr into terminating
# errors under 'Stop', so that is relaxed for the duration of the call.
function Invoke-Native {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Exe,
        [Parameter(Position = 1)][string[]]$ArgList = @(),
        [string]$InputText,
        [switch]$AllowFailure
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $out = $InputText | & $Exe @ArgList 2>&1 | ForEach-Object { "$_" }
        } else {
            $out = & $Exe @ArgList 2>&1 | ForEach-Object { "$_" }
        }
        $script:LastExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($script:LastExit -ne 0 -and -not $AllowFailure) {
        throw "$(Split-Path $Exe -Leaf) $($ArgList -join ' ') failed (exit $($script:LastExit)):`n$($out -join "`n")"
    }
    return $out
}

# Writes a command's stdout straight to a file. Avoids Windows PowerShell's '>'
# redirection, which re-encodes output as UTF-16 and doubles the file size.
function Save-NativeOutput {
    param([string]$Exe, [string[]]$ArgList, [string]$Path)
    Start-Process -FilePath $Exe -ArgumentList $ArgList -NoNewWindow -Wait `
        -RedirectStandardOutput $Path -RedirectStandardError "$Path.stderr" | Out-Null
    Remove-EmptyFile "$Path.stderr"
}

function Remove-EmptyFile([string]$Path) {
    if ((Test-Path $Path) -and (Get-Item $Path).Length -eq 0) { Remove-Item $Path }
}

function Get-PodField([string]$Pod, [string]$JsonPath) {
    $v = Invoke-Native $kubectl @('get', 'pod', $Pod, '-n', $ns, '-o', "jsonpath=$JsonPath") -AllowFailure
    if ($script:LastExit -ne 0) { return $null }
    return ($v -join '').Trim()
}

function Get-UtcStamp { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'") }

function Reset-Network {
    Write-Host "  Restarting all statefulsets in $ns ..."
    Invoke-Native $kubectl @('rollout', 'restart', 'statefulset', '-n', $ns) | Out-Null
    foreach ($s in (Invoke-Native $kubectl @('get', 'statefulset', '-n', $ns, '-o', 'name'))) {
        Invoke-Native $kubectl @('rollout', 'status', $s, '-n', $ns, '--timeout=15m') | Out-Null
    }
    Write-Host '  Network back up.'
}

function Publish-Runs([string]$Message) {
    Push-Location $RepoRoot
    try {
        Invoke-Native $git @('add', '--', 'runs') | Out-Null
        Invoke-Native $git @('diff', '--cached', '--quiet') -AllowFailure | Out-Null
        if ($script:LastExit -ne 0) {
            Invoke-Native $git @('commit', '-m', $Message) | Out-Null
        }
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            Invoke-Native $git @('pull', '--rebase', '--autostash') -AllowFailure | Out-Null
            if ($script:LastExit -ne 0) {
                Invoke-Native $git @('rebase', '--abort') -AllowFailure | Out-Null
            }
            Invoke-Native $git @('push') -AllowFailure | Out-Null
            if ($script:LastExit -eq 0) { Write-Host '  Pushed to repo.'; return }
            Start-Sleep -Seconds (10 * $attempt)
        }
        Write-Warning 'Push failed. Results are committed locally and will go up with the next successful push.'
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

$plan            = Get-Content $PlanFile -Raw | ConvertFrom-Json
$runs            = @($plan.runs)
$ns              = $plan.namespace
$validatorPod    = $plan.validatorPod
$cooldownSeconds = [int]$plan.cooldownSeconds
$warmupSeconds   = [int]$plan.warmupSeconds
$sampleSeconds   = [int]$plan.sampleSeconds
$template        = Get-Content $TemplateFile -Raw

if (-not (Test-Path $PrivKeyFile)) {
    throw "Spamoor private key not found at $PrivKeyFile. Put it there (outside the repo) and re-run."
}
$privKey = (Get-Content $PrivKeyFile -Raw).Trim()

if (-not $Registry) {
    throw 'Image registry not set. Set $env:IMAGE_REGISTRY (or pass -Registry) and re-run.'
}
$image = '{0}/{1}' -f $Registry.TrimEnd('/'), $plan.image

$runsDir = Join-Path $RepoRoot 'runs'
New-Item -ItemType Directory -Force -Path $runsDir, $WorkRoot | Out-Null

$loadMinutes = ($runs | Measure-Object -Property durationMinutes -Sum).Sum
Write-Host "$($runs.Count) runs, $loadMinutes min of load plus warmup/cooldown per run."

# Remove leftover spamoor pods, including the original hand-made 'spamoor' pod
Invoke-Native $kubectl @('delete', 'pod', '-n', $ns, '-l', 'app=spamoor', '--ignore-not-found', '--wait=true') | Out-Null
Invoke-Native $kubectl @('delete', 'pod', 'spamoor', '-n', $ns, '--ignore-not-found', '--wait=true') | Out-Null

# ---------------------------------------------------------------------------
# Test loop
# ---------------------------------------------------------------------------

$runNumber = 0
foreach ($run in $runs) {
    $runNumber++
    $safeName = ($run.name.ToLower() -replace '[^a-z0-9-]', '-')
    $runId    = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $safeName
    $podName  = "spamoor-$runId"
    if ($podName.Length -gt 63) { $podName = $podName.Substring(0, 63) }
    $podName  = $podName.TrimEnd('-')
    $runDir   = Join-Path $WorkRoot $runId
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null

    Write-Host "`n=== Run $runNumber/$($runs.Count): $runId ($($run.durationMinutes) min) ==="

    $spamoorArgs = @(
        $plan.scenario, '-h', $plan.rpcUrl, '--privkey', $privKey,
        '--slot-duration', $plan.slotDuration,
        '-t', [string]$run.throughput, '--amount', [string]$run.amount
    ) + @($run.extraArgs | Where-Object { $_ })

    $argLines = $spamoorArgs | ForEach-Object { '        - "' + ($_ -replace '"', '\"') + '"' }
    $manifest = $template.Replace('{{NAME}}', $podName).Replace('{{NAMESPACE}}', $ns).Replace('{{IMAGE}}', $image).Replace('{{ARGS}}', ($argLines -join "`n"))

    $meta = [ordered]@{
        runId           = $runId
        name            = $run.name
        image           = $plan.image                                  # without the registry
        durationMinutes = $run.durationMinutes
        throughput      = $run.throughput
        amount          = $run.amount
        spamoorArgs     = @($spamoorArgs | ForEach-Object { if ($_ -eq $privKey) { '<redacted>' } else { $_ } })
        resetNetwork    = [bool]$plan.resetNetwork
        warmupSeconds   = $(if ($plan.resetNetwork) { $warmupSeconds } else { 0 })
        validatorPod    = $validatorPod
    }

    $valLog       = Join-Path $runDir 'validator.log'
    $logProc      = $null
    $spamoorAlive = $false

    try {
        if ($plan.resetNetwork) { Reset-Network }

        $meta.validatorNode           = Get-PodField $validatorPod '{.spec.nodeName}'
        $meta.validatorRestartsBefore = Get-PodField $validatorPod '{.status.containerStatuses[0].restartCount}'

        # 1. Stream the validator's logs (survives kubelet log rotation, which a one-off
        #    'kubectl logs' at the end would not). After a reset the container is fresh,
        #    so take its whole log to include startup; otherwise only from now on.
        $logArgs = @('logs', '-f', '-n', $ns, $validatorPod)
        if (-not $plan.resetNetwork) { $logArgs += '--tail=0' }
        $logProc = Start-Process -FilePath $kubectl -ArgumentList $logArgs `
            -RedirectStandardOutput $valLog -RedirectStandardError "$valLog.stderr" -NoNewWindow -PassThru
        Start-Sleep -Seconds 3
        $meta.logStartUtc = Get-UtcStamp

        # Let the restarted network settle, with the stream running so analysis can
        # check blocks were being produced before load started
        if ($plan.resetNetwork) {
            Write-Host "  Warming up for $warmupSeconds s ..."
            Start-Sleep -Seconds $warmupSeconds
        }

        # 2. Start spamoor
        Invoke-Native $kubectl @('apply', '-f', '-') -InputText $manifest | Out-Null
        $spamoorAlive = $true
        Invoke-Native $kubectl @('wait', '--for=condition=Ready', "pod/$podName", '-n', $ns, '--timeout=10m') | Out-Null
        $meta.spamoorNode  = Get-PodField $podName '{.spec.nodeName}'
        $meta.loadStartUtc = Get-UtcStamp
        Write-Host "  spamoor running on $($meta.spamoorNode); load for $($run.durationMinutes) min ..."

        # 3. Sample CPU/memory until the duration is up
        $topFile = Join-Path $runDir 'top.log'
        $endAt   = (Get-Date).AddMinutes([double]$run.durationMinutes)
        while ((Get-Date) -lt $endAt) {
            $ts = Get-UtcStamp
            Invoke-Native $kubectl @('top', 'pods', '-n', $ns, '--containers', '--no-headers') -AllowFailure |
                ForEach-Object { "$ts $_" } | Add-Content -Path $topFile
            $phase = Get-PodField $podName '{.status.phase}'
            if ($phase -ne 'Running') { Write-Warning "spamoor stopped early (phase: $phase)"; break }
            $left = ($endAt - (Get-Date)).TotalSeconds
            if ($left -gt 0) { Start-Sleep -Seconds ([int][Math]::Ceiling([Math]::Min([double]$sampleSeconds, $left))) }
        }
        $meta.loadEndUtc   = Get-UtcStamp
        $meta.spamoorPhase = Get-PodField $podName '{.status.phase}'

        # 4. Save spamoor's own logs, then stop it
        Save-NativeOutput $kubectl @('logs', '-n', $ns, $podName) (Join-Path $runDir 'spamoor.log')
        Invoke-Native $kubectl @('delete', 'pod', $podName, '-n', $ns, '--wait=true') | Out-Null
        $spamoorAlive = $false

        # 5. Keep logging while the txpool drains
        Write-Host "  Cooldown $cooldownSeconds s ..."
        Start-Sleep -Seconds $cooldownSeconds
    }
    catch {
        $meta.error = "$_"
        Write-Warning "Run $runId hit an error: $_"
    }
    finally {
        $meta.logStreamDiedEarly = [bool]($logProc -and $logProc.HasExited)
        if ($logProc -and -not $logProc.HasExited) { Stop-Process -Id $logProc.Id -Force }
        if ($spamoorAlive) {
            Invoke-Native $kubectl @('delete', 'pod', $podName, '-n', $ns, '--ignore-not-found', '--wait=true') -AllowFailure | Out-Null
        }
    }

    $meta.endUtc                 = Get-UtcStamp
    $meta.validatorRestartsAfter = Get-PodField $validatorPod '{.status.containerStatuses[0].restartCount}'

    # If the validator restarted mid-run, the stream ended with it: grab what we can
    if ($meta.logStreamDiedEarly -and $meta.logStartUtc) {
        Write-Warning 'Validator log stream ended early; saving fallback copies.'
        Save-NativeOutput $kubectl @('logs', '-n', $ns, $validatorPod, "--since-time=$($meta.logStartUtc)") (Join-Path $runDir 'validator-fallback.log')
        if ($meta.validatorRestartsAfter -ne $meta.validatorRestartsBefore) {
            Save-NativeOutput $kubectl @('logs', '-n', $ns, $validatorPod, '--previous') (Join-Path $runDir 'validator-previous.log')
        }
    }
    Remove-EmptyFile "$valLog.stderr"

    $meta | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $runDir 'meta.json') -Encoding UTF8

    # 6. Package and publish
    $zip = Join-Path $WorkRoot "$runId.zip"
    Compress-Archive -Path (Join-Path $runDir '*') -DestinationPath $zip -CompressionLevel Optimal -Force
    $zipMB = [Math]::Round((Get-Item $zip).Length / 1MB, 1)
    if ($zipMB -gt $MaxZipMB) {
        Write-Warning "$runId.zip is $zipMB MB, too large for git. Left in $WorkRoot."
    } else {
        Copy-Item $zip $runsDir
        Write-Host "  Packaged $runId.zip ($zipMB MB)."
        if (-not $NoPush) { Publish-Runs "spamoor run $runId" }
    }
}

Write-Host "`nAll runs done. Local copies are in $WorkRoot."
