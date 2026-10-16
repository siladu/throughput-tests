# Run-SpamoorTests.ps1

Runs every load test listed in `test-plan.json`, one after another. For each run it
captures the validator's logs and CPU/memory samples, then zips the results into `runs/`
and, with `-Push`, commits and pushes them. It runs on the VDS under Windows PowerShell 5.1.

The VDS currently can't push to GitHub, so leave `-Push` off there and share results as
screenshots or pasted output.

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
[reset network] → health check (+ fix-ups) → start validator log stream → [warmup]
→ start spamoor → load + sample CPU/mem → save spamoor log, kill spamoor → cooldown
→ stop stream → meta.json → zip → [git push]
```

Each run is wrapped so that a failure is written into that run's `meta.json` and the loop
moves on to the next run.

Timeline of one run and the `meta.json` timestamps. `validator.log` covers all of it,
from `logStartUtc` to `endUtc`:

```
logStartUtc ──┬─ ... reset (if enabled), health check, fix-ups ...
              ├─ healthyUtc    every pod peered with all its static peers, chain advancing
              │   ... warmup (idle, warmupSeconds; only after a reset or fix-up) ...
              ├─ loadStartUtc  spamoor pod Ready
              │   ... load + top sampling ...
              ├─ loadEndUtc    spamoor log saved, pod deleted
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

- **Run ID**: a timestamp plus the cleaned run name. The pod name is `spamoor-<runId>`,
  truncated to the 63-character Kubernetes limit.
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
2. **Log stream**: `kubectl logs -f --since-time=<logStartUtc>` runs as a **background
   process** writing to `validator.log`.
   - `--since-time` backfills everything since the run began: the reset, Besu startup,
     peering and the health check, even if the validator was restarted in between.
   - Streaming matters because kubelet rotates container logs, and a single
     `kubectl logs` at the end would lose the start of a long, noisy run.
   - A 3-second sleep lets the stream attach before anything else happens.
3. **Warmup**: after a reset or a fix-up restart, the network is left idle for
   `warmupSeconds` (see [Warmup](#warmup)).
4. **Start spamoor**: the manifest is piped to `kubectl apply -f -`, then the script waits
   up to 10 minutes for the pod to be Ready. `loadStartUtc` is stamped once it's Ready.
5. **Sampling loop**:
   - Every `sampleSeconds` it appends `kubectl top pods --containers` to `top.log`, with
     a UTC timestamp at the start of each line.
   - It also checks spamoor's phase, and **stops early** if the pod is no longer
     `Running` (for example, if it crashed).
   - The last sleep is cut short so the load phase ends on time.
6. **Spamoor teardown**: spamoor's logs are saved *before* the pod is deleted, because
   deleting it discards them.
7. **Cooldown**: the validator stream keeps running for `cooldownSeconds` so the txpool
   draining is captured.

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

## Cleanup and packaging

- **`catch`** stores the error message in `meta.error`, and the loop continues.
- **`finally`** always runs, including on Ctrl+C:
  - `logStreamDiedEarly` is set to true if the background kubectl had **already exited
    on its own**. That is the signal that the validator restarted, since the stream dies
    with the container.
  - It then stops the stream, and deletes the spamoor pod if `$spamoorAlive` is still set.
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
2. **`spamoor.log` comes from a single `kubectl logs` call at the end.** If spamoor is very
   verbose at high throughput, kubelet rotation could cut off the start of it. The
   validator log doesn't have this problem because it's streamed.
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
