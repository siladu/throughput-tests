# throughput-tests

Load/throughput testing harness for a private Hyperledger Besu (QBFT) network on AKS.
Spamoor is the current load generator; other tools will be added later, so keep the
harness tool-agnostic where it's cheap to do so.

## How this repo is used (read first)

There are two machines, and **git is the only data channel between them**:

| Machine | Who | Can reach the cluster? | Role |
|---|---|---|---|
| Host | You (Claude Code) + the user | **No** | Edit scripts and test plans, analyse results |
| VDS (Windows, PowerShell) | The user only | Yes (kubectl) | `git pull`, run tests, push results |

- You cannot run kubectl, PowerShell scripts or tests yourself. Nothing in `scripts/` is
  meant to run on the host.
- When the user needs to do something on the VDS, give **copy-pasteable PowerShell** in a
  single block. The user relays output back as pasted text or screenshots.
- Folder ownership keeps the two sides from conflicting:
  - `scripts/` (and any analysis/docs): written on the host, pulled on the VDS.
  - `runs/`: written **only** by the VDS. Never edit, rename or delete files in `runs/`
    unless the user explicitly asks.
- Always `git pull` before changing anything; results may have arrived since last session.

## Layout

```
scripts/
  Run-SpamoorTests.ps1        # test loop: run load, capture logs, zip, push
  README-Run-SpamoorTests.md  # walkthrough of the runner; keep in sync when changing it
  spamoor-run.template.yml    # spamoor pod manifest, rendered per run
  test-plan.json              # which runs to do, and settings
runs/
  <yyyyMMdd-HHmmss>-<name>.zip  # one zip per run, pushed from the VDS
```

## The test loop (Run-SpamoorTests.ps1)

Per run in `test-plan.json`:

1. Optionally restart all statefulsets (`resetNetwork`).
2. Start streaming the validator's logs (`kubectl logs -f`; from container start after a
   reset, else `--tail=0`), then wait `warmupSeconds` if reset. Streaming is used instead
   of a one-off `kubectl logs` because kubelet log rotation would drop lines.
3. Render the template and apply the spamoor pod; wait for Ready.
4. For `durationMinutes`, sample `kubectl top pods --containers` every `sampleSeconds`.
5. Save spamoor's logs, delete its pod, keep logging for `cooldownSeconds` (txpool drain).
6. Stop the stream, write `meta.json`, zip, copy into `runs/`, commit and push.

Errors in one run are recorded in `meta.json` and the loop moves on.

### test-plan.json

Top level: `image` (`name:tag` only, no registry), `namespace`, `validatorPod`, `rpcUrl`,
`scenario` (spamoor subcommand), `slotDuration`, `resetNetwork`, `warmupSeconds`,
`cooldownSeconds`, `sampleSeconds`, `runs`.

Each run: `name` (becomes part of the run ID and pod name, keep it short, lowercase,
`[a-z0-9-]`), `durationMinutes` (expected 5-15), `throughput` (spamoor `-t`), `amount`
(spamoor `--amount`), optional `extraArgs` (array of extra spamoor CLI args).

When editing the plan, tell the user the rough total wall time
(sum of durations + per-run warmup/cooldown + a few minutes per network restart).

### Run zip contents

- `validator.log`: Besu logs from one validator, covering just that run.
- `spamoor.log`: the load generator's own output.
- `top.log`: `<UTC timestamp> <pod> <container> <cpu> <memory>` samples for every pod.
- `meta.json`: parameters, UTC timestamps (`logStartUtc`, `loadStartUtc`, `loadEndUtc`,
  `endUtc`), nodes used, validator restart counts before/after, `logStreamDiedEarly`,
  `spamoorPhase`, `error` if any.
- `validator-fallback.log` / `validator-previous.log`: only present if the validator
  restarted mid-run. A restart during a run usually means OOMKilled; flag it.

## Analysing results

- Unzip into a scratch location outside the repo (or a gitignored folder), never into `runs/`.
- Use `meta.json` timestamps to separate warmup, load and cooldown phases in the logs.
- Check blocks were being produced during warmup (before `loadStartUtc`); if not, the
  run started on an unsettled network.
- Steady-state metrics exclude the first 2 minutes after `loadStartUtc` (spamoor wallet
  funding/ramp, JVM JIT warmup), using the same time cut in all three logs. Before
  relying on the cut, check per-minute txs/block and achieved TPS have flattened by
  then; if not, say so and use a longer cut for all runs being compared. Show the
  untrimmed figures alongside.
- Compare runs on: block production rate and gaps, transactions per block, achieved vs
  requested throughput, validator CPU/memory under load, restarts, and errors/warnings in
  `validator.log`.
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
- Each Besu pod: CPU 500m request / 1 limit, memory 1G request / 2G limit. Besu is a JVM:
  memory problems show as OOMKilled, CPU limits as throttling.
- Node pool `besu` (taint `nodekind=besunode:NoSchedule`): one Besu pod per node via
  pod anti-affinity on `app.kubernetes.io/component=besu`. The load generator must
  tolerate the taint, require `kubernetes.azure.com/agentpool In (besu)` (otherwise it
  lands in the separate `besu2` pool), and use the same anti-affinity so it gets the
  free node.
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
- Kubernetes names: lowercase `[a-z0-9-]`, max 63 characters.
- Prefer small, reviewable diffs; the user can't easily debug on the VDS.

### Adding another load generator

Keep the same shape so results stay comparable: a `Run-<Tool>Tests.ps1` (or a `tool`
field in the plan if refactoring to one runner), a `<tool>-run.template.yml`, its own
plan file, and the same zip contents (`validator.log`, `top.log`, `meta.json`, plus the
tool's own log). Shared helpers can move to a `scripts/common.ps1` dot-sourced by each
runner once there's a second tool, not before.

## Data handling

- Never commit secrets. The spamoor private key lives at `$HOME\spamoor-privkey.txt` on
  the VDS, outside the repo, and is injected at render time; `meta.json` redacts it.
  Don't add keys, tokens or kubeconfigs to any file here.
- Never commit the internal image registry or anything naming the organisation. The
  registry + path prefix comes from `$env:IMAGE_REGISTRY` on the VDS and is prepended to
  the plan's `image` at render time; `meta.json` records only `image`.
- GitHub rejects files over 100 MB; the runner keeps zips over 95 MB local. Run zips stay
  in history forever, so suggest a fresh repo/branch after large batches.
