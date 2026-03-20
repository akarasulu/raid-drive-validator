# Backup Pool Qualification Summary

Date: 2026-03-20
Host: `stein`
Target pool: `backup`
Role: backup RAIDZ2 pool for an operational RAIDZ1 source

## Executive Summary

The drive burn-in toolkit's built-in heuristic marked all 9 candidate 4 TB HDDs as `FAIL`, but that heuristic is too strict for the actual target role. It heavily penalized random-read latency on old HDDs, which is a poor proxy for suitability as a bulk backup pool.

For the real use case, the stronger evidence is:

- all 9 candidate disks completed destructive qualification without reallocated, pending, or offline-uncorrectable sectors
- the final deployed `backup` pool stayed `ONLINE`
- a full large-file pool stress run completed
- the pool remained free of read, write, and checksum errors
- a scrub progressed cleanly with `0B repaired` and `0 errors`
- sustained sequential throughput was consistent with an 8-wide RAIDZ2 of older HDDs

Conclusion: the selected 8+1 set is acceptable for backup duty, with the caveat that several drives showed historical CRC/bus errors during burn-in and should be monitored as path-level risk rather than treated as proven media failure.

## Selection Heuristic For This Pool

The source workload is an operational RAIDZ1. The target pool is a backup pool. For that purpose, drive acceptance should be weighted in this order:

1. no media failure indicators:
   `Reallocated_Sector_Ct=0`, `Current_Pending_Sector=0`, `Offline_Uncorrectable=0`
2. no pool-level integrity faults under load:
   clean `zpool status`, no checksum errors, no scrub repairs
3. acceptable sustained sequential write and read throughput
4. acceptable temperatures under long-running load
5. CRC errors treated as connection-path or cabling risk unless they continue increasing
6. random IOPS and random latency treated as secondary, because this pool is not intended for VM or database workloads

This weighting differs from the stock burn-in score, which is intentionally conservative and random-latency-heavy.

## Burn-In Results

Batch artifact reviewed: `drive_test_report.tgz`

Observed across all 9 candidates:

- 0 reallocated sectors
- 0 pending sectors
- 0 offline uncorrectable sectors
- all drives completed qualification

Observed concerns:

- all drives were marked `FAIL` by the built-in score because mean and p99 random-read latency were high for HDDs
- three drives showed CRC/bus-path concerns during qualification:
  - `sdc` / `Z300FGDQ`: CRC = 1
  - `sdf` / `Z300FT4Q`: CRC = 109
  - `sdh` / `Z300BZHX`: CRC = 1

Interpretation:

- the media itself does not show classic failing-disk signatures
- the toolkit's FAIL verdicts should not be used literally for this backup-pool decision
- the real residual concern is transport-path quality on the CRC-flagged members, especially `sdf`

## Deployed Pool Layout

Current pool members observed in `zpool status`:

- `ata-ST4000DM000-1F2168_Z300APEH`
- `ata-ST4000DM000-1F2168_Z300FGDQ`
- `ata-HGST_HDN724040ALE640_PK2338P4GTPL2C`
- `ata-ST4000DM000-1F2168_Z300DGKH`
- `ata-ST4000DM000-1F2168_Z300FT4Q`
- `ata-ST4000DM000-1F2168_Z304RNDJ`
- `ata-ST4000DM000-1F2168_Z300BZHX`
- `ata-HGST_HDN724040ALE640_PK2334PCJBLVEB`

Hot spare:

- `ata-HGST_HDN724040ALE640_PK2338P4GTPE5C`

Notable point: the deployed pool includes the CRC-flagged drives `Z300FGDQ`, `Z300FT4Q`, and `Z300BZHX`. That does not invalidate the pool, but it means monitoring should focus on whether CRC counts continue to rise.

## Pool Stress Results

Final large-file artifact reviewed: `zpool_stress_reports.tgz`

Run parameters:

- file size: `512G`
- random phase runtime: `600s`
- jobs: `4`
- sequential write timeout: `7200s`
- sequential read timeout: `3600s`

Results:

- sequential write: about `352.67 MiB/s`
- sequential read: about `580.36 MiB/s`
- timed random mixed workload:
  - reads: about `19.85 MiB/s`, `158.83 IOPS`
  - writes: about `8.60 MiB/s`, `68.77 IOPS`
  - read p99 latency: about `1166 ms`
  - write p99 latency: about `1183 ms`

Interpretation:

- the large-file sequential numbers are the meaningful ones for this pool
- they are credible for an 8-disk RAIDZ2 built from older 4 TB HDDs
- the random numbers are slow, but that is expected and acceptable for a backup pool
- this pool should be treated as bulk-capacity backup storage, not latency-sensitive storage

## Pool Health Outcome

Before the stress run:

- pool `ONLINE`
- all members `ONLINE`
- spare `AVAIL`
- no known data errors

After the stress run:

- pool still `ONLINE`
- no member-level read, write, or checksum errors
- scrub still in progress at capture time but already >94% complete
- scrub had `0B repaired` and `0 errors`
- no known data errors

Operational conclusion:

- the pool passed the meaningful backup-duty tests
- the selected members are acceptable for deployment as a backup target
- the observed limitations are performance-shape limitations, not integrity failures

## Residual Risks And Follow-Up

1. Monitor SMART `UDMA_CRC_Error_Count` for `Z300FGDQ`, `Z300FT4Q`, and `Z300BZHX`.
   If the value increases, treat that as a cable, backplane, HBA, or path problem first.

2. Keep an eye on the hotter HGST drives.
   The HGST units peaked around `45-46 C` during burn-in, which is not immediately alarming, but they are warmer than the cooler Seagates.

3. Do not use this pool for latency-sensitive random IO.
   The large-file backup role is fine. VM, database, or sync-heavy workloads are not the intended fit.

4. Prefer periodic scrub and SMART review after the pool enters service.
   The large-file stress run was clean, but long-term backup duty still depends on path stability and ongoing monitoring.

## Final Decision

Decision: accept the current `backup` RAIDZ2 pool for backup duty.

Rationale:

- no media-defect indicators from burn-in
- no pool integrity errors under full large-file stress
- clean scrub behavior
- acceptable sustained sequential throughput for replication and backup
- random-latency failures in the burn-in score are not disqualifying for this pool role

This is a reasonable backup target for an operational RAIDZ1 source, provided CRC/bus counters are monitored and the pool is kept in a bulk-backup role.
