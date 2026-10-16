<#
.SYNOPSIS
    Runs the spamoor load tests listed in test-plan.json. For each run it streams one
    validator's logs, samples pod CPU/memory, runs spamoor for the set duration, lets the
    txpool drain, then zips everything into the repo's runs/ folder (and, with -Push,
    commits and pushes it).

.EXAMPLE
    git pull
    .\scripts\Run-SpamoorTests.ps1                   # results go to runs\, not pushed

.EXAMPLE
    .\scripts\Run-SpamoorTests.ps1 txpool-config     # results go to runs\txpool-config\

.EXAMPLE
    .\scripts\Run-SpamoorTests.ps1 -NoReset          # don't restart the network, whatever the plan says

.EXAMPLE
    .\scripts\Run-SpamoorTests.ps1 -Push             # commit and push each result as it finishes
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    # Optional subfolder of runs\ (and of -WorkRoot) to group this batch's results under
    [Parameter(Position = 0)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$Group,
    [string]$PlanFile     = (Join-Path $PSScriptRoot 'test-plan.json'),
    [string]$TemplateFile = (Join-Path $PSScriptRoot 'spamoor-run.template.yml'),
    [string]$RepoRoot     = (Split-Path $PSScriptRoot -Parent),
    [string]$WorkRoot     = (Join-Path $HOME 'spamoor-runs'),
    [string]$PrivKeyFile  = (Join-Path $HOME 'spamoor-privkey.txt'),   # kept outside the repo on purpose
    [string]$Registry     = $env:IMAGE_REGISTRY,                       # registry + path prefix, kept outside the repo
    [int]$MaxZipMB        = 95,                                        # GitHub rejects files over 100 MB
    [switch]$NoReset,                                                  # overrides the plan's resetNetwork
    [switch]$Push                                                      # commit and push each run's zip
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

# Full network restart: scale every statefulset to 0 and wait until every Besu pod is
# gone before bringing any back. Unlike 'rollout restart', no new node can peer with an
# old one (and be handed its pending transactions). Each statefulset is scaled back to 1,
# one pod per Helm release, even if a previous aborted reset left it at 0.
function Reset-Network {
    $sets = @(Invoke-Native $kubectl @('get', 'statefulset', '-n', $ns, '-o', 'name') | Where-Object { $_ })
    Write-Host "  Scaling $($sets.Count) statefulsets in $ns to 0 ..."
    try {
        foreach ($s in $sets) { Invoke-Native $kubectl @('scale', $s, '-n', $ns, '--replicas=0') | Out-Null }
        $deadline = (Get-Date).AddMinutes(10)
        while ($true) {
            $left = @(Invoke-Native $kubectl (@('get', 'pods', '-n', $ns, '--ignore-not-found', '-o', 'name') + $besuPods) |
                Where-Object { $_ } | ForEach-Object { $_ -replace '^pod/', '' })
            if ($left.Count -eq 0) { break }
            if ((Get-Date) -gt $deadline) { throw "Besu pods still running 10 min after scaling to 0: $($left -join ', ')" }
            Write-Host "    waiting for $($left.Count) pod(s) to stop: $($left -join ', ')"
            Start-Sleep -Seconds 5
        }
        Write-Host '  All Besu pods stopped; scaling back to 1 ...'
    } finally {
        # Always bring the network back, even if the scale-down failed part way
        foreach ($s in $sets) { Invoke-Native $kubectl @('scale', $s, '-n', $ns, '--replicas=1') -AllowFailure | Out-Null }
    }
    foreach ($s in $sets) {
        Invoke-Native $kubectl @('rollout', 'status', $s, '-n', $ns, '--timeout=15m') | Out-Null
    }
    Write-Host '  All pods started.'
}

function Get-PlanInt([string]$Name, [int]$Default) {
    $v = $plan.$Name
    if ($null -eq $v) { return $Default }
    return [int]$v
}

# besu-node-validator-1-0 -> validator-1, for progress lines
function Get-ShortName([string]$Pod) { ($Pod -replace '^besu-node-', '') -replace '-0$', '' }

# JSON-RPC call through a local port-forward, with at most one string param. Returns
# 'result'; throws on any failure, including a JSON-RPC error.
function Invoke-Rpc([int]$Port, [string]$Method, [string]$Param) {
    $params = ''
    if ($Param) { $params = '"' + $Param + '"' }
    $body = '{"jsonrpc":"2.0","method":"' + $Method + '","params":[' + $params + '],"id":1}'
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5
    if ($r.error) { throw "$Method failed: $($r.error.message)" }
    return $r.result
}

function ConvertFrom-Hex([string]$Hex) { [Convert]::ToInt64($Hex.Substring(2), 16) }

function Test-LocalPort([int]$Port) {
    $c = New-Object Net.Sockets.TcpClient
    try { return $c.ConnectAsync('127.0.0.1', $Port).Wait(500) } catch { return $false } finally { $c.Close() }
}

# UID of each Besu pod that currently exists, so a forward to a replaced pod is noticed
function Get-PodUids {
    $uids  = @{}
    $lines = Invoke-Native $kubectl (@('get', 'pods', '-n', $ns, '--ignore-not-found', '--no-headers',
            '-o', 'custom-columns=NAME:.metadata.name,UID:.metadata.uid') + $besuPods) -AllowFailure
    foreach ($l in $lines) {
        $f = "$l".Trim() -split '\s+'
        if ($f.Count -eq 2) { $uids[$f[0]] = $f[1] }
    }
    return $uids
}

function Save-PodLog([string]$Pod, [string]$Since, [string]$Path) {
    Save-NativeOutput $kubectl @('logs', '-n', $ns, $Pod, "--since-time=$Since") $Path
}

# Polls every Besu pod's RPC (through kubectl port-forward) until each is connected to all
# of its static peers and within $maxBlocksBehind of the best head, and the best head has
# advanced $minNewBlocks since polling began. A pod missing static peers is asked to dial
# them (admin_addPeer) on every poll. Prints one progress line per poll and gives up after
# $healthTimeoutSeconds. Returns Healthy, Stalled (chain not advancing), Bad (pods failing
# their own checks), Missing, Peers and Heads.
function Wait-NetworkHealthy {
    $forwards  = @{}   # pod -> @{ Proc; Uid; Port }
    $startHead = $null
    $t0        = Get-Date
    try {
        while ($true) {
            # Keep one forward per pod across polls; replace it if kubectl exited or the
            # pod was replaced
            $uids    = Get-PodUids
            $started = @()
            for ($i = 0; $i -lt $besuPods.Count; $i++) {
                $pod = $besuPods[$i]
                $f   = $forwards[$pod]
                if ($f -and ($f.Proc.HasExited -or $f.Uid -ne $uids[$pod])) {
                    if (-not $f.Proc.HasExited) { Stop-Process -Id $f.Proc.Id -Force }
                    $forwards.Remove($pod)
                    $f = $null
                }
                if (-not $f -and $uids.ContainsKey($pod)) {
                    $port = $rpcLocalPortBase + $i
                    $proc = Start-Process -FilePath $kubectl -WindowStyle Hidden -PassThru `
                        -ArgumentList @('port-forward', '-n', $ns, "pod/$pod", "${port}:$rpcPort")
                    $forwards[$pod] = @{ Proc = $proc; Uid = $uids[$pod]; Port = $port }
                    $started += $port
                }
            }
            # kubectl takes ~5 s to start listening on the VDS
            $readyBy = (Get-Date).AddSeconds(15)
            while ($started.Count -gt 0 -and (Get-Date) -lt $readyBy) {
                $started = @($started | Where-Object { -not (Test-LocalPort $_) })
                if ($started.Count -gt 0) { Start-Sleep -Milliseconds 500 }
            }

            $peers = @{}   # pod -> pods it's connected to
            $heads = @{}
            foreach ($pod in $besuPods) {
                if (-not $forwards[$pod]) { continue }
                $port = $forwards[$pod].Port
                try {
                    $peers[$pod] = @(Invoke-Rpc $port 'admin_peers' | ForEach-Object {
                        if ($_.enode -match '^enode://([0-9a-fA-F]+)@') { $podByKey[$Matches[1].ToLower()] }
                    } | Where-Object { $_ })
                    $heads[$pod] = ConvertFrom-Hex (Invoke-Rpc $port 'eth_blockNumber')
                } catch {
                    $peers.Remove($pod)
                    $heads.Remove($pod)
                }
            }

            $best = ($heads.Values | Measure-Object -Maximum).Maximum
            if ($null -ne $best -and $null -eq $startHead) { $startHead = $best }
            $newBlocks = 0
            if ($null -ne $startHead) { $newBlocks = $best - $startHead }

            $missing = @{}   # pod -> static peers it isn't connected to
            $bad     = @()
            foreach ($pod in $besuPods) {
                if (-not $heads.ContainsKey($pod)) { $bad += $pod; continue }
                $connected     = $peers[$pod]
                $missing[$pod] = @($expectedPeers[$pod] | Where-Object { $connected -notcontains $_ })
                if ($missing[$pod].Count -gt 0 -or $heads[$pod] -lt ($best - $maxBlocksBehind)) { $bad += $pod }
            }

            $parts = foreach ($pod in $besuPods) {
                $s = Get-ShortName $pod
                if ($heads.ContainsKey($pod)) {
                    $s += " $($peers[$pod].Count)p #$($heads[$pod])"
                    if ($missing[$pod].Count -gt 0) { $s += ' missing ' + (($missing[$pod] | ForEach-Object { Get-ShortName $_ }) -join ',') }
                } else {
                    $s += ' no-rpc'
                }
                if ($bad -contains $pod) { $s += ' !' }
                $s
            }
            $elapsed = (Get-Date) - $t0
            Write-Host ('  [{0:mm\:ss}] {1} | +{2}/{3} blocks' -f $elapsed, ($parts -join ' | '), $newBlocks, $minNewBlocks)

            $healthy = ($bad.Count -eq 0 -and $newBlocks -ge $minNewBlocks)
            if ($healthy -or $elapsed.TotalSeconds -ge $healthTimeoutSeconds) {
                return @{
                    Healthy = $healthy; Stalled = ($newBlocks -lt $minNewBlocks); Bad = $bad
                    Missing = $missing; Peers = $peers; Heads = $heads
                }
            }

            # Ask each pod to dial the static peers it's missing. Both ends of a missing
            # link get asked; Besu keeps a single connection per peer.
            foreach ($pod in @($missing.Keys)) {
                foreach ($other in $missing[$pod]) {
                    try { Invoke-Rpc $forwards[$pod].Port 'admin_addPeer' $staticEnode[$other] | Out-Null } catch { }
                }
            }
            Start-Sleep -Seconds $healthPollSeconds
        }
    } finally {
        foreach ($f in $forwards.Values) { if (-not $f.Proc.HasExited) { Stop-Process -Id $f.Proc.Id -Force } }
    }
}

# Waits for a healthy network, escalating up to $maxFixups times if it isn't healthy in
# time. A stalled chain gets a full network reset: QBFT round timers double each round, so
# stalled validators can sit in one round for many minutes, and a single restarted
# validator starts back at round 0, out of step with the rest. A chain that's advancing
# with one unhealthy pod gets just that pod restarted (never two at once, so QBFT keeps
# quorum). Saves the logs of the pods involved into $RunDir. Throws if still unhealthy.
function Confirm-NetworkHealthy([string]$RunDir, [string]$Since) {
    $t0     = Get-Date
    $fixups = @()
    while ($true) {
        Write-Host "  Waiting for network health (every pod peered with all its static peers, chain +$minNewBlocks blocks; timeout $healthTimeoutSeconds s) ..."
        $h = Wait-NetworkHealthy
        if ($h.Healthy) { break }

        $n = $fixups.Count + 1
        if ($h.Stalled) { $why = 'chain not advancing' } else { $why = "unhealthy: $($h.Bad -join ', ')" }
        if ($fixups.Count -ge $maxFixups) {
            $suspects = @($h.Bad)
            if ($h.Stalled -or $suspects.Count -eq 0) { $suspects = $besuPods }
            foreach ($pod in $suspects) { Save-PodLog $pod $Since (Join-Path $RunDir "unhealthy-$pod.log") }
            throw "Network not healthy after $($fixups.Count) fix-up(s) ($($fixups -join ', ')); $why"
        }

        if ($h.Stalled) {
            Write-Warning "Chain not advancing; resetting the whole network (fix-up $n of $maxFixups)"
            foreach ($pod in $besuPods) { Save-PodLog $pod $Since (Join-Path $RunDir "fixup-$n-$pod.log") }
            Reset-Network
            $fixups += 'reset'
        } else {
            # No RPC answer first, then the most missing peers
            $pod = $h.Bad | Sort-Object { if ($h.Missing.ContainsKey($_)) { -$h.Missing[$_].Count } else { -999 } } |
                Select-Object -First 1
            Write-Warning "$pod is unhealthy ($why); restarting it (fix-up $n of $maxFixups)"
            Save-PodLog $pod $Since (Join-Path $RunDir "fixup-$n-$pod.log")
            Invoke-Native $kubectl @('delete', 'pod', $pod, '-n', $ns, '--wait=true') | Out-Null
            $fixups += $pod
        }
    }
    Write-Host "  Network healthy after $([int]((Get-Date) - $t0).TotalSeconds) s."
    return [ordered]@{
        secondsToHealthy = [int]((Get-Date) - $t0).TotalSeconds
        fixups           = $fixups
        peers            = $h.Peers
        heads            = $h.Heads
    }
}

# Commits just the given zip (not anything else under runs\, such as unzipped copies)
# and pushes, along with any earlier commits whose push failed
function Publish-Run([string]$ZipPath, [string]$Message) {
    Push-Location $RepoRoot
    try {
        Invoke-Native $git @('add', '--', $ZipPath) | Out-Null
        Invoke-Native $git @('diff', '--cached', '--quiet', '--', $ZipPath) -AllowFailure | Out-Null
        if ($script:LastExit -ne 0) {
            # Pathspec so anything else you've staged by hand stays out of this commit
            Invoke-Native $git @('commit', '-m', $Message, '--', $ZipPath) | Out-Null
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

$doReset = [bool]$plan.resetNetwork -and -not $NoReset

# Health check before each run's load: see Wait-NetworkHealthy
$healthTimeoutSeconds = Get-PlanInt 'healthTimeoutSeconds' 300
$maxFixups            = Get-PlanInt 'maxFixups' 2
$minNewBlocks         = 5
$maxBlocksBehind      = 2
$healthPollSeconds    = 10
$rpcPort              = 8545
$rpcLocalPortBase     = 18545
$peersConfigMap       = 'besu-peers'

$besuPods = @((Invoke-Native $kubectl @('get', 'pods', '-n', $ns, '-l', 'app.kubernetes.io/component=besu',
            '-o', 'jsonpath={.items[*].metadata.name}')) -join ' ' -split '\s+' | Where-Object { $_ } | Sort-Object)
if ($besuPods.Count -eq 0) { throw "No Besu pods (app.kubernetes.io/component=besu) found in $ns." }

# Static peers, from the configmap every Besu pod mounts. The pod name is the first label
# of each enode's host; the public key maps admin_peers results back to pods.
$staticJson = (Invoke-Native $kubectl @('get', 'configmap', $peersConfigMap, '-n', $ns,
            '-o', 'jsonpath={.data.static-nodes\.json}')) -join "`n"
$staticEnode = @{}   # pod -> enode URL
$podByKey    = @{}   # lowercase public key -> pod
foreach ($e in ($staticJson | ConvertFrom-Json)) {
    if ($e -match '^enode://([0-9a-fA-F]+)@([^.:]+)') {
        $staticEnode[$Matches[2]] = $e
        $podByKey[$Matches[1].ToLower()] = $Matches[2]
    }
}
if ($staticEnode.Count -eq 0) { throw "No enodes found in configmap $peersConfigMap." }
$expectedPeers = @{}   # pod -> the other running pods it should be connected to
foreach ($p in $besuPods) {
    $expectedPeers[$p] = @($besuPods | Where-Object { $_ -ne $p -and $staticEnode.ContainsKey($_) })
}

$runsDir = Join-Path $RepoRoot 'runs'
$workDir = $WorkRoot
if ($Group) {
    $runsDir = Join-Path $runsDir $Group
    $workDir = Join-Path $WorkRoot $Group
}
New-Item -ItemType Directory -Force -Path $runsDir, $workDir | Out-Null

$loadMinutes = ($runs | Measure-Object -Property durationMinutes -Sum).Sum
Write-Host "$($runs.Count) runs, $loadMinutes min of load plus setup/cooldown per run."
Write-Host "Network reset before each run: $doReset. Results go to $runsDir."
Write-Host "Health check covers: $($besuPods -join ', ')"

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
    $runDir   = Join-Path $workDir $runId
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
        group           = $Group
        name            = $run.name
        image           = $plan.image                                  # without the registry
        durationMinutes = $run.durationMinutes
        throughput      = $run.throughput
        amount          = $run.amount
        spamoorArgs     = @($spamoorArgs | ForEach-Object { if ($_ -eq $privKey) { '<redacted>' } else { $_ } })
        resetNetwork    = $doReset
        validatorPod    = $validatorPod
    }

    $valLog       = Join-Path $runDir 'validator.log'
    $logProc      = $null
    $spamoorAlive = $false

    try {
        # validator.log covers everything from here: reset, health check, warmup, load, cooldown
        $meta.logStartUtc = Get-UtcStamp

        # 1. Get to a healthy network: optional full restart, then wait for peers and
        #    block production, restarting single stuck pods if needed
        if ($doReset) { Reset-Network }
        $meta.health     = Confirm-NetworkHealthy $runDir $meta.logStartUtc
        $meta.healthyUtc = Get-UtcStamp

        $meta.validatorNode           = Get-PodField $validatorPod '{.spec.nodeName}'
        $meta.validatorRestartsBefore = Get-PodField $validatorPod '{.status.containerStatuses[0].restartCount}'

        # 2. Stream the validator's logs (survives kubelet log rotation, which a one-off
        #    'kubectl logs' at the end would not). --since-time backfills the reset and
        #    health check, including the startup of a container restarted since then.
        $logProc = Start-Process -FilePath $kubectl -NoNewWindow -PassThru `
            -ArgumentList @('logs', '-f', '-n', $ns, $validatorPod, "--since-time=$($meta.logStartUtc)") `
            -RedirectStandardOutput $valLog -RedirectStandardError "$valLog.stderr"
        Start-Sleep -Seconds 3

        # Let a restarted network or pod settle before load
        $meta.warmupSeconds = 0
        if ($doReset -or $meta.health.fixups.Count -gt 0) {
            $meta.warmupSeconds = $warmupSeconds
            Write-Host "  Warming up for $warmupSeconds s ..."
            Start-Sleep -Seconds $warmupSeconds
        }

        # 3. Start spamoor
        Invoke-Native $kubectl @('apply', '-f', '-') -InputText $manifest | Out-Null
        $spamoorAlive = $true
        Invoke-Native $kubectl @('wait', '--for=condition=Ready', "pod/$podName", '-n', $ns, '--timeout=10m') | Out-Null
        $meta.spamoorNode  = Get-PodField $podName '{.spec.nodeName}'
        $meta.loadStartUtc = Get-UtcStamp
        Write-Host "  spamoor running on $($meta.spamoorNode); load for $($run.durationMinutes) min ..."

        # 4. Sample CPU/memory until the duration is up
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

        # 5. Save spamoor's own logs, then stop it
        Save-NativeOutput $kubectl @('logs', '-n', $ns, $podName) (Join-Path $runDir 'spamoor.log')
        Invoke-Native $kubectl @('delete', 'pod', $podName, '-n', $ns, '--wait=true') | Out-Null
        $spamoorAlive = $false

        # 6. Keep logging while the txpool drains
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

    # 7. Package and publish
    $zip = Join-Path $workDir "$runId.zip"
    Compress-Archive -Path (Join-Path $runDir '*') -DestinationPath $zip -CompressionLevel Optimal -Force
    $zipMB = [Math]::Round((Get-Item $zip).Length / 1MB, 1)
    if ($zipMB -gt $MaxZipMB) {
        Write-Warning "$runId.zip is $zipMB MB, too large for git. Left in $workDir."
    } else {
        Copy-Item $zip $runsDir
        Write-Host "  Packaged $runId.zip ($zipMB MB)."
        $label = $runId
        if ($Group) { $label = "$Group/$runId" }
        if ($Push) { Publish-Run (Join-Path $runsDir "$runId.zip") "spamoor run $label" }
    }
}

Write-Host "`nAll runs done. Local copies are in $workDir."
