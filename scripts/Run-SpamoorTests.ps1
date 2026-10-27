<#
.SYNOPSIS
    Runs the spamoor load tests listed in test-plan.json. For each run it streams every
    validator's logs, samples pod CPU/memory, runs spamoor for the set duration, lets the
    txpool drain, and leaves the results in a folder per run under the repo's runs/
    folder (optionally zipped too; with -Push, the zip is committed and pushed).

.EXAMPLE
    git pull
    .\scripts\Run-SpamoorTests.ps1                   # results go to runs\<runId>\, not zipped or pushed

.EXAMPLE
    .\scripts\Run-SpamoorTests.ps1 txpool-config     # results go to runs\txpool-config\<runId>\

.EXAMPLE
    .\scripts\Run-SpamoorTests.ps1 -NoReset          # don't restart the network, whatever the plan says

.EXAMPLE
    .\scripts\Run-SpamoorTests.ps1 -Zip              # also zip each run folder, as runs\<runId>.zip

.EXAMPLE
    .\scripts\Run-SpamoorTests.ps1 -Push             # zip, then commit and push each zip as it finishes
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    # Optional subfolder of runs\ to group this batch's results under
    [Parameter(Position = 0)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$Group,
    [string]$PlanFile     = (Join-Path $PSScriptRoot 'test-plan.json'),
    [string]$TemplateFile = (Join-Path $PSScriptRoot 'spamoor-run.template.yml'),
    [string]$RepoRoot     = (Split-Path $PSScriptRoot -Parent),
    [string]$PrivKeyFile  = (Join-Path $HOME 'spamoor-privkey.txt'),   # kept outside the repo on purpose
    [string]$Registry     = $env:IMAGE_REGISTRY,                       # registry + path prefix, kept outside the repo
    [int]$MaxZipMB        = 95,                                        # -Push skips larger zips: GitHub rejects files over 100 MB
    [switch]$NoReset,                                                  # overrides the plan's resetNetwork
    [switch]$Zip,                                                      # also zip each run folder
    [switch]$Push                                                      # zip, then commit and push each run's zip
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

# JSON-RPC call through a local port-forward. $ParamsJson is the inside of the params
# array, e.g. '"0x10",false'. Returns 'result'; throws on any failure, including a
# JSON-RPC error.
function Invoke-Rpc([int]$Port, [string]$Method, [string]$ParamsJson = '') {
    $body = '{"jsonrpc":"2.0","method":"' + $Method + '","params":[' + $ParamsJson + '],"id":1}'
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5
    if ($r.error) { throw "$Method failed: $($r.error.message)" }
    return $r.result
}

function ConvertFrom-Hex([string]$Hex) { [Convert]::ToInt64($Hex.Substring(2), 16) }

function Test-LocalPort([int]$Port) {
    $c = New-Object Net.Sockets.TcpClient
    try { return $c.ConnectAsync('127.0.0.1', $Port).Wait(500) } catch { return $false } finally { $c.Close() }
}

# Starts a port-forward to one pod and waits for it to listen; returns the process
function Start-Forward([string]$Pod, [int]$Port) {
    $proc = Start-Process -FilePath $kubectl -WindowStyle Hidden -PassThru `
        -ArgumentList @('port-forward', '-n', $ns, "pod/$Pod", "${Port}:$rpcPort")
    $readyBy = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $readyBy -and -not $proc.HasExited) {
        if (Test-LocalPort $Port) { return $proc }
        Start-Sleep -Milliseconds 500
    }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    throw "port-forward to $Pod didn't start listening"
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

# Follows a pod's logs into $Path in the background, from $Since (or the container's
# start). Survives kubelet log rotation, which a one-off 'kubectl logs' at the end would
# not. Ends by itself when the container stops.
function Start-LogStream([string]$Pod, [string]$Path, [string]$Since) {
    $a = @('logs', '-f', '-n', $ns, $Pod)
    if ($Since) { $a += "--since-time=$Since" }
    Start-Process -FilePath $kubectl -NoNewWindow -PassThru -ArgumentList $a `
        -RedirectStandardOutput $Path -RedirectStandardError "$Path.stderr"
}

# Gives a stream up to $WaitSeconds to finish by itself (its container stopping), then kills it
function Stop-LogStream($Proc, [int]$WaitSeconds = 0) {
    if (-not $Proc) { return }
    if ($WaitSeconds -gt 0 -and -not $Proc.HasExited) { $Proc.WaitForExit($WaitSeconds * 1000) | Out-Null }
    if (-not $Proc.HasExited) { Stop-Process -Id $Proc.Id -Force }
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

            $healthy = ($bad.Count -eq 0 -and $newBlocks -ge $minNewBlocks)
            if ($healthy -or $elapsed.TotalSeconds -ge $healthTimeoutSeconds) {
                # Peer state is only worth showing when it explains a timeout
                if (-not $healthy) {
                    Write-Host ('  [{0:mm\:ss}] {1} | +{2}/{3} blocks' -f $elapsed, ($parts -join ' | '), $newBlocks, $minNewBlocks)
                }
                return @{
                    Healthy = $healthy; Stalled = ($newBlocks -lt $minNewBlocks); Bad = $bad
                    Missing = $missing; Peers = $peers; Heads = $heads
                }
            }

            # Ask each pod to dial the static peers it's missing. Both ends of a missing
            # link get asked; Besu keeps a single connection per peer.
            foreach ($pod in @($missing.Keys)) {
                foreach ($other in $missing[$pod]) {
                    try { Invoke-Rpc $forwards[$pod].Port 'admin_addPeer' ('"' + $staticEnode[$other] + '"') | Out-Null } catch { }
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

# ---------------------------------------------------------------------------
# Run summary: results don't come back through git, so each run prints what's needed
# to compare runs from the console output
# ---------------------------------------------------------------------------

function ConvertTo-Unix([string]$Utc) { [DateTimeOffset]::Parse($Utc).ToUnixTimeSeconds() }

# '2s', '500ms', '1m' -> seconds
function ConvertTo-Seconds([string]$Duration) {
    if ($Duration -notmatch '^([\d.]+)\s*(ms|s|m)?$') { throw "Can't parse duration '$Duration'" }
    $factor = @{ 'ms' = 0.001; 's' = 1; 'm' = 60; '' = 1 }[[string]$Matches[2]]
    return [double]$Matches[1] * $factor
}

# kubectl top values and pod limits: '512m' or '2' cores; '1650Mi', '2Gi', '2G' -> cores / MiB
function ConvertFrom-Cpu([string]$s) {
    if ($s -match '^(\d+)m$') { return [double]$Matches[1] / 1000 }
    if ($s -match '^[\d.]+$') { return [double]$s }
    return $null
}
function ConvertFrom-Mem([string]$s) {
    if ($s -cnotmatch '^([\d.]+)(Ki|Mi|Gi|Ti|k|M|G|T)?$') { return $null }
    $factor = @{
        'Ki' = 1 / 1024; 'Mi' = 1; 'Gi' = 1024; 'Ti' = 1048576; '' = 1 / 1MB
        'k' = 1e3 / 1MB; 'M' = 1e6 / 1MB; 'G' = 1e9 / 1MB; 'T' = 1e12 / 1MB
    }[[string]$Matches[2]]
    return [double]$Matches[1] * $factor
}
function Format-Mem([double]$MiB) {
    if ($MiB -ge 1024) { return '{0:N1}Gi' -f ($MiB / 1024) }
    return '{0:N0}Mi' -f $MiB
}

# CPU/memory limits of every container in the namespace, keyed '<pod>/<container>' to
# match top.log. Missing limits are $null. Empty if kubectl fails.
function Get-ContainerLimits {
    $limits = [ordered]@{}
    $json = (Invoke-Native $kubectl @('get', 'pods', '-n', $ns, '-o', 'json') -AllowFailure) -join "`n"
    if ($script:LastExit -ne 0) { return $limits }
    try { $items = ($json | ConvertFrom-Json).items } catch { return $limits }
    foreach ($p in $items) {
        foreach ($c in $p.spec.containers) {
            $l = $c.resources.limits
            $limits["$($p.metadata.name)/$($c.name)"] = [ordered]@{ cpu = $l.cpu; memory = $l.memory }
        }
    }
    return $limits
}

function Format-Gas([double]$Gas) {
    if ($Gas -ge 1e9) { return '{0:N1} Ggas' -f ($Gas / 1e9) }
    return '{0:N1} Mgas' -f ($Gas / 1e6)
}

# Blocks from the current head back to the first one stamped at or after $FromUnix,
# oldest first
function Get-BlocksSince([int]$Port, [long]$FromUnix) {
    $blocks = New-Object System.Collections.Generic.List[object]
    $n = ConvertFrom-Hex (Invoke-Rpc $Port 'eth_blockNumber')
    while ($n -ge 0 -and $blocks.Count -lt 20000) {
        $b  = Invoke-Rpc $Port 'eth_getBlockByNumber' ('"0x{0:x}",false' -f $n)
        $ts = ConvertFrom-Hex $b.timestamp
        if ($ts -lt $FromUnix) { break }
        $gas      = ConvertFrom-Hex $b.gasUsed
        $gasLimit = ConvertFrom-Hex $b.gasLimit
        $blocks.Add([pscustomobject]@{
            Number   = $n
            Time     = $ts
            Txs      = @($b.transactions).Count
            Gas      = $gas
            GasLimit = $gasLimit
            GasPct   = 100.0 * $gas / $gasLimit
        })
        $n--
    }
    $blocks.Reverse()
    return , $blocks.ToArray()
}

# avg, p50, p95 and max of a set of numbers (nearest-rank percentiles)
function Get-Spread([double[]]$Values) {
    $s = [double[]]$Values.Clone()
    [Array]::Sort($s)
    $at = { param($p) $s[[int][Math]::Ceiling($p / 100 * $s.Count) - 1] }
    [pscustomobject]@{ Avg = ($s | Measure-Object -Average).Average; P50 = & $at 50; P95 = & $at 95; Max = $s[-1] }
}

# One pass over a Besu log: its per-block 'Produced #N ...' / 'Imported #N ...' lines,
# keyed by block number, and its WARN/ERROR lines. All versions log the txpool size
# ('N pending'); newer ones add the proposer's build time ('gas in 2.378s') and
# 'Timing(..., txsSelection=551ms, ...)'. Phase names are read from the line rather than
# fixed, so phases added or renamed in later releases still show up. Returns Entries,
# Phases, Warn, Error and Messages (WARN/ERROR message -> count, with numbers and hashes
# blanked so repeats group together).
function Read-BesuLog([string]$Path) {
    $entries  = @{}
    $phases   = New-Object System.Collections.Generic.List[string]   # in first-seen order
    $messages = @{}
    $warn     = 0
    $err      = 0
    $level    = [regex]'\b(WARN|ERROR)\b'
    foreach ($l in [IO.File]::ReadLines($Path)) {
        $isBlock = $l.Contains(' pending')
        if (-not ($isBlock -or $l.Contains('WARN') -or $l.Contains('ERROR'))) { continue }
        $l = $l -replace $ansiEscape, ''   # Besu colours its console log; 'ESC[32mProduced' has no \b
        $m = $level.Match($l)
        if ($m.Success) {
            if ($m.Groups[1].Value -eq 'WARN') { $warn++ } else { $err++ }
            $msg = $m.Value + ' ' + ($l.Substring($m.Index + $m.Length) -replace '^[\s|]+', '' -replace '0x[0-9a-fA-F]+', '0x..' -replace '\d+', 'N')
            if ($msg.Length -gt 110) { $msg = $msg.Substring(0, 110) }
            $messages[$msg] = 1 + [int]$messages[$msg]
            continue
        }
        if (-not $isBlock -or $l -cnotmatch '\b(Produced|Imported)\b[^#]*#(\d[\d,.]*)') { continue }
        $kind = $Matches[1]
        $num  = [long]($Matches[2] -replace '\D', '')
        if ($kind -eq 'Imported' -and $entries[$num] -and $entries[$num].Kind -eq 'Produced') { continue }
        $e = [pscustomobject]@{ Kind = $kind; Pending = $null; Total = $null; Phases = $null }
        if ($l -match '\b(\d[\d,.]*) pending\b') { $e.Pending = [long]($Matches[1] -replace '\D', '') }
        if ($kind -eq 'Produced') {
            if ($l -match '\sin\s+([\d.]+\s*m?s)\b') { $e.Total = 1000 * (ConvertTo-Seconds $Matches[1]) }
            if ($l -match 'Timing\(([^)]*)\)') {
                $e.Phases = [ordered]@{}
                foreach ($pm in [regex]::Matches($Matches[1], '(\w+)=([\d.]+\s*m?s)\b')) {
                    $name = $pm.Groups[1].Value
                    $e.Phases[$name] = 1000 * (ConvertTo-Seconds $pm.Groups[2].Value)
                    if (-not $phases.Contains($name)) { $phases.Add($name) }
                }
            }
        }
        $entries[$num] = $e
    }
    return @{ Entries = $entries; Phases = $phases.ToArray(); Warn = $warn; Error = $err; Messages = $messages }
}

# Build-time table (total and each Timing phase) over $Timed (Time + E, a Read-BesuLog
# entry), from $SteadyFrom (unix time) on if given, with the untrimmed total alongside.
# Returns Lines, and Avg, P95 and OverPct of the total ($null if no block logged one).
function Get-BuildTimingTable($Timed, [string[]]$Phases, $SteadyFrom, [string]$Head) {
    $lines  = New-Object System.Collections.Generic.List[string]
    $out    = @{ Lines = $lines; Avg = $null; P95 = $null; OverPct = $null }
    $steady = $Timed
    $label  = "ms, whole load ($($Timed.Count) blocks)"
    if ($SteadyFrom) {
        $s = @($Timed | Where-Object { $_.Time -ge $SteadyFrom })
        if ($s.Count -gt 0) { $steady = $s; $label = "ms, after first 2 min ($($s.Count) blocks)" }
    }
    $totals = @($steady | Where-Object { $null -ne $_.E.Total } | ForEach-Object { $_.E.Total })
    $rows = @()
    if ($totals.Count -gt 0) { $rows += , @('total', $totals) }
    $zero = @()
    foreach ($p in $Phases) {
        $v = @($steady | Where-Object { $_.E.Phases -and $_.E.Phases.Contains($p) } | ForEach-Object { $_.E.Phases[$p] })
        if ($v.Count -eq 0) { continue }
        if (($v | Measure-Object -Maximum).Maximum -eq 0) { $zero += $p; continue }
        $name = $p
        if ($timingSubPhases -contains $p) { $name = "  $p" }
        $rows += , @($name, $v)
    }
    $w = 2 + [Math]::Max($label.Length, [int]($rows | ForEach-Object { $_[0].Length } | Measure-Object -Maximum).Maximum)
    $lines.Add("${Head}:")
    $lines.Add('  ' + $label.PadRight($w) + ('{0,7}{1,7}{2,7}{3,7}' -f 'avg', 'p50', 'p95', 'max'))
    foreach ($r in $rows) {
        $sp = Get-Spread $r[1]
        $lines.Add('  ' + $r[0].PadRight($w) + ('{0,7:N0}{1,7:N0}{2,7:N0}{3,7:N0}' -f $sp.Avg, $sp.P50, $sp.P95, $sp.Max))
    }
    if ($zero.Count -gt 0) { $lines.Add('  0 ms throughout: ' + ($zero -join ', ')) }
    if ($totals.Count -gt 0) {
        $slotMs = 1000 * (ConvertTo-Seconds $plan.slotDuration)
        $sp     = Get-Spread $totals
        $over   = @($totals | Where-Object { $_ -gt $slotMs }).Count
        $msg    = '  over {0} slot: {1} of {2} ({3:N0}%)' -f $plan.slotDuration, $over, $totals.Count, (100.0 * $over / $totals.Count)
        $all    = @($Timed | Where-Object { $null -ne $_.E.Total } | ForEach-Object { $_.E.Total })
        if ($all.Count -ne $totals.Count) {
            $spAll = Get-Spread $all
            $msg += '; untrimmed total avg {0:N0}, p95 {1:N0}, over slot {2} of {3}' -f $spAll.Avg, $spAll.P95, @($all | Where-Object { $_ -gt $slotMs }).Count, $all.Count
        }
        $lines.Add($msg)
        $out.Avg     = $sp.Avg
        $out.P95     = $sp.P95
        $out.OverPct = 100.0 * $over / $totals.Count
    }
    return $out
}

# Every validator's log (<validator>.log): build timings of the load blocks, pooled across
# the validators that proposed them, then one line per validator (its own blocks' timings,
# its txpool size after each load block, restarts, WARN/ERROR counts) and the most common
# WARN/ERROR messages across all of them. Each validator's own timing table and messages
# go in Detail (validators.txt). Timings are from $SteadyFrom (unix time) on if given.
# $Load may be empty (no load phase): restarts and log warnings are still reported.
# Returns Lines, Detail, Notes and the batch table's BuildMs (avg/p95), OverSlot and MaxPending.
function Get-ValidatorSummary($Load, $SteadyFrom, $Meta, [string]$RunDir) {
    $lines  = New-Object System.Collections.Generic.List[string]
    $detail = New-Object System.Collections.Generic.List[string]
    $out    = @{ Lines = $lines; Detail = $detail; Notes = @(); BuildMs = ''; OverSlot = ''; MaxPending = '' }
    $logs   = [ordered]@{}   # validator -> Read-BesuLog, for those with a log
    foreach ($pod in $Meta.validatorPods) {
        $path = Join-Path $RunDir "$(Get-ShortName $pod).log"
        if (Test-Path $path) { $logs[$pod] = Read-BesuLog $path }
    }
    $phases = @($logs.Values | ForEach-Object { $_.Phases } | Select-Object -Unique)

    # Each load block's Produced line, from whichever validator proposed it
    $produced = @(foreach ($b in $Load) {
        foreach ($pod in $logs.Keys) {
            $e = $logs[$pod].Entries[$b.Number]
            if ($e -and $e.Kind -eq 'Produced') { [pscustomobject]@{ Time = $b.Time; E = $e; Pod = $pod }; break }
        }
    })
    $timed = @($produced | Where-Object { $null -ne $_.E.Total -or $_.E.Phases })
    if ($Load.Count -ge 2) {
        $head = "Block production (all validators; Produced lines for $($produced.Count) of $($Load.Count) load blocks)"
        if ($produced.Count -eq 0) {
            $lines.Add('Block production: no Produced lines for load blocks in the validator logs')
        } elseif ($timed.Count -eq 0) {
            $lines.Add("$head; no build timings in the logs (older Besu)")
        } else {
            $t = Get-BuildTimingTable $timed $phases $SteadyFrom $head
            foreach ($l in $t.Lines) { $lines.Add($l) }
            if ($null -ne $t.Avg) {
                $out.BuildMs  = '{0:N0}/{1:N0}' -f $t.Avg, $t.P95
                $out.OverSlot = '{0:N0}%' -f $t.OverPct
            }
        }
    }

    $before = $Meta.validatorRestartsBefore
    if (-not $before) { $before = @{} }
    $after = $Meta.validatorRestartsAfter
    if (-not $after) { $after = @{} }
    $died = $Meta.logStreamDiedEarly
    if (-not $died) { $died = @{} }
    if ($logs.Count -eq 0 -and $before.Count -eq 0) {
        $lines.Add('No validator logs.')   # abandoned before the streams started
        return $out
    }
    $lines.Add('Per validator (more in validators.txt; prop = load blocks proposed, build = ms avg/p95, pend = txpool max/at load end):')
    $maxPend = $null
    $stalls  = @()   # From/To index into $Load, Pod, Pending
    foreach ($pod in $Meta.validatorPods) {
        $short = Get-ShortName $pod
        $detail.Add("--- $short ---")
        $rs = "restarts $($before[$pod])->$($after[$pod])"
        if (($null -ne $before[$pod] -and $before[$pod] -ne $after[$pod]) -or $died[$pod]) {
            $rs += ' RESTARTED MID-RUN'
            $out.Notes += "$short restarted"
        }
        $log = $logs[$pod]
        if (-not $log) {
            $lines.Add(('  {0,-12} no log; {1}' -f $short, $rs))
            $detail.Add("No log; $rs")
            continue
        }
        $parts = @()
        if ($Load.Count -ge 2) {
            $own      = @($produced | Where-Object { $_.Pod -eq $pod })
            $ownTimed = @($timed | Where-Object { $_.Pod -eq $pod })
            $ownHead  = "Block production ($short proposed $($own.Count) of $($Load.Count) load blocks)"
            $parts   += "prop $($own.Count)"
            if ($ownTimed.Count -gt 0) {
                $t = Get-BuildTimingTable $ownTimed $phases $SteadyFrom $ownHead
                foreach ($l in $t.Lines) { $detail.Add($l) }
                if ($null -ne $t.Avg) { $parts += 'build {0:N0}/{1:N0} over {2:N0}%' -f $t.Avg, $t.P95, $t.OverPct }
            } else {
                $detail.Add("$ownHead; no build timings")
            }
            $pend = @(foreach ($b in $Load) {
                $e = $log.Entries[$b.Number]
                if ($e -and $null -ne $e.Pending) { $e.Pending }
            })
            if ($pend.Count -gt 0) {
                $pm = $pend | Measure-Object -Average -Maximum
                $parts += 'pend {0:N0}/{1:N0}' -f $pm.Maximum, $pend[-1]
                $detail.Add(('Txpool pending ({0} of {1} load blocks): avg {2:N0}, max {3:N0}, at load end {4:N0}' -f
                        $pend.Count, $Load.Count, $pm.Average, $pm.Maximum, $pend[-1]))
                if (-not $maxPend -or $pm.Maximum -gt $maxPend.Value) { $maxPend = @{ Value = $pm.Maximum; Pod = $short } }
            }
            # Stalls: $stallBlocks+ consecutive load blocks with 0 txs while this validator's
            # pending count stays the same (and above 0): txs waiting that no proposer includes
            $from = -1
            $flat = $null
            for ($i = 0; $i -le $Load.Count; $i++) {
                $p = $null
                if ($i -lt $Load.Count -and $Load[$i].Txs -eq 0) {
                    $e = $log.Entries[$Load[$i].Number]
                    if ($e -and $e.Pending -gt 0) { $p = $e.Pending }
                }
                if ($from -ge 0 -and $p -eq $flat) { continue }
                if ($from -ge 0 -and $i - $from -ge $stallBlocks) {
                    $stalls += [pscustomobject]@{ From = $from; To = $i - 1; Pod = $short; Pending = $flat }
                    $detail.Add(('STALL: blocks #{0}-#{1} ({2} blocks) had 0 txs while pending stayed at {3:N0}' -f
                            $Load[$from].Number, $Load[$i - 1].Number, ($i - $from), $flat))
                }
                $from = -1
                if ($null -ne $p) { $from = $i; $flat = $p }
            }
        }
        $parts += $rs
        $parts += "WARN $($log.Warn) ERROR $($log.Error)"
        $lines.Add(('  {0,-12} {1}' -f $short, ($parts -join '; ')))
        $detail.Add("$rs; WARN $($log.Warn), ERROR $($log.Error) (whole run)")
        $log.Messages.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 |
            ForEach-Object { $detail.Add(('  {0,5} x {1}' -f $_.Value, $_.Key)) }
    }
    if ($maxPend) { $out.MaxPending = '{0:N0} {1}' -f $maxPend.Value, $maxPend.Pod }

    # The same stall usually shows on several validators: merge overlapping block ranges
    $merged = @()
    foreach ($st in ($stalls | Sort-Object From)) {
        $m = $merged | Select-Object -Last 1
        $who = '{0} {1:N0}' -f $st.Pod, $st.Pending
        if ($m -and $st.From -le $m.To) {
            $m.To = [Math]::Max($m.To, $st.To)
            $m.Pods += $who
        } else {
            $merged += [pscustomobject]@{ From = $st.From; To = $st.To; Pods = @($who) }
        }
    }
    if ($merged.Count -gt 0) {
        $ls = ConvertTo-Unix $Meta.loadStartUtc
        foreach ($m in ($merged | Select-Object -First 3)) {
            $a = $Load[$m.From]
            $z = $Load[$m.To]
            $lines.Add(('STALL +{0} s into load: #{1}-#{2} ({3} blocks, {4} s) 0 txs, pending flat: {5}' -f
                    ($a.Time - $ls), $a.Number, $z.Number, ($m.To - $m.From + 1), ($z.Time - $a.Time), ($m.Pods -join ', ')))
        }
        if ($merged.Count -gt 3) { $lines.Add("  ... $($merged.Count - 3) more (validators.txt lists them per validator)") }
        $blocks = ($merged | ForEach-Object { $_.To - $_.From + 1 } | Measure-Object -Sum).Sum
        $out.Notes = @("STALL x$($merged.Count) ($blocks blocks)") + $out.Notes
    }

    # Most common WARN/ERROR messages across every validator's log
    $all = @{}
    foreach ($log in $logs.Values) {
        foreach ($k in $log.Messages.Keys) { $all[$k] = $log.Messages[$k] + [int]$all[$k] }
    }
    if ($all.Count -gt 0) {
        $lines.Add('Most common WARN/ERROR across validator logs (whole run):')
        $all.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 |
            ForEach-Object { $lines.Add(('  {0,5} x {1}' -f $_.Value, $_.Key)) }
    }
    return $out
}

# spamoor's cap on transactions in flight (sent, not yet included): --max-pending, or
# unset, eoatx's default (v1.2.x): 10 x -t, at most 10 x wallets (--max-wallets, else
# 10 x -t up to 1,000, or -c / 50 within 10..1,000). Returns Cap and Source, or $null
# when it can't be told (another scenario without --max-pending).
function Get-SpamoorPendingCap($Run) {
    $opt = @{}
    $a = @($Run.extraArgs | Where-Object { $_ } | ForEach-Object { "$_" })
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ($a[$i] -notmatch '^(--max-pending|--max-wallets|--count|-c)(?:=(\d+))?$') { continue }
        $name = $Matches[1] -replace '^-c$', '--count'
        $v = $Matches[2]
        if (-not $v -and $i + 1 -lt $a.Count) { $v = $a[$i + 1] }
        if ($v -match '^\d+$') { $opt[$name] = [long]$v }
    }
    if ($opt['--max-pending'] -gt 0) { return @{ Cap = $opt['--max-pending']; Source = '--max-pending' } }
    if ($plan.scenario -ne 'eoatx') { return $null }
    $t = [long]$Run.throughput
    $wallets = $opt['--max-wallets']
    if (-not $wallets) {
        if ($opt['--count'] -gt 0) { $wallets = [Math]::Min(1000, [Math]::Max(10, [Math]::Floor($opt['--count'] / 50))) }
        else { $wallets = [Math]::Min(1000, 10 * $t) }
    }
    $cap = 10 * $t
    if ($cap -eq 0) { $cap = 4000 }
    $cap = [Math]::Min($cap, 10 * $wallets)
    if ($cap -le 0) { return $null }
    return @{ Cap = $cap; Source = "eoatx default, $wallets wallets" }
}

# spamoor's own pending count at each load block, from its per-block line
# ('block N: submitted=.., pending=.., confirmed=..'), against its cap. spamoor logs that
# line after marking the block's txs confirmed, so pending is the low point; the cap
# binds just before the block, at pending + confirmed ('in flight'). A block counts as at
# the cap when that is $spamCapPct% of the cap or more. $Blocks: block number ->
# Pending/InFlight. Returns Lines and the batch table's SpamPend and AtCap (after the
# first 2 min when $SteadyFrom is set).
function Get-SpamoorPendingSummary($Blocks, $Load, $SteadyFrom, $Run) {
    $out  = @{ Lines = @(); SpamPend = ''; AtCap = '' }
    $seen = @($Load | Where-Object { $Blocks.ContainsKey($_.Number) })
    if ($seen.Count -eq 0) {
        if ($Load.Count -gt 0) { $out.Lines += 'spamoor pending: no per-block lines (block N: ... pending=N) for load blocks in spamoor.log' }
        return $out
    }
    $max  = ($seen | ForEach-Object { $Blocks[$_.Number].Pending } | Measure-Object -Maximum).Maximum
    $peak = ($seen | ForEach-Object { $Blocks[$_.Number].InFlight } | Measure-Object -Maximum).Maximum
    $out.SpamPend = '{0:N0}' -f $max
    $cap = Get-SpamoorPendingCap $Run
    $out.Lines += 'spamoor pending ({0} of {1} load blocks logged): max {2:N0}; in flight before the block (+ its confirmed) max {3:N0}' -f
        $seen.Count, $Load.Count, $max, $peak
    if (-not $cap) {
        $out.Lines += '  cap unknown (no --max-pending, scenario not eoatx)'
        return $out
    }
    $atCap = {
        param($bs)
        $n = @($bs | Where-Object { $Blocks[$_.Number].InFlight -ge $cap.Cap * $spamCapPct / 100 }).Count
        100 * $n / $bs.Count
    }
    $whole = & $atCap $seen
    $line  = '  cap {0:N0} ({1}); at cap ({2}%+ in flight): {3:N0}% of load blocks' -f $cap.Cap, $cap.Source, $spamCapPct, $whole
    $out.AtCap = '{0:N0}%' -f $whole
    $steady = @($seen | Where-Object { $SteadyFrom -and $_.Time -ge $SteadyFrom })
    if ($steady.Count -gt 0) {
        $s = & $atCap $steady
        $line += ', after first 2 min {0:N0}%' -f $s
        $out.AtCap = '{0:N0}%' -f $s
    }
    if ($peak -gt 1.05 * $cap.Cap) { $line += ' (in flight went over the cap: spamoor flags or version not as assumed)' }
    $out.Lines += $line
    return $out
}

# Summarises a finished run from the chain (RPC on $validatorPod), top.log and the logs.
# Returns Lines (printed and saved as summary.txt), Detail (validators.txt) and Row
# (end-of-batch table).
function Get-RunSummary($Run, $Meta, [string]$RunDir) {
    $lines  = New-Object System.Collections.Generic.List[string]
    $load       = @()
    $steadyFrom = $null
    $reqTps = [double]$Run.throughput / (ConvertTo-Seconds $plan.slotDuration)
    $extra  = @($Run.extraArgs | Where-Object { $_ }) -join ' '
    $row    = [ordered]@{
        Run = $Meta.name; 'Req tx/s' = [int]$reqTps; 'Tx/s' = ''; 'Tx/s 2m+' = ''; 'Deliv %' = ''; 'Send err' = ''; 'Tx/blk' = ''
        'Max tx/blk' = ''; 'Mgas/s' = ''; 'Blk s' = ''; 'Max gap s' = ''; 'Build ms' = ''; 'Over slot' = ''
        'Max pending' = ''; 'Spam pend' = ''; 'At cap' = ''
        'Besu CPU' = ''; 'Besu mem' = ''
        'Extra args' = $extra; Notes = ''
    }
    $notes = @()
    $head = "--- Summary: $($Meta.runId)"
    if ($Meta.label) { $head += " ($($Meta.label))" }
    $lines.Add("$head ---")
    $lines.Add("spamoor $($plan.scenario) --slot-duration $($plan.slotDuration) -t $($Run.throughput) --amount $($Run.amount) $extra".TrimEnd())

    # Blocks and transactions, from the chain
    if ($Meta.loadStartUtc -and $Meta.loadEndUtc) {
        $ls = ConvertTo-Unix $Meta.loadStartUtc
        $le = ConvertTo-Unix $Meta.loadEndUtc
        try {
            $pf = Start-Forward $validatorPod $summaryPort
            try { $blocks = Get-BlocksSince $summaryPort $ls } finally { Stop-Process -Id $pf.Id -Force }
            $load = @($blocks | Where-Object { $_.Time -le $le })
            $cool = @($blocks | Where-Object { $_.Time -gt $le })
            $secs = [Math]::Max(1, $le - $ls)
            if ($load.Count -ge 2) {
                $txs    = ($load | Measure-Object -Property Txs -Sum -Maximum)
                $gas    = ($load | Measure-Object -Property Gas -Sum -Average -Maximum)
                $gasPct = ($load | Measure-Object -Property GasPct -Average -Maximum)
                $mgasPs = $gas.Sum / $secs / 1e6
                $tps    = $txs.Sum / $secs
                $span = $load[-1].Time - $load[0].Time
                $maxGap = 0
                for ($i = 1; $i -lt $load.Count; $i++) { $maxGap = [Math]::Max($maxGap, $load[$i].Time - $load[$i - 1].Time) }
                $avgBlk = $span / ($load.Count - 1)
                $lines.Add(('Load {0:N1} min: {1} blocks, avg {2:N2} s, max gap {3} s' -f ($secs / 60), $load.Count, $avgBlk, $maxGap))
                # Delivered = included on chain, as a % of the requested rate
                $tpsLine = '{0:N0} txs = {1:N1} tx/s = {2:N1}% of requested {3:N0} tx/s ({4} per {5} slot)' -f
                    $txs.Sum, $tps, (100 * $tps / $reqTps), $reqTps, $Run.throughput, $plan.slotDuration
                $row.'Deliv %' = '{0:N1}' -f (100 * $tps / $reqTps)
                # Same 2-minute cut as the analysis rule in CLAUDE.md (spamoor ramp, JIT warmup)
                if ($secs -gt 180) {
                    $steadyTxs = ($load | Where-Object { $_.Time -ge $ls + 120 } | Measure-Object -Property Txs -Sum).Sum
                    $tps2 = $steadyTxs / ($secs - 120)
                    $tpsLine += '; after first 2 min {0:N1} tx/s = {1:N1}%' -f $tps2, (100 * $tps2 / $reqTps)
                    $row.'Tx/s 2m+' = '{0:N0}' -f $tps2
                    $row.'Deliv %' += '/{0:N1}' -f (100 * $tps2 / $reqTps)
                }
                $lines.Add($tpsLine)
                $lines.Add(('Tx/block avg {0:N0}, max {1}' -f ($txs.Sum / $load.Count), $txs.Maximum))
                $lines.Add(('Gas/block avg {0}, max {1} = {2:N1} Mgas/s; {3:N2}% of the {4} limit avg, {5:N2}% max' -f
                        (Format-Gas $gas.Average), (Format-Gas $gas.Maximum), $mgasPs, $gasPct.Average, (Format-Gas $load[-1].GasLimit), $gasPct.Maximum))
                $row.'Tx/s'    = '{0:N0}' -f $tps
                $row.'Tx/blk'  = '{0:N0}' -f ($txs.Sum / $load.Count)
                $row.'Max tx/blk' = '{0:N0}' -f $txs.Maximum
                $row.'Mgas/s'  = '{0:N1}' -f $mgasPs
                $row.'Blk s'   = '{0:N2}' -f $avgBlk
                $row.'Max gap s' = $maxGap
            } else {
                $lines.Add("Load: only $($load.Count) block(s) during the load window")
                $notes += 'no blocks'
            }
            # spamoor keeps sending after loadEndUtc while its log is saved and its pod shuts
            # down, so only blocks after spamoorStoppedUtc show the txpool draining
            $st = $le
            if ($Meta.spamoorStoppedUtc) { $st = [Math]::Max($le, (ConvertTo-Unix $Meta.spamoorStoppedUtc)) }
            $stopping  = @($cool | Where-Object { $_.Time -le $st })
            $drain     = @($cool | Where-Object { $_.Time -gt $st })
            $stopTxs   = ($stopping | Measure-Object -Property Txs -Sum).Sum
            $drainTxs  = ($drain | Measure-Object -Property Txs -Sum).Sum
            $lastBusy  = @($drain | Where-Object { $_.Txs -gt 0 }) | Select-Object -Last 1
            $drainNote = 'txpool empty when spamoor stopped'
            if ($lastBusy) { $drainNote = "last txs at +$($lastBusy.Time - $st) s" }
            $delNote = ''
            if ($null -ne $Meta.spamoorDeleteSeconds) { $delNote = "; pod delete took $($Meta.spamoorDeleteSeconds) s" }
            $lines.Add(('Stopping spamoor ({0} s after load end{1}): {2} blocks, {3:N0} txs' -f ($st - $le), $delNote, $stopping.Count, [int]$stopTxs))
            $lines.Add(('Drain after spamoor stopped: {0} blocks, {1:N0} txs ({2})' -f $drain.Count, [int]$drainTxs, $drainNote))
        } catch {
            $lines.Add("Block stats unavailable: $_")
            $notes += 'no block stats'
        }
        if ($load.Count -ge 2 -and $secs -gt 180) { $steadyFrom = $ls + 120 }
    } else {
        $lines.Add('No load phase (see error below).')
    }

    # Build timings, txpool size, restarts and warnings, from every validator's log
    $detail = @()
    try {
        $v = Get-ValidatorSummary $load $steadyFrom $Meta $RunDir
        foreach ($l in $v.Lines) { $lines.Add($l) }
        $detail = $v.Detail.ToArray()
        $notes += $v.Notes
        $row.'Build ms'    = $v.BuildMs
        $row.'Over slot'   = $v.OverSlot
        $row.'Max pending' = $v.MaxPending
    } catch {
        $lines.Add("Validator log stats unavailable: $_")
        $notes += 'no validator stats'
    }

    # Health before load
    if ($Meta.health) {
        $fx = 'none'
        if ($Meta.health.fixups.Count -gt 0) { $fx = $Meta.health.fixups -join ', '; $notes += "fixups: $fx" }
        $lines.Add("Health: healthy after $($Meta.health.secondsToHealthy) s; fix-ups: $fx")
    }

    # CPU / memory during load, from top.log, against the limits read at load start
    $topFile = Join-Path $RunDir 'top.log'
    if ((Test-Path $topFile) -and $Meta.loadStartUtc -and $Meta.loadEndUtc) {
        $limits = $Meta.limits
        if (-not $limits) { $limits = @{} }
        $stats = @{}
        foreach ($l in [IO.File]::ReadLines($topFile)) {
            $f = $l -split '\s+'
            if ($f.Count -lt 5) { continue }
            if ([string]::CompareOrdinal($f[0], $Meta.loadStartUtc) -lt 0 -or [string]::CompareOrdinal($f[0], $Meta.loadEndUtc) -gt 0) { continue }
            $cpu = ConvertFrom-Cpu $f[3]
            $mem = ConvertFrom-Mem $f[4]
            if ($null -eq $cpu -or $null -eq $mem) { continue }
            $s = $stats[$f[1]]
            if (-not $s) {
                $s = @{ CpuMax = 0.0; CpuSum = 0.0; N = 0; MemMax = 0.0; CpuLim = $null; MemLim = $null; CpuPct = 0.0; MemPct = 0.0 }
                $stats[$f[1]] = $s
            }
            $s.CpuMax = [Math]::Max($s.CpuMax, $cpu); $s.CpuSum += $cpu; $s.N++
            $s.MemMax = [Math]::Max($s.MemMax, $mem)
            $lim = $limits["$($f[1])/$($f[2])"]
            if ($lim) {
                $cl = ConvertFrom-Cpu $lim.cpu
                $ml = ConvertFrom-Mem $lim.memory
                if ($cl) { $s.CpuLim = $cl; $s.CpuPct = [Math]::Max($s.CpuPct, 100 * $cpu / $cl) }
                if ($ml) { $s.MemLim = $ml; $s.MemPct = [Math]::Max($s.MemPct, 100 * $mem / $ml) }
            }
        }
        if ($stats.Count -gt 0) {
            $lines.Add("CPU cores max (avg) / limit, memory max / limit, during load (! = $limitWarnPct%+ of limit):")
            foreach ($pod in ($stats.Keys | Sort-Object)) {
                $s = $stats[$pod]
                $label = Get-ShortName $pod
                if ($pod -like 'spamoor-*') { $label = 'spamoor' }
                $cpuLim = '-'
                if ($s.CpuLim) { $cpuLim = '{0:G4}' -f $s.CpuLim }
                $memLim = '-'
                if ($s.MemLim) { $memLim = Format-Mem $s.MemLim }
                $flags = @()
                if ($s.CpuPct -ge $limitWarnPct) { $flags += 'CPU {0:N0}%' -f $s.CpuPct }
                if ($s.MemPct -ge $limitWarnPct) { $flags += 'mem {0:N0}%' -f $s.MemPct }
                $flag = ''
                if ($flags.Count -gt 0) {
                    $flag = '  ! ' + ($flags -join ', ') + ' of limit'
                    $notes += "$label " + ($flags -join ', ') + ' of limit'
                }
                $lines.Add(('  {0,-12} cpu {1,5:N2} ({2:N2}) / {3,-4} mem {4,6} / {5}{6}' -f
                        $label, $s.CpuMax, ($s.CpuSum / $s.N), $cpuLim, (Format-Mem $s.MemMax), $memLim, $flag))
            }
            $besu = @($stats.Keys | Where-Object { $besuPods -contains $_ })
            if ($besu.Count -gt 0) {
                $topCpu = $besu | Sort-Object { $stats[$_].CpuMax } | Select-Object -Last 1
                $topMem = $besu | Sort-Object { $stats[$_].MemMax } | Select-Object -Last 1
                $row.'Besu CPU' = '{0:N2} {1}' -f $stats[$topCpu].CpuMax, (Get-ShortName $topCpu)
                $row.'Besu mem' = '{0} {1}' -f (Format-Mem $stats[$topMem].MemMax), (Get-ShortName $topMem)
            }
        }
    }

    # spamoor: did it run the whole window, and what did it complain about
    foreach ($f in @($Meta.spamoorFailures)) {
        if (-not $f) { continue }
        $lines.Add("spamoor attempt $($f.attempt): $($f.phase) $($f.secondsAfterStart) s after start; restarted (log in spamoor-failed-$($f.attempt).log)")
        $notes += "spamoor retried ($($f.phase) at +$($f.secondsAfterStart) s)"
    }
    if ($Meta.spamoorPhase -and $Meta.spamoorPhase -ne 'Running' -and $Meta.loadStartUtc -and $Meta.loadEndUtc) {
        $ran = ((ConvertTo-Unix $Meta.loadEndUtc) - (ConvertTo-Unix $Meta.loadStartUtc)) / 60
        $lines.Add(('spamoor {0} after {1:N1} of {2} min: load window cut short, run not comparable' -f $Meta.spamoorPhase, $ran, $Run.durationMinutes))
        $notes = @(('SPAMOOR {0} at {1:N1} min' -f $Meta.spamoorPhase.ToUpper(), $ran)) + $notes
    }
    $spamLog = Join-Path $RunDir 'spamoor.log'
    if (Test-Path $spamLog) {
        # Can be 1 GB+ when the network is overloaded, so one streaming pass, with the
        # most common warning/error messages counted (numbers and hex blanked)
        $spamErrors = 0; $spamWarns = 0; $sendErrors = 0
        $msgCounts  = @{}
        $spamBlocks = @{}   # block number -> spamoor's pending after it, and in flight before it
        foreach ($l in [IO.File]::ReadLines($spamLog)) {
            if ($l.Contains('pending=') -and $l -match '\bblock #?(\d+)\b.*?\bpending=(\d+)') {
                $num  = [long]$Matches[1]
                $pend = [long]$Matches[2]
                $conf = 0
                if ($l -match '\bconfirmed=(\d+)') { $conf = [long]$Matches[1] }
                $spamBlocks[$num] = @{ Pending = $pend; InFlight = $pend + $conf }
            }
            if ($l.Contains('level=error') -or $l.StartsWith('panic:')) { $spamErrors++ }
            elseif ($l.Contains('level=warning')) { $spamWarns++ }
            else { continue }
            if ($l -match $sendErrorPattern) { $sendErrors++ }
            $msg = $l
            $i = $l.IndexOf('msg=')
            if ($i -ge 0) { $msg = $l.Substring($i + 4) }
            # URLs (the RPC endpoint) would use up the width before the actual error
            $msg = $msg -replace 'https?://[^\s"\\]+', '<url>'
            if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) }
            $msg = $msg -replace '0x[0-9a-fA-F]+', '0x..' -replace '\d+', 'N'
            $msgCounts[$msg] = 1 + [int]$msgCounts[$msg]
        }
        $mb = (Get-Item $spamLog).Length / 1MB
        # Against the txs requested over the time spamoor was sending (load start to its pod gone)
        $sendMsg = '{0:N0}' -f $sendErrors
        $sentTo  = $Meta.spamoorStoppedUtc
        if (-not $sentTo) { $sentTo = $Meta.loadEndUtc }
        if ($Meta.loadStartUtc -and $sentTo) {
            $reqTxs = $reqTps * ((ConvertTo-Unix $sentTo) - (ConvertTo-Unix $Meta.loadStartUtc))
            if ($reqTxs -gt 0) { $sendMsg += ' ({0:N1}% of {1:N0} requested)' -f (100 * $sendErrors / $reqTxs), $reqTxs }
        }
        $lines.Add(('spamoor.log {0:N1} MB: error lines {1}, warning lines {2:N0}; send errors {3}' -f $mb, $spamErrors, $spamWarns, $sendMsg))
        $row.'Send err' = $sendMsg -replace ' of [\d,.]+ requested', ''
        $msgCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 |
            ForEach-Object { $lines.Add(('  {0,7:N0} x {1}' -f $_.Value, $_.Key)) }
        if ($spamErrors -gt 0) { $notes += "spamoor errors $spamErrors" }
        $sp = Get-SpamoorPendingSummary $spamBlocks $load $steadyFrom $Run
        foreach ($l in $sp.Lines) { $lines.Add($l) }
        $row.'Spam pend' = $sp.SpamPend
        $row.'At cap'    = $sp.AtCap
    }

    if ($Meta.error) {
        $err = "$($Meta.error)" -replace '\s+', ' '
        if ($err.Length -gt 200) { $err = $err.Substring(0, 200) + '...' }
        $lines.Add("ERROR: $err")
        $notes = @('ERROR') + $notes
    }
    $row.Notes = $notes -join '; '
    return @{ Lines = $lines.ToArray(); Detail = $detail; Row = [pscustomobject]$row }
}

# Commits just the given file (not anything else under runs\, such as the run folders)
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
$batchLabel      = [string]$plan.label   # optional: what this batch is testing, for the batch summary
$ns              = $plan.namespace
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
$summaryPort          = $rpcLocalPortBase + 100
$limitWarnPct         = 95   # summary flags any container at or above this % of its CPU/memory limit
$timingSubPhases      = @('selectedTxsEvaluation')   # Besu Timing(...) phases that are part of the one before, so indented
$ansiEscape           = '\x1b\[[\d;]*[A-Za-z]'       # terminal colour codes in Besu's log
$spamoorRetrySeconds  = 60   # spamoor exiting this soon after Ready is retried (once) ...
$spamoorMaxAttempts   = 2    # ... up to this many starts in total
$spamoorGraceSeconds  = 5    # SIGTERM -> SIGKILL when stopping spamoor; it keeps sending until gone
$slowDeleteSeconds    = 60   # a spamoor pod delete slower than this is warned about, with its events saved
$stallBlocks          = 5    # this many 0-tx load blocks in a row with a validator's pending count unchanged is a stall
$spamCapPct           = 95   # a load block where spamoor's in-flight txs are at this % of its max-pending cap counts as at the cap
# spamoor warning/error lines counted as send errors (one per tx the RPC node rejected).
# Matches the verb rather than any one message, so reworded messages still count.
$sendErrorPattern     = '(?i)\b(send|sending|submit|submitting|broadcast|broadcasting)\b|send\w*transaction'

# The RPC node spamoor sends to (first label of rpcUrl's host), unless the plan names one
$rpcPod = $plan.rpcPod
if (-not $rpcPod) { $rpcPod = ([Uri]$plan.rpcUrl).Host.Split('.')[0] }

$besuPods = @((Invoke-Native $kubectl @('get', 'pods', '-n', $ns, '-l', 'app.kubernetes.io/component=besu',
            '-o', 'jsonpath={.items[*].metadata.name}')) -join ' ' -split '\s+' | Where-Object { $_ } | Sort-Object)
if ($besuPods.Count -eq 0) { throw "No Besu pods (app.kubernetes.io/component=besu) found in $ns." }
if ($besuPods -notcontains $rpcPod) {
    Write-Warning "RPC pod '$rpcPod' (from rpcUrl) isn't a Besu pod in $ns; rpc.log won't be captured. Set rpcPod in the plan."
    $rpcPod = $null
}

# Every validator's log is streamed and summarised. The summary reads blocks over RPC
# from the plan's validatorPod, or the first validator.
$validatorPods = @($besuPods | Where-Object { $_ -match 'validator' })
if ($validatorPods.Count -eq 0) { throw "No validator pods (Besu pods named *validator*) found in $ns." }
$validatorPod = $plan.validatorPod
if ($validatorPods -notcontains $validatorPod) {
    if ($validatorPod) { Write-Warning "validatorPod '$validatorPod' isn't a validator pod in $ns; reading blocks from $($validatorPods[0])." }
    $validatorPod = $validatorPods[0]
}

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
if ($Group) { $runsDir = Join-Path $runsDir $Group }
New-Item -ItemType Directory -Force -Path $runsDir | Out-Null

$loadMinutes = ($runs | Measure-Object -Property durationMinutes -Sum).Sum
if ($batchLabel) { Write-Host "Batch: $batchLabel" }
Write-Host "$($runs.Count) runs, $loadMinutes min of load plus setup/cooldown per run."
Write-Host "Network reset before each run: $doReset. Results go to $runsDir."
Write-Host "Health check covers: $($besuPods -join ', ')"
Write-Host "Validator logs: $($validatorPods -join ', ')"

# Remove leftover spamoor pods, including the original hand-made 'spamoor' pod
Invoke-Native $kubectl @('delete', 'pod', '-n', $ns, '-l', 'app=spamoor', '--ignore-not-found', '--wait=true') | Out-Null
Invoke-Native $kubectl @('delete', 'pod', 'spamoor', '-n', $ns, '--ignore-not-found', '--wait=true') | Out-Null

# ---------------------------------------------------------------------------
# Test loop
# ---------------------------------------------------------------------------

$runNumber   = 0
$summaryRows = @()
$batchStamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($run in $runs) {
    $runNumber++
    # Named after the requested tx/s (spamoor's -t is per slot); the plan's name, if any, is a suffix
    $runName  = 'tps{0}' -f [math]::Round([double]$run.throughput / (ConvertTo-Seconds $plan.slotDuration))
    if ($run.name) { $runName = "$runName-$($run.name)" }
    $safeName = ($runName.ToLower() -replace '[^a-z0-9-]', '-')
    $runId    = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $safeName
    $podName  = "spamoor-$runId"
    if ($podName.Length -gt 63) { $podName = $podName.Substring(0, 63) }
    $podName  = $podName.TrimEnd('-')
    $runDir   = Join-Path $runsDir $runId
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
        label           = $batchLabel
        name            = $runName
        image           = $plan.image                                  # without the registry
        durationMinutes = $run.durationMinutes
        throughput      = $run.throughput
        amount          = $run.amount
        spamoorArgs     = @($spamoorArgs | ForEach-Object { if ($_ -eq $privKey) { '<redacted>' } else { $_ } })
        resetNetwork    = $doReset
        validatorPods   = $validatorPods
        validatorPod    = $validatorPod                                # the summary reads blocks from this one
    }

    $valLogs      = [ordered]@{}   # validator -> <validator>.log
    foreach ($p in $validatorPods) { $valLogs[$p] = Join-Path $runDir "$(Get-ShortName $p).log" }
    $rpcLog       = Join-Path $runDir 'rpc.log'
    $spamLog      = Join-Path $runDir 'spamoor.log'
    $logProcs     = @{}            # validator -> its log stream
    $rpcLogProc   = $null
    $spamLogProc  = $null
    $spamoorAlive = $false

    try {
        # The validator logs cover everything from here: reset, health check, warmup, load, cooldown
        $meta.logStartUtc = Get-UtcStamp

        # 1. Get to a healthy network: optional full restart, then wait for peers and
        #    block production, restarting single stuck pods if needed
        if ($doReset) { Reset-Network }
        $meta.health     = Confirm-NetworkHealthy $runDir $meta.logStartUtc
        $meta.healthyUtc = Get-UtcStamp

        $meta.validatorNodes          = [ordered]@{}
        $meta.validatorRestartsBefore = [ordered]@{}
        foreach ($p in $validatorPods) {
            $meta.validatorNodes[$p]          = Get-PodField $p '{.spec.nodeName}'
            $meta.validatorRestartsBefore[$p] = Get-PodField $p '{.status.containerStatuses[0].restartCount}'
        }

        # 2. Stream every validator's and the RPC node's logs. --since-time backfills the reset
        #    and health check, including the startup of a container restarted since then.
        foreach ($p in $validatorPods) { $logProcs[$p] = Start-LogStream $p $valLogs[$p] $meta.logStartUtc }
        if ($rpcPod) { $rpcLogProc = Start-LogStream $rpcPod $rpcLog $meta.logStartUtc }
        Start-Sleep -Seconds 3

        # Let a restarted network or pod settle before load
        $meta.warmupSeconds = 0
        if ($doReset -or $meta.health.fixups.Count -gt 0) {
            $meta.warmupSeconds = $warmupSeconds
            Write-Host "  Warming up for $warmupSeconds s ..."
            Start-Sleep -Seconds $warmupSeconds
        }

        # 3. Start spamoor, streaming its log from the start. If it exits within
        #    $spamoorRetrySeconds (e.g. a transient RPC error while preparing wallets),
        #    keep that log as spamoor-failed-<n>.log and start it again.
        $topFile = Join-Path $runDir 'top.log'
        $meta.spamoorFailures = @()
        $attempt = 0
        while ($true) {
            $attempt++
            Invoke-Native $kubectl @('apply', '-f', '-') -InputText $manifest | Out-Null
            $spamoorAlive = $true
            Invoke-Native $kubectl @('wait', '--for=condition=Ready', "pod/$podName", '-n', $ns, '--timeout=10m') | Out-Null
            $spamLogProc = Start-LogStream $podName $spamLog ''
            $startedAt         = Get-Date
            $meta.spamoorNode  = Get-PodField $podName '{.spec.nodeName}'
            $meta.loadStartUtc = Get-UtcStamp
            Write-Host "  spamoor running on $($meta.spamoorNode); load for $($run.durationMinutes) min ..."
            $meta.limits = Get-ContainerLimits

            # 4. Sample CPU/memory until the duration is up
            $endAt   = $startedAt.AddMinutes([double]$run.durationMinutes)
            $restart = $false
            while ((Get-Date) -lt $endAt) {
                $ts = Get-UtcStamp
                Invoke-Native $kubectl @('top', 'pods', '-n', $ns, '--containers', '--no-headers') -AllowFailure |
                    ForEach-Object { "$ts $_" } | Add-Content -Path $topFile
                $phase = Get-PodField $podName '{.status.phase}'
                if ($phase -ne 'Running') {
                    $secs = [int]((Get-Date) - $startedAt).TotalSeconds
                    # Only a pod that has really finished; $null may be an API blip
                    $exited  = @('Failed', 'Succeeded') -contains $phase
                    $restart = $exited -and $secs -le $spamoorRetrySeconds -and $attempt -lt $spamoorMaxAttempts
                    if (-not $restart) { Write-Warning "spamoor stopped early (phase: $phase, $secs s after start)" }
                    break
                }
                $left = ($endAt - (Get-Date)).TotalSeconds
                if ($left -gt 0) { Start-Sleep -Seconds ([int][Math]::Ceiling([Math]::Min([double]$sampleSeconds, $left))) }
            }
            if (-not $restart) { break }

            $meta.spamoorFailures += [ordered]@{ attempt = $attempt; phase = $phase; secondsAfterStart = $secs; startUtc = $meta.loadStartUtc }
            Write-Warning "spamoor $phase $secs s after starting; log kept as spamoor-failed-$attempt.log. Starting it again ..."
            Stop-LogStream $spamLogProc 10
            Move-Item $spamLog (Join-Path $runDir "spamoor-failed-$attempt.log") -Force
            Remove-EmptyFile "$spamLog.stderr"
            if (Test-Path "$spamLog.stderr") { Move-Item "$spamLog.stderr" (Join-Path $runDir "spamoor-failed-$attempt.log.stderr") -Force }
            Invoke-Native $kubectl @('delete', 'pod', $podName, '-n', $ns, '--wait=true') | Out-Null
            $spamoorAlive = $false
        }
        $meta.spamoorAttempts = $attempt
        $meta.loadEndUtc      = Get-UtcStamp
        $meta.spamoorPhase    = Get-PodField $podName '{.status.phase}'

        # 5. Stop spamoor. Its log is already streamed, so it goes straight away; it keeps
        #    sending until the pod is gone. A slow delete is timed and its events saved.
        $t = Get-Date
        Invoke-Native $kubectl @('delete', 'pod', $podName, '-n', $ns, "--grace-period=$spamoorGraceSeconds", '--wait=true') | Out-Null
        $spamoorAlive = $false
        $meta.spamoorStoppedUtc    = Get-UtcStamp
        $meta.spamoorDeleteSeconds = [int]((Get-Date) - $t).TotalSeconds
        if ($meta.spamoorDeleteSeconds -gt $slowDeleteSeconds) {
            Write-Warning "Deleting spamoor's pod took $($meta.spamoorDeleteSeconds) s (grace period $spamoorGraceSeconds s); events in spamoor-events.log"
            Save-NativeOutput $kubectl @('get', 'events', '-n', $ns, "--field-selector=involvedObject.name=$podName",
                '-o', 'custom-columns=TIME:.lastTimestamp,TYPE:.type,REASON:.reason,MESSAGE:.message') (Join-Path $runDir 'spamoor-events.log')
        }
        Stop-LogStream $spamLogProc 10

        # 6. Keep logging while the txpool drains
        Write-Host "  Cooldown $cooldownSeconds s ..."
        Start-Sleep -Seconds $cooldownSeconds
    }
    catch {
        $meta.error = "$_"
        Write-Warning "Run $runId hit an error: $_"
    }
    finally {
        $meta.logStreamDiedEarly = [ordered]@{}   # validator -> its stream had ended by itself
        foreach ($p in $validatorPods) { $meta.logStreamDiedEarly[$p] = [bool]($logProcs[$p] -and $logProcs[$p].HasExited) }
        $meta.rpcLogStreamDiedEarly = [bool]($rpcLogProc -and $rpcLogProc.HasExited)
        foreach ($proc in $logProcs.Values) { Stop-LogStream $proc }
        Stop-LogStream $rpcLogProc
        if ($spamoorAlive) {
            Invoke-Native $kubectl @('delete', 'pod', $podName, '-n', $ns, '--ignore-not-found', "--grace-period=$spamoorGraceSeconds", '--wait=true') -AllowFailure | Out-Null
        }
        Stop-LogStream $spamLogProc
    }

    $meta.endUtc                 = Get-UtcStamp
    $meta.validatorRestartsAfter = [ordered]@{}
    foreach ($p in $validatorPods) {
        $meta.validatorRestartsAfter[$p] = Get-PodField $p '{.status.containerStatuses[0].restartCount}'
    }

    # If a validator restarted mid-run, its stream ended with it: grab what we can
    foreach ($p in $validatorPods) {
        if (-not ($meta.logStreamDiedEarly[$p] -and $meta.logStartUtc)) { continue }
        $short = Get-ShortName $p
        Write-Warning "$short log stream ended early; saving fallback copies."
        Save-NativeOutput $kubectl @('logs', '-n', $ns, $p, "--since-time=$($meta.logStartUtc)") (Join-Path $runDir "$short-fallback.log")
        if ($meta.validatorRestartsBefore -and $meta.validatorRestartsAfter[$p] -ne $meta.validatorRestartsBefore[$p]) {
            Save-NativeOutput $kubectl @('logs', '-n', $ns, $p, '--previous') (Join-Path $runDir "$short-previous.log")
        }
    }
    foreach ($f in @($valLogs.Values) + @($rpcLog, $spamLog)) { Remove-EmptyFile "$f.stderr" }

    # Summary for the console (results don't come back through git), summary.txt and meta.json
    Write-Host '  Summarising (reads the run''s blocks over RPC) ...'
    try {
        $summary = Get-RunSummary $run $meta $runDir
        $meta.summary = $summary.Lines
        $summaryRows += $summary.Row
        Write-Host ''
        $summary.Lines | ForEach-Object { Write-Host "  $_" }
        $summary.Lines | Set-Content -Path (Join-Path $runDir 'summary.txt') -Encoding UTF8
        if ($summary.Detail.Count -gt 0) {
            $summary.Detail | Set-Content -Path (Join-Path $runDir 'validators.txt') -Encoding UTF8
        }
    } catch {
        Write-Warning "Couldn't summarise ${runId}: $_"
        $summaryRows += [pscustomobject]@{ Run = $runName; Notes = "summary failed: $_" }
    }

    $meta | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $runDir 'meta.json') -Encoding UTF8

    # 7. The run folder is the result; zip it (next to the folder) and publish the zip if asked
    Write-Host "  Results in $runDir."
    if ($Zip -or $Push) {
        $zipPath = Join-Path $runsDir "$runId.zip"
        Compress-Archive -Path (Join-Path $runDir '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force
        $zipMB = [Math]::Round((Get-Item $zipPath).Length / 1MB, 1)
        Write-Host "  Zipped $runId.zip ($zipMB MB)."
        if ($Push) {
            $label = $runId
            if ($Group) { $label = "$Group/$runId" }
            if ($zipMB -gt $MaxZipMB) { Write-Warning "$runId.zip is $zipMB MB, too large for git; not pushed." }
            else { Publish-Run $zipPath "spamoor run $label" }
        }
    }
}

# The plan's label says what the batch was testing; the group folder and start time say where to find it
$batchWhere = "runs\, started $batchStamp"
if ($Group) { $batchWhere = "runs\$Group\, started $batchStamp" }
$batchTitle = "=== Batch summary: $($summaryRows.Count) run(s) in $batchWhere ==="
if ($batchLabel) { $batchTitle += "`nLabel: $batchLabel" }
$batchTitle += "`nLoad window only; 2m+ excludes the first 2 min; Deliv %: Tx/s as % of Req tx/s (whole/2m+); Send err: spamoor's whole log; Build ms (avg/p95) and Over slot: every validator's blocks, 2m+; Spam pend: spamoor's max pending=; At cap: % of blocks (2m+) with spamoor's in-flight txs at $spamCapPct%+ of its max-pending"
$batchTable = $summaryRows | Format-Table -AutoSize -Property Run, 'Req tx/s', 'Tx/s', 'Tx/s 2m+', 'Deliv %', 'Send err', 'Tx/blk', 'Max tx/blk', 'Mgas/s', 'Blk s', 'Max gap s', 'Build ms', 'Over slot', 'Max pending', 'Spam pend', 'At cap', 'Besu CPU', 'Besu mem', 'Extra args', Notes |
    Out-String -Width 300
Write-Host "`n$batchTitle"
Write-Host $batchTable

# Saved next to the run folders (in the group folder if there is one); timestamped so a
# reused group name doesn't overwrite an earlier batch's table
$batchFile = Join-Path $runsDir "$batchStamp-batch-summary.txt"
@($batchTitle, $batchTable.TrimEnd()) | Set-Content -Path $batchFile -Encoding UTF8
Write-Host "Batch summary saved to $batchFile."
if ($Push) {
    $label = $batchStamp
    if ($Group) { $label = "$Group/$batchStamp" }
    Publish-Run $batchFile "spamoor batch summary $label"
}

Write-Host "All runs done. Results are in $runsDir."
