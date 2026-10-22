# Run-SpamoorTests.ps1

Runs every load test listed in `test-plan.json`, one after another. For each run it
captures the validator's logs and CPU/memory samples, then zips the results into `runs/`
and, with `-Push`, commits and pushes them. It runs on the VDS under Windows PowerShell 5.1.

The VDS currently can't push to GitHub, so leave `-Push` off there; the console output
(per-run summaries and the batch table) carries the results.

```powershell
git pull
.\scripts\Run-SpamoorTests.ps1                    # results go to runs\, not pushed
.\scripts\Run-SpamoorTests.ps1 txpool-config      # results go to runs\txpool-config\
.\scripts\Run-SpamoorTests.ps1 txpool-config -Push   # ... and commit + push each one
.\scripts\Run-SpamoorTests.ps1 -NoReset           # skip the network restart this batch
```

## Overall shape

For each entry in `test-plan.json`:

```
[reset network] → health check (+ fix-ups) → start validator + rpc log streams → [warmup]
→ start spamoor + its log stream [→ retry once if it dies in the first minute]
→ load + sample CPU/mem → delete spamoor → cooldown → stop streams → summary
→ meta.json → zip → [git push]
```

After the last run it prints a table comparing all runs in the batch. See
[Run summary](#run-summary).

Each run is wrapped so that a failure is written into that run's `meta.json` and the loop
moves on to the next run.

Timeline of one run and the `meta.json` timestamps. `validator.log` and `rpc.log` cover
all of it, from `logStartUtc` to `endUtc`:

```
logStartUtc ──┬─ ... reset (if enabled), health check, fix-ups ...
              ├─ healthyUtc    every pod peered with all its static peers, chain advancing
              │   ... warmup (idle, warmupSeconds; only after a reset or fix-up) ...
              ├─ loadStartUtc  spamoor pod Ready (the retry's, if it was restarted)
              │   ... load + top sampling ...
              ├─ loadEndUtc    duration up; spamoor still sending while its pod is deleted
              ├─ spamoorStoppedUtc  spamoor pod gone (it has stopped sending)
              │   ... cooldown (txpool drains) ...
              └─ endUtc        stream stopped, meta.json, zip, push
```

## Prerequisites on the VDS

| What | Where | Why |
|---|---|---|
| Spamoor private key | `$HOME\spamoor-privkey.txt` | Kept out of git; injected into the pod args at render time |
| Image registry prefix | `$env:IMAGE_REGISTRY` | Kept out of git; prepended to the plan's `image` |
| `kubectl`, `git` | on `PATH` | Cluster access and publishing results |
| HTTP JSON-RPC on 8545 with the ADMIN API | every Besu pod | Health check (`admin_peers`, `admin_addPeer`, `eth_blockNumber`) |
| `besu-peers` configmap | namespace | Static peers list; the health check reads it at startup |
| Local ports 18545 upwards | VDS | One `kubectl port-forward` per Besu pod during the health check |

Set the registry once (it persists for your user). The second line covers the current
shell, because already-open windows won't see the persisted value:

```powershell
[Environment]::SetEnvironmentVariable('IMAGE_REGISTRY', '<registry>/<path>', 'User')
$env:IMAGE_REGISTRY = '<registry>/<path>'
```

The script throws at startup if either the key or the registry is missing.

## Parameters

All parameters have defaults.

| Parameter | Default | Notes |
|---|---|---|
| *(first positional)* `-Group` | none | Subfolder of `runs\` (and of `-WorkRoot`) for this batch, e.g. `txpool-config`. Letters, digits, `.`, `_`, `-`. Without it, zips go straight into `runs\` |
| `-PlanFile` | `scripts\test-plan.json` | |
| `-TemplateFile` | `scripts\spamoor-run.template.yml` | |
| `-RepoRoot` | parent of `scripts\` | |
| `-WorkRoot` | `$HOME\spamoor-runs` | Working folder outside the repo. Each run is built here as an unzipped folder, zipped here, and only the zip is copied into `runs\`. So the unzipped copy of every run is already here (no need to unzip into `runs\`), and zips too big for git stay here |
| `-PrivKeyFile` | `$HOME\spamoor-privkey.txt` | |
| `-Registry` | `$env:IMAGE_REGISTRY` | Registry + path prefix, without the image name |
| `-MaxZipMB` | `95` | GitHub rejects files over 100 MB |
| `-NoReset` | off | Skip the network restart even if the plan's `resetNetwork` is true. The health check still runs |
| `-Push` | off | Commit and push each zip as it finishes. Without it, zips are copied into `runs\` and left uncommitted |

## Plan settings for the health check

| Field | Default if absent | Meaning |
|---|---|---|
| `healthTimeoutSeconds` | 300 | How long one health wait lasts before a fix-up (or giving up) |
| `maxFixups` | 2 | Fix-ups (full reset or single-pod restart) allowed per run before the run is abandoned |
| `rpcPod` | first label of `rpcUrl`'s host | Pod whose log is streamed as `rpc.log` (the node spamoor sends to) |

Fixed in the script: every pod must be connected to every other running pod in the
`besu-peers` configmap, the chain must advance 5 blocks, each pod must be within 2 blocks
of the best head, polls every 10 s, RPC port 8545.

## Helpers

Most of these exist to work around Windows PowerShell 5.1:

- **`Invoke-Native`** is used for every kubectl and git call.
  - Under `$ErrorActionPreference = 'Stop'`, 5.1 treats any stderr line from a native
    tool as a fatal error, even when the tool succeeded. kubectl and git both write normal
    progress to stderr, so this helper switches to `Continue` for the duration of the call.
  - It decides success from the exit code instead. It throws on a non-zero exit, unless
    you pass `-AllowFailure`, in which case the caller checks `$script:LastExit` itself.
  - stdout and stderr are merged (`2>&1`), so the returned output includes both.
- **`Save-NativeOutput`** writes a command's output straight to a file. In 5.1, `>`
  re-encodes output as UTF-16, which doubles the size of large logs. Going through
  `Start-Process -RedirectStandardOutput` keeps the bytes as they are.
- **`Start-LogStream` / `Stop-LogStream`** run `kubectl logs -f` as a background process
  writing to a file, and stop it (optionally giving it a few seconds to end by itself
  first, as it does when its container stops). Used for `validator.log`, `rpc.log` and
  `spamoor.log`.
- **`Get-PodField`** is a small `kubectl get pod -o jsonpath=…` wrapper. It returns
  `$null` on failure instead of throwing.
- **`Reset-Network`** is the deliberate full-network restart (all 4 validators plus the
  RPC node):
  - It scales **every statefulset to 0**, waits (printing progress) until every Besu pod
    is gone, then scales each back to 1. Unlike `rollout restart`, no new node can peer
    with an old one and be handed its pending transactions, so every txpool starts empty.
  - Scaling back up is in a `finally`, so the network comes back even if the scale-down
    fails part way. It always restores 1 replica (one pod per Helm release), which also
    repairs a statefulset left at 0 by an earlier aborted batch.
  - It then waits on `rollout status` for each one, with a 15-minute timeout. The pods
    have no readiness probe, so this only means the containers have started, not that
    Besu is peered. The health check covers that.
- **`Wait-NetworkHealthy`**: the health check. See [Health check](#health-check-and-fix-ups).
- **`Confirm-NetworkHealthy`**: the health check plus fix-ups (full reset or single-pod
  restart).
- **`Publish-Run`** (only with `-Push`):
  - It stages and commits **only the zip it was given**, so unzipped folders under
    `runs\` or anything you've staged by hand stay out of the commit.
  - It then tries `pull --rebase --autostash` + `push` up to 3 times with backoff, so
    pushes from the host while a batch is running don't break it.
  - If all attempts fail, the commit stays local and goes up with the next successful push.

## Setup

- The plan and template are read **once at startup**. If you push a plan change
  mid-batch, the running batch ignores it; it applies from the next invocation.
- The Besu pods to health-check are found once, by the label
  `app.kubernetes.io/component=besu`, and printed.
- Before the first run, any leftover pods labelled `app=spamoor` are deleted. So is the
  original hand-made `spamoor` pod, so an orphan from a crashed earlier batch can't add
  extra load.

## Per-run setup

- **Run ID**: a timestamp plus the cleaned run name. The run name is `tps<N>`, where `N`
  is the requested tx/s (`throughput / slotDuration`, so `-t 16000` with a 2 s slot is
  `tps8000`); the plan's optional `name` is appended (`tps8000-<name>`) to tell apart
  runs at the same rate. The pod name is `spamoor-<runId>`, truncated to the
  63-character Kubernetes limit.
- **spamoor args**: built from the plan's top-level fields plus the run's `throughput`,
  `amount` and `extraArgs`.
- **Rendering**: each argument becomes a double-quoted YAML list item, and the four
  `{{…}}` placeholders (`NAME`, `NAMESPACE`, `IMAGE`, `ARGS`) are filled in with plain
  string replacement.
- **`$meta`**: an ordered hashtable that grows as the run goes, so `meta.json` has the
  same keys in the same order every time. The private key is replaced with `<redacted>`,
  and `image` is recorded without the registry.
- **`$spamoorAlive`**: a flag that tells the cleanup step whether there's a pod to delete.

## The run itself

1. **Healthy network**: if resetting (plan's `resetNetwork` and no `-NoReset`), the
   network is restarted. Then the health check runs, with fix-ups if needed. If
   the network still isn't healthy, the run is abandoned before any load is sent. The
   validator's restart count is read *after* this, so the before/after comparison only
   covers the load.
2. **Log streams**: `kubectl logs -f --since-time=<logStartUtc>` runs as a **background
   process** for the validator (`validator.log`) and for the RPC node spamoor sends to
   (`rpc.log`, see `rpcPod`).
   - `--since-time` backfills everything since the run began: the reset, Besu startup,
     peering and the health check, even if the pod was restarted in between.
   - Streaming matters because kubelet rotates container logs, and a single
     `kubectl logs` at the end would lose the start of a long, noisy run.
   - A 3-second sleep lets the streams attach before anything else happens.
3. **Warmup**: after a reset or a fix-up restart, the network is left idle for
   `warmupSeconds` (see [Warmup](#warmup)).
4. **Start spamoor**: the manifest is piped to `kubectl apply -f -`, then the script waits
   up to 10 minutes for the pod to be Ready. `loadStartUtc` is stamped once it's Ready,
   and spamoor's log is streamed into `spamoor.log` from the container's start. At high
   load spamoor can write 60 MB in 30 s (one warning per rejected tx), so a one-off
   `kubectl logs` at the end only got the last rotated file. Then every container's
   CPU/memory limits are read from the pod specs into `meta.limits`
   (`<pod>/<container>` → `cpu`, `memory`) for the summary.
5. **Sampling loop**:
   - Every `sampleSeconds` it appends `kubectl top pods --containers` to `top.log`, with
     a UTC timestamp at the start of each line.
   - It also checks spamoor's phase, and **stops early** if the pod is no longer
     `Running` (for example, if it crashed).
   - **Early-failure retry**: if the pod has `Failed` or `Succeeded` within 60 s of
     Ready, and it's the first attempt, its log is kept as `spamoor-failed-<n>.log`, the
     pod is deleted and spamoor starts again with a fresh load window (`loadStartUtc`
     restamped). Seen once: spamoor panicked preparing wallets after rpc-1 answered one
     `eth_getBalance`-type call with `null`. `meta.spamoorFailures` records each failed
     attempt and `meta.spamoorAttempts` the total.
   - The last sleep is cut short so the load phase ends on time.
6. **Spamoor teardown**: the pod is deleted with a 5 s grace period straight away (its
   log is already streamed). spamoor keeps sending until the pod is gone, so
   `spamoorStoppedUtc` is stamped then, and `spamoorDeleteSeconds` records how long the
   delete took. Over 60 s prints a warning and saves the pod's events as
   `spamoor-events.log` (one delete took 13.5 minutes, with spamoor sending throughout).
7. **Cooldown**: the validator and rpc streams keep running for `cooldownSeconds` so the
   txpool draining is captured.

## Health check and fix-ups

A pod reporting Ready doesn't mean Besu is peered. On Besu 25.7.0, after a full restart,
some static-peer links never form (seen: validator-4 never connected to validator-1 or
validator-2, in either direction, even 15 minutes later). If that splits the validators,
QBFT stalls until its round timers happen to line up, which took over 10 minutes. So
before any load, every run checks the network over RPC.

- The VDS can't reach pod IPs, so the script keeps one `kubectl port-forward` per Besu
  pod (local ports 18545, 18546, …) open across polls. kubectl takes about 5 s to start
  listening, so each new forward gets up to 15 s. A forward is replaced if kubectl exits
  or its pod is replaced (pod UID changes).
- Each pod is asked for `admin_peers` and `eth_blockNumber`. Peers are matched to pods by
  public key, using the `besu-peers` configmap's `static-nodes.json`.
- A pod is **unhealthy** if it doesn't answer RPC, isn't connected to **every other
  running pod in the static peers list**, or is more than 2 blocks behind the best head.
- The network is **healthy** when no pod is unhealthy and the best head has advanced at
  least 5 blocks since the check began, which proves QBFT is producing blocks.
- After each poll, every pod that is missing static peers is asked to dial them with
  `admin_addPeer`, from both ends of the link. This usually repairs the links within a
  poll or two, without any restart.
- Every poll prints one progress line. `p` is the peer count, unhealthy pods are marked
  with `!`:

  ```
    [00:40] rpc-1 4p #385437 | validator-1 3p #385437 missing validator-4 ! | ... | validator-4 2p #385437 missing validator-1,validator-2 ! | +3/5 blocks
  ```

**Fix-ups.** If the network still isn't healthy after `healthTimeoutSeconds`, the script
escalates, up to `maxFixups` times per run:

- **Chain stalled** (fewer than 5 new blocks): a full network reset (`Reset-Network`),
  after saving every pod's logs as `fixup-<n>-<pod>.log`. Restarting one validator
  doesn't help here: it starts back at round 0, while the stalled validators sit in a
  round whose timer has doubled each round (320 s at round 4, 640 s at round 5).
- **Chain advancing, but a pod unhealthy**: that pod's logs are saved as
  `fixup-<n>-<pod>.log` and the pod is deleted, so its statefulset recreates it. The worst
  pod goes first (no RPC answer, then most missing peers). Only one pod is restarted at a
  time, so QBFT never loses quorum.

After `maxFixups` fix-ups the run is abandoned before any load is sent. The logs of the
unhealthy pods (every pod, for a stall) are saved as `unhealthy-<pod>.log`, and
`meta.error` says why. The next run tries again from the start.

`meta.json` records `health`: `secondsToHealthy`, `fixups` (`reset` or the pod restarted,
in order) and the final `peers` (pod names) and `heads` per pod.

## Run summary

Results can't come back through git (the VDS can't push), so after each run the script
prints a summary that fits on one screen, and saves it as `summary.txt` and in
`meta.json` (`summary`). Example:

```
  --- Summary: 20261016-140623-t2000 ---
  spamoor eoatx --slot-duration 2s -t 2000 --amount 50
  Load 10.0 min: 300 blocks, avg 2.00 s, max gap 4 s
  598,000 txs = 996.7 tx/s (requested 1,000 tx/s = 2000 per 2s slot); after first 2 min 1,000.1 tx/s
  Tx/block avg 1,993, max 2000
  Gas/block avg 41.9 Mgas, max 42.0 Mgas = 20.9 Mgas/s; 41.86% of the 100.0 Mgas limit avg, 42.00% max
  Stopping spamoor (6 s after load end; pod delete took 4 s): 3 blocks, 6,000 txs
  Drain after spamoor stopped: 27 blocks, 0 txs (txpool empty when spamoor stopped)
  Block production (validator-1 proposed 75 of 300 load blocks):
    ms, after first 2 min (60 blocks)      avg    p50    p95    max
    total                                1,498  1,488  1,812  1,892
    txsSelection                           578    576    684    696
      selectedTxsEvaluation                264    264    264    264
    blockAssembled                         120    120    120    120
    blockImported                          800    800  1,100  1,100
    0 ms throughout: duplicateWorldState, preTxsSelection
    over 2s slot: 0 of 60 (0%); untrimmed total avg 1,648, p95 2,264, over slot 15 of 75
  Txpool pending on validator-1 (300 of 300 load blocks): avg 34,950, max 49,900, at load end 49,900
  Health: healthy after 33 s; fix-ups: none
  CPU cores max (avg) / limit, memory max / limit, during load (! = 95%+ of limit):
    rpc-1        cpu  0.95 (0.70) / 40   mem  1.7Gi / 1.9Gi
    validator-1  cpu  0.98 (0.71) / 40   mem  1.8Gi / 1.9Gi  ! mem 95% of limit
    ...
    spamoor      cpu  3.20 (2.50) / 40   mem  2.1Gi / 160.0Gi
  validator restarts 0 -> 0; validator.log WARN 3, ERROR 0
        3 x WARN RoundTimer | ...
  spamoor.log 1.2 MB: error lines 0, warning lines 0
```

If spamoor was restarted or stopped early, extra lines say so, e.g.
`spamoor attempt 1: Failed 31 s after start; restarted (log in spamoor-failed-1.log)` or
`spamoor Failed after 0.2 of 10 min: load window cut short, run not comparable`.

Where each figure comes from:

- **Blocks and transactions**: read from the chain after cooldown, over RPC on
  `validatorPod` (`eth_getBlockByNumber`, walking back from the head to the first block
  stamped at or after `loadStartUtc`). The load window is `loadStartUtc`–`loadEndUtc`, by
  block timestamp. This reads one block per call, so it takes roughly half a minute for a
  10-minute run.
- **Avg block time / max gap**: from the load blocks' timestamps. The average is the
  span from first to last load block divided by the intervals between them. *Max gap*
  is the longest interval between two consecutive load blocks, in whole seconds (block
  timestamps have 1 s resolution). On a healthy network it equals the slot time
  (`slotDuration`); a larger gap means at least one slot produced no block, usually a
  QBFT round change (a proposer that was slow or missing). Gaps that grow with the
  load point to block building or import not keeping up.
- **Requested tx/s** is `throughput / slotDuration`, which assumes spamoor's `-t` is
  transactions per slot. If tx/block sits near `throughput` while blocks keep to the slot
  time, that assumption holds.
- **"After first 2 min"** uses the same cut as the analysis rule in `CLAUDE.md` (spamoor
  ramp-up, JVM warmup). It's only shown for load windows over 3 minutes.
- **Gas**: absolute gas per block and Mgas/s (total gas in the load window over its
  length), plus gas used as a % of the block gas limit (the limit shown is the last
  load block's).
- **Stopping / drain**: the cooldown is split at `spamoorStoppedUtc`. *Stopping* is
  `loadEndUtc` → `spamoorStoppedUtc`, when spamoor was still sending. *Drain* is after
  that, so its txs (and "last txs at +N s") show the txpool emptying with no new load.
  Runs from before `spamoorStoppedUtc` existed count everything as drain.
- **Block production**: from `validator.log`'s `Produced #N ...` lines, so only the load
  blocks that validator proposed (about 1 in 4 with 4 validators). Lines are matched to
  load blocks by block number, not log timestamp. Newer Besu logs the build time
  (`gas in 2.378s`, the `total` row) and `Timing(...)` per phase. Every `name=<n>ms` in
  `Timing(...)` becomes a row, so phases added or renamed in later releases show up
  without a script change. Phases at 0 ms in every block are listed on one line.
  `selectedTxsEvaluation` is part of `txsSelection` (`txsSelection + blockAssembled +
  blockImported` = total), so it's indented; other phases like it go in
  `$timingSubPhases`. *Over slot* counts blocks whose total exceeded `slotDuration` (taken
  to be the Besu block period). Figures are after the first 2 minutes when the load is
  over 3 minutes, with the untrimmed total alongside. Older Besu without timings gets a
  single line saying so.
- **Txpool pending**: the `N pending` in every `Produced`/`Imported` line (all Besu
  versions), i.e. the logged validator's txpool size after each load block. A pool still
  growing at load end means the load exceeds what the chain can take.
- **CPU/memory**: `top.log` samples inside the load window, against the container limits
  in `meta.limits` (`-` if none). Memory limits are converted to Gi, so a decimal `2G`
  shows as `1.9Gi`. Any container whose max reaches 95% of a limit is marked `!` and
  named in the table's notes: near the CPU limit means throttling, near memory means OOM
  risk.
- **Warnings/errors**: counts of `WARN`/`ERROR` in `validator.log` (the whole run, not
  just the load), with the three most common messages (numbers and hashes blanked so
  repeats group). For `spamoor.log`: its size, the count of `level=error` (and `panic:`)
  and `level=warning` lines, and the three most common of those messages. It's read in
  one streaming pass because it can be over 1 GB.
- **spamoor failures**: a retry, or a pod not `Running` at load end, adds a line and a
  note. A load window cut short puts `SPAMOOR FAILED at <n> min` first in the notes.

The end-of-batch table has one row per run: requested and achieved tx/s (also after the
first 2 minutes), average and max tx/block, Mgas/s, average gas used %, average block time (`Blk s`), the longest gap between
consecutive load blocks in seconds (`Max gap s`, see above),
block build time avg/p95 in ms and the % of blocks built over the slot (the logged
validator's own blocks after the first 2 minutes; empty for Besu without timings), the
largest txpool pending count on the logged validator during the load (`Max pending`, the
whole load window; a value close to the txpool's capacity means the pool filled up), the
highest Besu CPU and memory (and which pod), the run's `extraArgs`, and notes such as
errors, fix-ups, restarts and containers at 95%+ of a limit. If the summary itself
fails, the run is still packaged and the table row says why. The table is also saved as
`runs\[<group>\]<yyyyMMdd-HHmmss>-batch-summary.txt` (the batch's start time, so a reused
group doesn't overwrite an earlier batch's table), and committed and pushed with `-Push`.

## Cleanup and packaging

- **`catch`** stores the error message in `meta.error`, and the loop continues.
- **`finally`** always runs, including on Ctrl+C:
  - `logStreamDiedEarly` is set to true if the background kubectl had **already exited
    on its own**. That is the signal that the validator restarted, since the stream dies
    with the container.
  - `rpcLogStreamDiedEarly` is the same for `rpc.log` (the RPC node restarted).
  - It then stops the streams, and deletes the spamoor pod if `$spamoorAlive` is still set.
- **Fallback logs**: if the stream died, it saves `--since-time=logStartUtc` logs from the
  current container as `validator-fallback.log`. If the restart count also changed, it
  saves `--previous` as `validator-previous.log`, which is usually where an OOMKill shows up.
- **Packaging**: writes `meta.json` and zips the run folder. If the zip is at most
  `-MaxZipMB`, it's copied into `runs\` (or `runs\<group>\`) and, with `-Push`, committed
  and pushed. A larger zip stays only in `-WorkRoot`.

## Warmup

`warmupSeconds` (60 in the current plan) is **idle time with no load** after the health
check passes. It only happens after a reset or a fix-up restart. `meta.json` records the
value used (0 when skipped).

- The health check has already confirmed peering and block production, so this is extra
  settle time for freshly started JVMs, not a wait for the network to come up.
- It is recorded in `validator.log` (`healthyUtc` → `loadStartUtc`).
- There is no load warmup. The first part of the load window includes spamoor's own
  startup (funding its child wallets before it reaches the requested rate) and Besu's JVM
  warming up under load. This is handled at analysis time by trimming the start of the
  load window; see "Analysing results" in `CLAUDE.md`.

Without a reset (and with no fix-ups), there's no warmup sleep: the next run starts once
the health check passes after the previous run's cooldown.

## Known limitations

1. **One failed status check ends the load phase early.** If the phase lookup fails once
   (an API blip), `Get-PodField` returns `$null`, which isn't `'Running'`, so the loop
   treats spamoor as stopped.
2. **`spamoor.log` can be huge.** When the network can't keep up, spamoor logs every
   rejected tx (about 2 MB/s seen), so a 10-minute run can produce over 1 GB, and its zip
   may go over `-MaxZipMB` and stay in `-WorkRoot`.
3. **Run IDs use local time**, while every timestamp in `meta.json` is UTC. That's fine if
   the VDS clock is UTC; otherwise zip names and meta timestamps are offset from each other.
4. **The private key is in the pod's args.** It never reaches git, but anyone who can read
   pods in the namespace can see it (`kubectl get pod -o yaml`). A Kubernetes Secret
   would hide it.
5. **Smaller points:**
   - Because stderr is merged into output, a `kubectl top` error can end up as a line in
     `top.log`. Analysis should skip lines that don't parse.
   - The restart count reads `containerStatuses[0]`, which assumes the Besu pod has only
     one container.
   - `--since-time` compares the VDS clock with the node's. If the VDS runs ahead, the
     first few seconds of `validator.log` can be missing.
