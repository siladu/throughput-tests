# Run-SpamoorTests.ps1

Runs every load test listed in `test-plan.json`, one after another. For each run it
captures the validator's logs and CPU/memory samples, then zips the results and pushes
them to `runs/`. It runs on the VDS under Windows PowerShell 5.1.

```powershell
git pull
.\scripts\Run-SpamoorTests.ps1            # all runs, push each result as it finishes
.\scripts\Run-SpamoorTests.ps1 -NoPush    # keep results local (still copied into runs/)
```

## Overall shape

For each entry in `test-plan.json`:

```
[reset network] → start validator log stream → [warmup] → start spamoor → load + sample CPU/mem
→ save spamoor log, kill spamoor → cooldown → stop stream → meta.json → zip → git push
```

Each run is wrapped so that a failure is written into that run's `meta.json` and the loop
moves on to the next run.

Timeline of one run and the `meta.json` timestamps:

```
Reset-Network ──┬─ logStartUtc   validator log stream starts (after a reset: from container start)
                │   ... warmup (idle, warmupSeconds) ...
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
| `-PlanFile` | `scripts\test-plan.json` | |
| `-TemplateFile` | `scripts\spamoor-run.template.yml` | |
| `-RepoRoot` | parent of `scripts\` | |
| `-WorkRoot` | `$HOME\spamoor-runs` | Each run's files are built here before zipping. Outside the repo, so it keeps a full local copy of every run, including zips too big for git |
| `-PrivKeyFile` | `$HOME\spamoor-privkey.txt` | |
| `-Registry` | `$env:IMAGE_REGISTRY` | Registry + path prefix, without the image name |
| `-MaxZipMB` | `95` | GitHub rejects files over 100 MB |
| `-NoPush` | off | Still copies the zip into `runs/`, but skips the commit and push |

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
- **`Reset-Network`**:
  - It restarts **every statefulset at once**, which is the deliberate full-network
    restart (all 4 validators plus the RPC node).
  - It then waits on `rollout status` for each one, with a 15-minute timeout. The warmup
    sleep happens later, once the log stream is running.
- **`Publish-Runs`**:
  - It stages **only `runs/`**, and commits only if something is actually staged.
  - It then tries `pull --rebase --autostash` + `push` up to 3 times with backoff, so
    pushes from the host while a batch is running don't break it.
  - If all attempts fail, the commit stays local and goes up with the next successful push.

## Setup

- The plan and template are read **once at startup**. If you push a plan change
  mid-batch, the running batch ignores it; it applies from the next invocation.
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

1. **Reset and restart baseline**: if `resetNetwork` is set, the network is restarted.
   The validator's restart count is read *after* the reset, so the before/after
   comparison only covers this run.
2. **Log stream**: `kubectl logs -f` runs as a **background process** writing to
   `validator.log`.
   - After a reset the container is fresh, so the stream takes its whole log, including
     Besu startup and peering. Without a reset it adds `--tail=0` and captures nothing
     from before this point.
   - Streaming matters because kubelet rotates container logs, and a single
     `kubectl logs` at the end would lose the start of a long, noisy run.
   - A 3-second sleep lets the stream attach before anything else happens.
3. **Warmup**: if `resetNetwork` is set, the network is left idle for `warmupSeconds`
   while the stream records it (see [Warmup](#warmup)).
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
- **Packaging**: writes `meta.json`, zips the run folder, and puts it in `runs/` and
  pushes it if it's at most `-MaxZipMB`. A larger zip stays only in `-WorkRoot`.

## Warmup

`warmupSeconds` (60 in the current plan) is **idle time with no load**, and it only
happens when `resetNetwork` is true. `meta.json` records the value used (0 without a
reset).

- It starts after `rollout status` reports every statefulset rolled out, which means the
  pods are Ready. It does not mean QBFT is producing blocks again.
- Nothing is sent during it. It is time for the restarted validators to reconnect and
  resume block production, not a load ramp-up.
- It is recorded in `validator.log` (`logStartUtc` → `loadStartUtc`), along with the
  validator's startup. Check that blocks were being produced before `loadStartUtc`.
- There is no load warmup. The first part of the load window includes spamoor's own
  startup (funding its child wallets before it reaches the requested rate) and Besu's JVM
  warming up under load. This is handled at analysis time by trimming the start of the
  load window; see "Analysing results" in `CLAUDE.md`.

When `resetNetwork` is false there is no restart and no warmup sleep: the next run starts
straight after the previous run's cooldown.

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
