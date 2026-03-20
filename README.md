# raid-drive-validator

`raid-drive-validator` is a shell-first toolkit for destructive qualification of disks before they enter a RAID or ZFS pool.

It grew out of a practical storage design discussion for two machines:

- **newton**: the operational ZFS server with roughly **14 TB** already allocated in its pool
- **stein**: the backup storage server that will receive replicated data over **10 GbE** using native ZFS send/receive

The operational requirement was to build a backup RAIDZ2 pool on `stein` from older **4 TB HDDs**, keep one extra disk as a hot spare, and make sure the chosen disks were healthy enough before trusting them with backup duty.

The design choices captured here came directly from that reasoning:

- keep the backup pool simple
- favor a single-HBA, single-NUMA-domain layout for the HDD pool
- avoid unnecessary ZFS complexity like consumer-SSD SLOG devices for the backup target
- burn in older drives *before* creating the pool
- surface not only obvious SMART failures, but also weak/slow/erratic disks and controller-path problems

The result is a toolkit with:

- SMART health checks
- SMART short and long self-tests
- destructive `badblocks` surface testing
- optional thermal / mechanical stress testing
- latency variance detection with `fio`
- simple reliability scoring
- kernel log checks for controller, bus, cable, and timeout problems
- auto-discovery of drives by vendor/model and capacity
- a tmux-based parallel runner with a dashboard window
- Debian packaging support, including helper scripts to build `.deb` packages inside a debootstrapped **Debian Trixie** chroot

## Repository layout

```text
raid-drive-validator/
├── README.md
├── LICENSE
├── Makefile
├── .gitignore
├── bin/
│   ├── drive_burnin_test.sh
│   └── drive_burnin_tmux.sh
├── lib/
│   ├── common.sh
│   ├── disk_discovery.sh
│   └── scoring.sh
├── dashboard/
│   └── dashboard.sh
├── config/
│   └── burnin.conf
├── docs/
│   ├── architecture.md
│   ├── burnin_methodology.md
│   └── zfs_backup_use_case.md
├── examples/
│   └── example-run.sh
├── tests/
│   ├── test_discovery.sh
│   └── test_scoring.sh
├── tools/
│   ├── install_dependencies.sh
│   ├── build_package.sh
│   └── build_in_chroot.sh
└── debian/
    ├── changelog
    ├── control
    ├── rules
    ├── install
    ├── links
    └── source/format
```

## What the toolkit tests

### 1. SMART overall health

Runs `smartctl -H` to catch obvious hardware failure immediately.

### 2. SMART attribute capture

Records values such as:

- `Reallocated_Sector_Ct`
- `Current_Pending_Sector`
- `Offline_Uncorrectable`
- `UDMA_CRC_Error_Count`
- temperature-related SMART attributes

These attributes are later used for scoring and final PASS / REVIEW / FAIL decisions.

### 3. SMART short self-test

A quick firmware-level diagnostic that usually completes in a few minutes.

### 4. SMART long self-test

A deeper firmware-level scan that usually takes hours on large HDDs.

### 5. Destructive surface test

Runs `badblocks -wsv` across the entire drive.

This matters because the drive firmware, not the filesystem, is what remaps bad sectors. A destructive surface test forces the disk to encounter weak sectors now, so that it either remaps them or exposes them before the disk is used in RAID.

### 6. Latency variance detection

Some disks look healthy in SMART but behave badly under load. In arrays, those are often the “silent killers” that drag down rebuilds or cause severe tail-latency spikes.

The toolkit runs a timed `fio` random-read test and extracts simple statistics like mean latency and p99 latency.

### 7. Optional thermal / mechanical stress phase

Enabled with `--stress`.

This adds sustained read/write/read streaming passes after the destructive test to help expose drives that only misbehave once they are warm or under continuous mechanical load.

### 8. Kernel log inspection

The toolkit snapshots the kernel log before and after testing and looks for signs of controller, bus, cable, or transport problems, including errors such as:

- I/O failures
- command timeouts
- resets
- CRC issues
- medium errors

## Reliability scoring

The scoring system is intentionally simple and conservative.

It starts each drive at `100` and subtracts points for:

- reallocated sectors
- pending sectors
- uncorrectable sectors
- CRC / bus errors
- high temperature
- poor mean latency
- poor p99 latency

Current verdict mapping:

- `PASS`: score >= 90
- `REVIEW`: score 75–89
- `FAIL`: score < 75

This is not meant to be a predictive ML model. It is a practical operator-oriented heuristic that helps rank drives after destructive qualification.

## Controller / bus / connection issues

Yes, the toolkit tries to detect these too.

It does so in two ways:

1. by recording SMART counters such as `UDMA_CRC_Error_Count`
2. by checking kernel log deltas for resets, timeouts, I/O errors, and similar transport-level failures

That means the toolkit is not only screening media quality, but also helping expose flaky cables, backplanes, controller paths, or link instability.

## Auto-discovery

You can either specify drives manually or have the runner discover them.

Discovery matching rules:

- `--devices` is explicit and bypasses auto-discovery entirely.
- Repeating `--model` means OR within the model/vendor category.
- Repeating `--size` means OR within the size category.
- If both `--model` and `--size` are present, a drive must match at least one model filter and at least one size filter.
- Model matching is substring-based against `MODEL` and `VENDOR` from `lsblk`.
- Size matching is substring-based against the `SIZE` column from `lsblk`.

Examples:

```bash
sudo drive-burnin-tmux --devices /dev/sdc,/dev/sdd
sudo drive-burnin-tmux --model ST4000 --dry-run
sudo drive-burnin-tmux --model HGST --model ST4000 --dry-run
sudo drive-burnin-tmux --size 3.6T --dry-run
sudo drive-burnin-tmux --model ST4000 --model HGST --size 3.6T --dry-run
sudo drive-burnin-tmux --model HGST --model ST4000 --size 3.6T --stress
```

Interpretation examples:

- `--devices /dev/sdc,/dev/sdd`
  Uses exactly those two devices.
- `--model ST4000`
  Matches any disk whose `MODEL` or `VENDOR` contains `ST4000`.
- `--model HGST --model ST4000`
  Matches disks containing either `HGST` or `ST4000`.
- `--size 3.6T`
  Matches disks whose `lsblk` size string contains `3.6T`.
- `--model ST4000 --model HGST --size 3.6T`
  Matches disks whose model/vendor contains either `ST4000` or `HGST`, and whose size string also contains `3.6T`.

Suggested operator workflow:

1. Use broad filters with `drive-burnin-preflight` to inventory the host and review what is present.
2. Run `sudo drive-burnin-tmux ... --dry-run` with the same filters to see the exact device set that would be touched.
3. For the destructive run, either reuse those reviewed filters or switch to explicit `--devices` for maximum determinism.

The `--dry-run` mode shows what would run without touching any disks.
For smoke testing, use `--step-timeout-max SEC` to stop any single step after a bounded interval.

## Quick start

### 1. Install the package

On the target Debian-family system:

```bash
sudo apt install ./raid-drive-validator_0.1.0-1_all.deb
```

### 2. Do a read-only preflight

Before any destructive run, inventory the host and confirm the target disks:

```bash
drive-burnin-preflight --model ST4000 --model HGST --size 3.6T
```

Review the newest bundle under `preflight_reports/` before proceeding.

### 3. Verify discovery without touching disks

```bash
sudo drive-burnin-tmux --model ST4000 --model HGST --size 3.6T --dry-run
```

If you already know the exact devices, prefer explicit device lists:

```bash
sudo drive-burnin-tmux --devices /dev/sdb,/dev/sdc --dry-run
```

### 4. Run a short smoke test

This validates workflow, tmux orchestration, reporting, and dashboard behavior without waiting for a full multi-day qualification:

```bash
sudo drive-burnin-tmux \
  --devices /dev/sdb,/dev/sdc \
  --step-timeout-max 10 \
  --stress
```

### 5. Run a full qualification

For a real burn-in, omit `--step-timeout-max`. You can use either explicit devices or previously-reviewed filters:

```bash
sudo drive-burnin-tmux \
  --devices /dev/sdb,/dev/sdc \
  --stress
```

```bash
sudo drive-burnin-tmux \
  --model ST4000 \
  --model HGST \
  --size 3.6T \
  --stress
```

### 6. Build the RAIDZ2 pool from stable by-id paths

After you have chosen the final pool members, generate the `zpool create` command
from the same model/size filters used during qualification:

```bash
drive-zpool-create-raidz2 \
  --pool-name backup \
  --model ST4000 \
  --model HGST \
  --size 3.6T \
  --drive-count 8 \
  --spare-count 1
```

By default this prints the exact `zpool create ... raidz2 /dev/disk/by-id/...`
command without running it. The script now defaults to the original backup-pool
layout: exactly `8` RAIDZ2 members plus `1` hot spare. If you want a different
layout, pass `--drive-count N` and `--spare-count N`. By default it prefers
device-name style by-id links such as `ata-*`; pass `--wwn` if you want it to
prefer `wwn-*` links instead.

To actually create the pool, review the printed command first and then rerun with
`--execute`:

```bash
sudo drive-zpool-create-raidz2 \
  --pool-name backup \
  --model ST4000 \
  --model HGST \
  --size 3.6T \
  --drive-count 8 \
  --spare-count 1 \
  --execute
```

### 7. Run a bounded pool stress test

After the pool exists, you can exercise it without committing to an all-day soak.
The helper below creates a temporary dataset inside the pool, runs sequential
write, timed random read/write, and sequential read `fio` phases, captures
`zpool status` and `zpool iostat`, and then destroys the temporary dataset
unless you pass `--keep-dataset`.

Preview the plan first:

```bash
drive-zpool-stress \
  --pool-name backup \
  --file-size 8G \
  --runtime-sec 300 \
  --jobs 4 \
  --seq-write-timeout-sec 1200 \
  --seq-read-timeout-sec 1200
```

Run it for real:

```bash
sudo drive-zpool-stress \
  --pool-name backup \
  --file-size 8G \
  --runtime-sec 300 \
  --jobs 4 \
  --seq-write-timeout-sec 1200 \
  --seq-read-timeout-sec 1200 \
  --execute
```

If you also want to kick a scrub and wait for a bounded period:

```bash
sudo drive-zpool-stress \
  --pool-name backup \
  --file-size 8G \
  --runtime-sec 300 \
  --jobs 4 \
  --seq-write-timeout-sec 1200 \
  --seq-read-timeout-sec 1200 \
  --scrub \
  --scrub-wait-sec 600 \
  --execute
```

For larger file sizes, raise the sequential timeouts explicitly. For example, a
much larger write/read pass might look like:

```bash
sudo drive-zpool-stress \
  --pool-name backup \
  --file-size 512G \
  --runtime-sec 600 \
  --jobs 4 \
  --seq-write-timeout-sec 7200 \
  --seq-read-timeout-sec 3600 \
  --scrub \
  --scrub-wait-sec 600 \
  --execute
```

On older 4 TB HDDs, a full run can take roughly 40+ hours per drive, dominated by `badblocks -wsv`.

## tmux runner and dashboard

The tmux runner creates one worker window per drive and, by default, also starts a dashboard window.

This avoids interleaved output while still allowing all drives to run in parallel.

During a run, each worker also polls SMART temperature in the background for the full lifecycle of the burn. Live current/min/max/average temperature values are shown in the dashboard and summary views, and each drive writes a timestamped temperature sample log into the report directory.

Each `drive-burnin-tmux` launch creates a unique timestamped run directory and passes that same directory to every worker, the dashboard, and the summary watcher. That keeps one tmux run internally correlated while preventing stale files from older runs from contaminating the current batch.

By default that looks like:

```text
drive_test_reports/YYYYMMDD-HHMMSS/
```

If you pass `--report-dir /some/path`, that path becomes the parent, and the tmux run still creates one timestamped subdirectory underneath it.

Typical use:

```bash
sudo drive-burnin-tmux --model ST4000 --model HGST --size 3.6T --stress
```

Attach to the session:

```bash
tmux attach -t drive-burnin
```

If you see `ERROR: tmux session 'drive-burnin' already exists`, that means a session with the default name is already present. Check existing sessions with:

```bash
tmux ls
```

If that session is the one you want, attach to it:

```bash
tmux attach -t drive-burnin
```

If it is stale and you want a fresh run, remove it:

```bash
tmux kill-session -t drive-burnin
```

If you want to keep the existing session and start another run, use a different name:

```bash
sudo drive-burnin-tmux --session drive-burnin-smoke --model HGST --model ST4000 --size 3.6T --stress --step-timeout-max 100
```

Detach without stopping the run:

```text
Ctrl-b d
```

Window layout:

- window `0`: dashboard
- window `1..N`: one worker per drive
- final window: batch summary watcher

The tmux session is expected to return immediately after launch. The tests continue in the background until workers complete.

## Stopping a run

To inspect an active batch:

```bash
tmux attach -t drive-burnin
```

To detach without stopping it:

```text
Ctrl-b d
```

To stop the entire batch immediately:

```bash
tmux kill-session -t drive-burnin
```

That kills the tmux session and the processes running inside it, including all per-drive workers, the dashboard, and the summary watcher. This is a hard stop, not a graceful shutdown, so any in-flight `badblocks`, `fio`, `dd`, or SMART self-test phase will be interrupted.

If you want to keep the old session and launch a new batch, use a different session name:

```bash
sudo drive-burnin-tmux --session drive-burnin-smoke --model HGST --model ST4000 --size 3.6T --stress --step-timeout-max 100
```

## Dashboard and summary behavior

The dashboard shows a live per-drive view:

- temperature, realloc, pending, CRC
- qualification status
- verdict and score when available
- current stage
- last update time
- current worker status message

The summary window shows:

- batch progress while workers are still running
- per-drive stage and markdown/JSON completion state
- final verdict totals after all drives complete
- the final batch markdown summary once generated

If the summary window reaches its final screen, all expected drive runs have finished.

## Reports

By default reports go into a timestamped run directory under:

```text
drive_test_reports/YYYYMMDD-HHMMSS/
```

Each tmux invocation writes all worker output, live state, markdown, summaries, and temperature samples into its own timestamped directory. That means one batch run maps to one run directory.

Per-drive outputs include:

- full text report
- latency JSON summary
- live state file for the dashboard
- compact JSON summary with score and verdict
- markdown report per drive under `drive_test_reports/YYYYMMDD-HHMMSS/markdown/drives/`

When the tmux runner is used, a summary watcher also emits:

```text
drive_test_reports/YYYYMMDD-HHMMSS/markdown/summary.md
```

If you want to remove generated output and start fresh:

```bash
make clean
```

If you want to remove all generated run output, preflight bundles, and the local build chroot:

```bash
make distclean
```

## Smoke-test semantics

`--step-timeout-max SEC` is for workflow validation, not for real drive qualification.

When one or more major stages time out:

- `qualification_status` becomes `incomplete`
- the result is forced to `REVIEW`
- the score is capped below `PASS`
- timed-out stages are listed in the raw report, JSON, and markdown outputs

This prevents short smoke runs from being mistaken for completed destructive qualification.

## Safety notes

This toolkit is **destructive**.

It overwrites target devices and must not be pointed at disks containing data you want to keep.

Always start with `--dry-run` if using discovery mode.

## Dependency installation

If you install the `.deb` with `apt`, the runtime dependencies should be pulled in automatically.

If you are running directly from a checkout instead of the package, install the runtime tools with:

```bash
sudo tools/install_dependencies.sh
```

## Configuration

The installed package ships `/etc/raid-drive-validator/burnin.conf`.

That file controls scoring and threshold settings used by the runtime scripts, including:

- `WARN_TEMP_C`
- `MAX_TEMP_C`
- `REVIEW_SCORE_MIN`
- `PASS_SCORE_MIN`
- `LATENCY_P99_WARN_MS`
- `LATENCY_MEAN_WARN_MS`

Edit it if you want to tune how conservative the qualification scoring is on a given host. If the file is absent, built-in defaults are used.

## Host preflight before touching `stein`

Before any destructive run on `stein`, collect a read-only inventory bundle:

```bash
bash tools/host_preflight.sh --model ST4000 --model HGST --size 3.6T
```

This writes a timestamped bundle under `preflight_reports/` with:

- OS and kernel details
- `lsblk`, `findmnt`, and `blkid` snapshots
- optional `smartctl --scan-open` output
- network and PCI inventory
- `zpool` / `zfs` snapshots when those tools are installed
- an optional burn-in `--dry-run` plan using the same model/size filters

Use that bundle to confirm exact device identities, mounted filesystems, and ZFS state before running any destructive command.

## Suggested `stein` workflow

Typical safe sequence for `stein`:

1. copy the built `.deb` to `stein`
2. run `sudo apt install ./raid-drive-validator_0.1.0-1_all.deb`
3. run `drive-burnin-preflight --model ... --size ...`
4. run `sudo drive-burnin-tmux --model ... --size ... --dry-run`
5. verify the exact matched devices in the dry-run output
6. run a short smoke test with `--step-timeout-max`
7. run the real qualification without `--step-timeout-max`, using either the reviewed filters or explicit `--devices`

## Debian packaging

The repository also contains Debian packaging metadata and helper scripts so the project can be built as a `.deb` package.

### Build on the host

```bash
dpkg-buildpackage -us -uc -b
```

### Build inside a debootstrapped Debian Trixie chroot

The supported packaged build path is:

```bash
make build
```

That entrypoint uses `tools/build_package.sh`, creates or refreshes a repo-local Trixie chroot under `.build/chroot/trixie-amd64`, copies the source tree into `/work` inside the chroot, provides only a private minimal `/dev` plus `/proc`, runs the package build there, copies resulting artifacts back to the host, and always tears down mounts on exit via a shell trap.

If you want to prepare the chroot without building yet:

```bash
sudo tools/build_package.sh --setup-only
```

If you want a different persistent chroot location:

```bash
sudo tools/build_package.sh --chroot-dir /some/other/path/trixie-amd64
```

The resulting package files are copied into the repository root. Docker is possible, but for Debian package builds this chroot path stays closer to native Debian tooling while avoiding direct bind-mount exposure of the host source tree or host `/dev`.

## Suggested workflow for the original use case

1. use `--dry-run` to discover the intended 4 TB HDDs
2. run the full destructive burn-in with `--stress`
3. review JSON/text reports and the reliability scores
4. choose 8 best disks for the RAIDZ2 pool
5. keep the 9th healthy disk as a hot spare
6. create the backup pool on `stein`
7. replicate from `newton` over 10 GbE with native ZFS send/receive

## Why shell scripts for now

This project stays in shell because the current iteration was already designed around shell-based Linux tooling and because that keeps the first packaged version easy to audit and easy to install on standard Debian systems.

The layout is intentionally modular so it can later be refactored into Python or a richer TUI without changing the overall workflow.
