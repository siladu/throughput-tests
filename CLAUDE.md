# throughput-tests

Load/throughput testing harness for a private Hyperledger Besu (QBFT) network on AKS.
Spamoor is the current load generator; other tools will be added later, so keep the
harness tool-agnostic where it's cheap to do so.

## How this repo is used (read first)

There are two machines. Git carries scripts **one way only**, host → VDS:

| Machine | Who | Can reach the cluster? | Role |
|---|---|---|---|
| Host | You (Claude Code) + the user | **No** | Edit scripts and test plans, commit and push, analyse results |
| VDS (Windows, PowerShell) | The user only | Yes (kubectl) | `git pull`, run tests |

- **The VDS can't push to GitHub.** Results, logs and command output come back only as
  console output the user relays, so run results won't normally appear in `runs/` on the host.
  When asking for data, ask for something that fits on a screen (counts, summaries,
  `Select-String` filtered log lines), not whole files.
- You cannot run kubectl, PowerShell scripts or tests yourself. Nothing in `scripts/` is
  meant to run on the host.
- When the user needs to do something on the VDS, give **copy-pasteable PowerShell** in a
  single block. The user relays the output back.
- Folder ownership keeps the two sides from conflicting:
  - `scripts/` (and any analysis/docs): written on the host, pulled on the VDS.
  - `runs/`: written **only** by the VDS. Never edit, rename or delete files in `runs/`
    unless the user explicitly asks.
- Always `git pull` before changing anything; results may have arrived since last session.

## Layout

```
scripts/
  Run-SpamoorTests.ps1        # test loop: run load, capture logs, [zip, push]
  README-Run-SpamoorTests.md  # walkthrough of the runner; keep in sync when changing it
  spamoor-run.template.yml    # spamoor pod manifest, rendered per run
  test-plan.json              # which runs to do, and settings
runs/
  [<group>/]<yyyyMMdd-HHmmss>-<name>/      # one folder per run, on the VDS (group if given)
  [<group>/]<yyyyMMdd-HHmmss>-<name>.zip   # only with -Zip or -Push
  [<group>/]<yyyyMMdd-HHmmss>-batch-summary.txt  # end-of-batch comparison table
```

## The test loop (Run-SpamoorTests.ps1)

Invocation: `.\scripts\Run-SpamoorTests.ps1 [<group>] [-NoReset] [-Zip] [-Push]`.
`<group>` is an optional subfolder of `runs/`. `-NoReset` overrides the plan's
`resetNetwork`. Each run's results are a folder in `runs/[<group>/]`, untracked in git.
Zipping is **off by default**: `-Zip` also zips each folder next to it; `-Push` zips and
commits and pushes the zip. `-Push` won't work from the VDS while it can't push.

Per run in `test-plan.json`:

1. Optionally reset the network (`resetNetwork`, unless `-NoReset`): scale every
   statefulset to 0, wait until all Besu pods are gone, scale back to 1. Not
   `rollout restart`, which lets new nodes peer with old ones and inherit their txpools.
2. Health check: port-forward to every Besu pod and poll `admin_peers` /
   `eth_blockNumber` until each is connected to all its static peers (`besu-peers`
   configmap), none lags, and the chain has advanced. Missing links are re-dialled with
   `admin_addPeer` every poll. If still unhealthy after `healthTimeoutSeconds`: a stalled
   chain gets a full reset, otherwise the worst pod is restarted (one at a time). After
   `maxFixups` of those, the run is abandoned.
3. Stream every validator's (Besu pods named `*validator*`) and the RPC node's logs with
   `kubectl logs -f --since-time=<logStartUtc>`, which backfills the reset and health
   check. Streaming is used instead of a one-off `kubectl logs` because kubelet log
   rotation would drop lines. Then wait `warmupSeconds` if there was a reset or fix-up.
4. Render the template and apply the spamoor pod; wait for Ready, then stream its log
   too. If spamoor exits within 60 s, keep that log and start it once more.
5. For `durationMinutes`, sample `kubectl top pods --containers` every `sampleSeconds`.
6. Delete spamoor's pod (5 s grace; the delete is timed), keep logging for
   `cooldownSeconds` (txpool drain).
7. Stop the streams, print a screen-sized summary (blocks and txs read from the chain,
   tx/s achieved vs requested (and as a %), gas per block / Mgas/s / % of gas limit, txs while spamoor
   was stopping vs drained after, block build time per phase pooled over every
   validator's own blocks (newer Besu only), one line per validator (blocks proposed,
   build time, txpool size, restarts, WARN/ERROR counts), STALL lines (5+ empty load
   blocks while a validator's pending count stays flat), CPU/memory against limits with
   95%+ flagged, warnings, spamoor send errors, spamoor's max pending and the % of
   blocks where it sat at its max-pending cap),
   write `summary.txt`, `validators.txt` (per-validator detail) and `meta.json`,
   all into `runs/[<group>/]<runId>/`; with `-Zip`/`-Push` zip it next to the folder, and
   with `-Push` commit and push that zip only.

After the last run it prints a table comparing every run in the batch and saves it as
`runs/[<group>/]<yyyyMMdd-HHmmss>-batch-summary.txt` (batch start time). That table and
the per-run summaries are normally what the user relays back for analysis.

Runs before 2026-10-27 were built in `$HOME\spamoor-runs\[<group>\]<runId>\` on the VDS
and only a zip went into `runs/`; later runs are folders in `runs/[<group>/]<runId>\`.

Errors in one run are recorded in `meta.json` and the loop moves on.

### test-plan.json

Top level: `image` (`name:tag` only, no registry), `namespace`, `rpcUrl`,
`scenario` (spamoor subcommand), `slotDuration`, `resetNetwork`, `warmupSeconds`,
`healthTimeoutSeconds`, `maxFixups`, `cooldownSeconds`, `sampleSeconds`, `runs`, and
optional `label` (free text saying what the batch tests, e.g. Besu version and config;
printed in the batch summary, each run's summary header and `meta.label`), `rpcPod`
(defaults to the first label of `rpcUrl`'s host) and `validatorPod`
(the validator the summary reads blocks from over RPC; defaults to the first one; every
validator's log is captured regardless).

Each run: optional `name` (the run is named `tps<throughput / slotDuration>`, e.g.
`tps8000` for `-t 16000` on a 2 s slot; `name` is appended as `tps8000-<name>` to tell
apart runs at the same rate; it becomes part of the run ID and pod name, keep it short,
lowercase, `[a-z0-9-]`), `durationMinutes` (expected 5-15), `throughput` (spamoor `-t`), `amount`
(spamoor `--amount`), optional `extraArgs` (array of extra spamoor CLI args).

When editing the plan, update `label` to match what the batch tests, and tell the user the rough total wall time
(sum of durations + per-run warmup/cooldown + a few minutes per network restart and health
check; up to `(maxFixups + 1) × healthTimeoutSeconds` extra if fix-ups are needed).

### Run folder contents

- `validator-<N>.log`: Besu logs from each validator, covering just that run, including
  the reset and health check. Runs before 2026-10-27 have a single `validator.log`
  (validator-1 only).
- `rpc.log`: Besu logs from the RPC node spamoor sends to, same window as the validator
  logs.
- `spamoor.log`: the load generator's own output, streamed from its start. Can exceed
  1 GB when the network is overloaded (a warning per rejected tx).
- `spamoor-failed-<n>.log`: a spamoor attempt that died in its first minute and was
  retried (`meta.spamoorFailures`).
- `spamoor-events.log`: only if deleting spamoor's pod took over 60 s.
- `summary.txt`: the summary printed at the end of the run (also in `meta.json` as
  `summary`).
- `validators.txt`: per validator, its own build-timing table, txpool pending
  avg/max/end, restarts and most common WARN/ERROR messages.
- `top.log`: `<UTC timestamp> <pod> <container> <cpu> <memory>` samples for every pod.
- `meta.json`: parameters (incl. `group`, `label`, `resetNetwork`, `warmupSeconds`), UTC timestamps
  (`logStartUtc`, `healthyUtc`, `loadStartUtc`, `loadEndUtc`, `spamoorStoppedUtc`,
  `endUtc`; spamoor keeps sending between `loadEndUtc` and `spamoorStoppedUtc`, so the
  txpool drain starts at the latter), `health` (`secondsToHealthy`, `fixups`, final
  `peers`/`heads` per pod), `limits` (CPU/memory limit per `<pod>/<container>`),
  `validatorPods`, per validator: `validatorNodes`, `validatorRestartsBefore`/`After`,
  `logStreamDiedEarly`; also `spamoorNode`, `rpcLogStreamDiedEarly`,
  `spamoorPhase`, `spamoorAttempts`, `spamoorFailures`, `spamoorDeleteSeconds`, `error`
  if any.
- `fixup-<n>-<pod>.log`: logs taken just before a fix-up (the restarted pod, or every pod
  for a full reset). Evidence for the startup peering problem (see Cluster context).
- `unhealthy-<pod>.log`: present when the run was abandoned because the network never
  became healthy (no load was sent).
- `validator-<N>-fallback.log` / `validator-<N>-previous.log`: only present if that
  validator restarted mid-run. A restart during a run usually means OOMKilled; flag it.

## Analysing results

- Usually the input is the console output of the per-run summaries and the batch table,
  not the run folders. Work from those; if a question needs more, give the user a PowerShell block
  that pulls just that out of `runs\<group>\<runId>\` on the VDS.
- If you do have zips, unzip them into a scratch location outside the repo (or a
  gitignored folder), never into `runs/`.
- Use `meta.json` timestamps to separate warmup, load and cooldown phases in the logs.
- Check `health` in `meta.json`: runs that needed fix-up restarts started with a freshly
  restarted pod, so note them when comparing.
- Steady-state metrics exclude the first 2 minutes after `loadStartUtc` (spamoor wallet
  funding/ramp, JVM JIT warmup), using the same time cut in every log. Before
  relying on the cut, check per-minute txs/block and achieved TPS have flattened by
  then; if not, say so and use a longer cut for all runs being compared. Show the
  untrimmed figures alongside.
- Compare runs on: block production rate and gaps, transactions per block, achieved vs
  requested throughput (`Deliv %`), stalls, spamoor send errors, spamoor at its pending cap
  (`At cap`: near 100% means `--max-pending` limited the load, not the network), block build time (total and per phase) and blocks built over the
  slot, txpool size, validator CPU/memory under load, restarts, and errors/warnings in
  the validator logs. Build timings only exist from Besu versions that log
  `Produced ... Timing(...)`, so don't compare them with runs on older Besu. Runs before
  2026-10-27 timed only validator-1's blocks (~1 in 4) and showed only its txpool; later
  runs pool every validator's blocks, so compare those figures with care.
- Check the requested load was actually generated (spamoor.log) before concluding the
  network was the bottleneck.
- Present findings as a comparison across runs, and say which runs are not comparable
  (different settings, errors, restarts).

## Cluster context

- AKS, namespace `besu-consensus`. Besu installed via Helm from a separate private repo
  (`<redacted-name>`, chart `./charts/besu-node`); releases `validator-1`..`validator-4`
  and `rpc-1`.
- Pods: `besu-node-validator-<N>-0`, `besu-node-rpc-1-0`. 4 QBFT validators, so consensus
  tolerates only one validator down. Don't suggest anything that takes down two at once
  except a deliberate full-network restart.
- Pod resource limits change between deployments (the 500m/1-core, 2G figures noted
  earlier are out of date; the user reports 40 CPU request and limit). Don't assume them:
  each run records every container's limits in `meta.limits` and the summary prints them.
  Besu is a JVM: memory problems show as OOMKilled, CPU limits as throttling.
- Node pool `besu` (taint `nodekind=besunode:NoSchedule`): one Besu pod per node via
  pod anti-affinity on `app.kubernetes.io/component=besu`. The load generator must
  tolerate the taint, require `kubernetes.azure.com/agentpool In (besu)` (otherwise it
  lands in the separate `besu2` pool), and use the same anti-affinity so it gets the
  free node.
- Besu version changes between batches: 26.9.0 as of 2026-10-20, earlier batches on
  25.7.0, and the user may switch back and forth or move to later releases. Don't assume
  a version; the script must keep working with older log formats (e.g. 25.7.0 has no
  `Timing(...)` in `Produced` lines), and runs on different versions aren't directly
  comparable. Every pod has HTTP
  JSON-RPC on 8545 with the ADMIN API, and no readiness probe (Ready = container started).
  Peering comes from configmaps `besu-peers` (`static-nodes.json`: all 4 validators +
  rpc-1, by headless-service DNS name) and `besu-bootnodes` (validator-1, validator-2).
  The chart already sets `--Xdns-enabled=true --Xdns-update-enabled=true`.
- Known issue (seen on 25.7.0): after a full restart some static-peer links never form
  (on 2026-10-16, validator-4 never peered with validator-1/2 in either direction). If
  that splits the validators, QBFT stalls until the doubling round timers line up (10+
  minutes). The runner works around it with `admin_addPeer`. Keep the workaround and the
  pre-run health check whatever the version: the user may revert Besu, and checking
  health before every run keeps runs consistent.
- Besu config (as of 2026-10-19, `besu-node-<release>-besu-config` configmaps, config.toml):
  `data-storage-format="FOREST"`, `sync-mode="FULL"`, `min-gas-price=0`, layered txpool
  with no tx-pool options set (all defaults). Block gas limit is 2^53−1, so gas never
  binds. Block selection is capped at 1500 ms (PoA default 75% of the 2 s period); the
  2026-10-19 baselines topped out at ~1,500–1,650 tx/s with selection being interrupted.
  The user changes this config between batches, so re-check before comparing.
- From the VDS, `kubectl port-forward` takes about 5 s to start listening.
- RPC endpoint inside the cluster:
  `http://besu-node-rpc-1-0.besu-node-rpc-1.besu-consensus.svc.cluster.local:8545`.

## Writing scripts for the VDS

Target **Windows PowerShell 5.1** unless told otherwise:

- Don't use `>` / `Out-File` for large native output: 5.1 writes UTF-16. Use
  `Save-NativeOutput` (Start-Process with `-RedirectStandardOutput`).
- Call native tools through `Invoke-Native`: under `$ErrorActionPreference = 'Stop'`,
  5.1 turns any stderr line from kubectl/git into a terminating error.
- No PowerShell 7-only syntax (`??`, `?.`, ternary, `-Parallel`, `&&`).
- Quote kubectl jsonpath arguments (braces otherwise parse as script blocks).
- Never put double quotes inside an argument to a native command (e.g. `{"\n"}` in a
  jsonpath): 5.1 doesn't escape them, so kubectl receives them stripped.
- Kubernetes names: lowercase `[a-z0-9-]`, max 63 characters.
- Prefer small, reviewable diffs; the user can't easily debug on the VDS.

### Adding another load generator

Keep the same shape so results stay comparable: a `Run-<Tool>Tests.ps1` (or a `tool`
field in the plan if refactoring to one runner), a `<tool>-run.template.yml`, its own
plan file, and the same run folder contents (`validator-<N>.log`, `top.log`, `meta.json`, plus the
tool's own log). Shared helpers can move to a `scripts/common.ps1` dot-sourced by each
runner once there's a second tool, not before.

## Data handling

- Never commit secrets. The spamoor private key lives at `$HOME\spamoor-privkey.txt` on
  the VDS, outside the repo, and is injected at render time; `meta.json` redacts it.
  Don't add keys, tokens or kubeconfigs to any file here.
- Never commit the internal image registry or anything naming the organisation. The
  registry + path prefix comes from `$env:IMAGE_REGISTRY` on the VDS and is prepended to
  the plan's `image` at render time; `meta.json` records only `image`.
- GitHub rejects files over 100 MB; `-Push` skips zips over 95 MB. Never commit run
  folders (`spamoor.log` alone can be 1 GB+). Run zips stay
  in history forever, so suggest a fresh repo/branch after large batches.
