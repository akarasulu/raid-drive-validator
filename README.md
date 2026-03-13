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
│   ├── setup_trixie_chroot.sh
│   └── build_trixie_package.sh
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

Examples:

```bash
sudo bin/drive_burnin_tmux.sh --devices /dev/sdc,/dev/sdd
sudo bin/drive_burnin_tmux.sh --model ST4000 --model HGST --size 3.6T --dry-run
sudo bin/drive_burnin_tmux.sh --model HGST --model ST4000 --size 3.6T --stress
```

Repeat `--model` and `--size` to provide multiple OR filters.

The `--dry-run` mode shows what would run without touching any disks.
For smoke testing, use `--step-timeout-max SEC` to stop any single step after a bounded interval.

## Quick start

### 1. Install dependencies

On Debian-family systems:

```bash
sudo tools/install_dependencies.sh
```

### 2. Do a read-only preflight

Before any destructive run, inventory the host and confirm the target disks:

```bash
bash tools/host_preflight.sh --model ST4000 --model HGST --size 3.6T
```

Review the newest bundle under `preflight_reports/` before proceeding.

### 3. Verify discovery without touching disks

```bash
sudo bin/drive_burnin_tmux.sh --model ST4000 --model HGST --size 3.6T --dry-run
```

If you already know the exact devices, prefer explicit device lists:

```bash
sudo bin/drive_burnin_tmux.sh --devices /dev/sdb,/dev/sdc --dry-run
```

### 4. Run a short smoke test

This validates workflow, tmux orchestration, reporting, and dashboard behavior without waiting for a full multi-day qualification:

```bash
sudo bin/drive_burnin_tmux.sh \
  --devices /dev/sdb,/dev/sdc \
  --step-timeout-max 10 \
  --stress
```

### 5. Run a full qualification

For a real burn-in, omit `--step-timeout-max`:

```bash
sudo bin/drive_burnin_tmux.sh \
  --devices /dev/sdb,/dev/sdc \
  --stress
```

On older 4 TB HDDs, a full run can take roughly 40+ hours per drive, dominated by `badblocks -wsv`.

## tmux runner and dashboard

The tmux runner creates one worker window per drive and, by default, also starts a dashboard window.

This avoids interleaved output while still allowing all drives to run in parallel.

Typical use:

```bash
sudo bin/drive_burnin_tmux.sh --model ST4000 --model HGST --size 3.6T --stress
```

Attach to the session:

```bash
tmux attach -t drive-burnin
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

By default reports go into:

```text
drive_test_reports/
```

Per-drive outputs include:

- full text report
- latency JSON summary
- live state file for the dashboard
- compact JSON summary with score and verdict
- markdown report per drive under `drive_test_reports/markdown/drives/`

When the tmux runner is used, a summary watcher also emits:

```text
drive_test_reports/markdown/summary.md
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

On a Debian-family host, install the runtime tools with:

```bash
sudo tools/install_dependencies.sh
```

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

1. sync the current repo to `stein`
2. run `sudo tools/install_dependencies.sh`
3. run `bash tools/host_preflight.sh ...`
4. run `--dry-run` discovery
5. run a short smoke test with `--step-timeout-max`
6. validate dashboard, per-drive markdown, and batch summary output
7. run the real qualification without `--step-timeout-max`

## Debian packaging

The repository also contains Debian packaging metadata and helper scripts so the project can be built as a `.deb` package.

### Build on the host

```bash
dpkg-buildpackage -us -uc -b
```

### Build inside a debootstrapped Debian Trixie chroot

First create the chroot:

```bash
sudo tools/setup_trixie_chroot.sh /srv/chroot/trixie-amd64
```

Then build inside it:

```bash
sudo tools/build_trixie_package.sh /srv/chroot/trixie-amd64
```

The resulting package is placed in the project root’s parent directory, following normal Debian package build behavior.

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
