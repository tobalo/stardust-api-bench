# Results

Every session behind the numbers in the top-level README, as the tools wrote them. Server IP addresses are
replaced with `SERVER_IP`, and the license status line is removed. Nothing else is edited.

[`latest.html`](latest.html) shows the headline measurements as tables and charts on one page, read from these files.

Setup for every session:
- Ubuntu 24.04 (kernel 6.8) in us-central (Dallas), tuned host profile, no swap;
- StardustDB embedded in the Rust io_uring server (`server/`), serving :80 directly;
- k6 2.3.0 on a dedicated Linode in the same region.

## What a session folder holds

| File | Written by | What it is |
|---|---|---|
| `<run>-<users>.log` | k6 | k6's own stdout for one run: the end-of-run summary, thresholds and every warning line, unedited |
| `<run>-<users>.json` | k6 `--summary-export` | Every k6 metric for the run: latency percentiles, request and error counts, rates |
| `<run>-<users>.html` | k6 web dashboard | k6's charts over time for one run. Kept on the machine that ran it, not committed (~180 KB each); the run's `.log` and `.json` hold its numbers |
| `summary.txt`, `runs.csv` | `bench/score.sh` | The run sequence and verdicts, read out of the k6 JSON with `jq` |
| `host.csv` | `deploy/host/sample-host.sh` | Server CPU (user, system, iowait, softirq, steal), memory, network, disk and TCP, every second; new sessions also include file allocation and process I/O counters, and from 2026-10-18 21:26 UTC unreclaimable kernel slab, orphaned sockets and IPv6 sockets |
| `storage-snapshots.csv` | `deploy/host/storage.sh` via `deploy/linode/bench.sh` | New sessions: seed/run file sizes and allocation before reset, at session start, and at session end; filesystem free space and process I/O counters |
| `app-stats.log` | the server | Every 5 s: requests by kind, read time, group-commit rounds and commit time, open connections |
| `server.txt` | `deploy/linode/bench.sh` | CPU model, kernel, memory, limits and sysctls of the server; the k6 version and client plan |
| `bench.log` | `deploy/linode/bench.sh` | The session's whole console output, as it ran (from 2026-10-17) |
| `deploy.log` | `deploy/linode/up.sh` | The deploy before the session: provisioning, the build, all 42 API checks, tuning (from 2026-10-17) |
| `dmesg-*.txt` | the server's kernel log | Saved after a step that failed or ended the server: the OOM killer's lines and socket counters |
| `*.log.gz` | k6 | A k6 log over 5 MB (k6 logs every failed request), kept whole and gzipped |
| `report.html` | `bench/report.py` | All of the above as charts in one self-contained page |

The run names in each folder follow the challenge's scoring procedure:
- `warmup`: 1,000 users for 2 minutes, not scored;
- `search`: 2-minute runs that bracket the limit;
- `confirm`: the 5-minute holds;
- `single`: one-off runs;
- `conns`: connection-capacity steps;
- `redline`: runs past the score.

k6 computes a run's req/s over the whole run, ramps included.

The [2026-10-17 storage observation](20261017-storage-observation/README.md) is a separate measurement of the
live files and seed inputs, not a scored session. Older sessions have no storage baseline. New reports show
apparent and allocated file sizes separately from process writes, and label per-run changes as sampled.
`seed/seed-metrics.json`, produced on the machine that builds a new seed, records input bytes/rows/hashes,
import peak RSS and time, and the completed file's size/allocation/hash. It does not retroactively identify
the seed used by old sessions; new `server.txt` files include the deployed compressed-seed hash.

## Scores

The challenge score: the most users that hold a 5-minute run at p95 < 500 ms, p99 < 1 s and < 1% errors, with
`load.js` unmodified. Every box was scored on fresh hardware with the same server, seed and procedure.

| Date (UTC) | Server | Score | The 5-minute hold (k6's own output) | Session |
|---|---|---:|---|---|
| 2026-10-16 | Nanode 1 GB (`g6-nanode-1`, 1 shared vCPU) | 7,250 | p95 59.66 ms · p99 551.1 ms · 0 of 270,027 failed · 675 req/s ([log](20261016T193737Z-g6-nanode-1-tuned/confirm-7250.log)) | [`…193737Z`](20261016T193737Z-g6-nanode-1-tuned/) |
| 2026-10-17 | Nanode 1 GB | **8,500** | p95 257.01 ms · p99 848.11 ms · 0 of 316,181 failed · 790 req/s ([log](20261017T120045Z-g6-nanode-1-tuned-redline/confirm-8500.log)) | [`…120045Z`](20261017T120045Z-g6-nanode-1-tuned-redline/) |
| 2026-10-16 | Linode 2 GB (`g6-standard-1`, 1 shared vCPU) | **12,750** | p95 200.04 ms · p99 338.85 ms · 0 of 473,295 failed · 1,183 req/s ([log](20261016T215520Z-g6-standard-1-tuned-redline/confirm-12750.log)) | [`…215520Z`](20261016T215520Z-g6-standard-1-tuned-redline/) |
| 2026-10-17 | Linode 2 GB | 10,500 | p95 302.97 ms · p99 887.72 ms · 0 of 390,607 failed · 976 req/s ([log](20261017T142505Z-g6-standard-1-tuned-redline/confirm-10500.log)) | [`…142505Z`](20261017T142505Z-g6-standard-1-tuned-redline/) |

The same plan scored differently on different days: 7,250 and 8,500 on the Nanode, 12,750 and 10,500 on the 2 GB. These are shared vCPUs,
and the box each deploy lands on varies. Near the limit, runs also vary by about one 250-user step: the 2026-10-17
Nanode passed 8,500 but failed 8,750 (p95 921 ms); the 2 GB passed 10,750 in its search but failed its 5-minute
confirm (p99 1,069 ms), then held 10,500.

## Redline: past the score

`make redline` keeps adding users after the score, 2 minutes per step, until errors pass 50% or `/health` stops
answering. k6's req/s counts every request it sent, including the ones that timed out at 60 s.

| Users | Nanode 1 GB, 2026-10-17 | Linode 2 GB, 2026-10-17 |
|---:|---|---|
| 10,000 | 820 req/s · p95 1.08 s · 0 errors | 828 req/s · p95 62.71 ms · 0 errors (passes) |
| 15,000 | 949 req/s · p95 14.59 s · 0.56% errors | 1,060 req/s · p95 2.29 s · 0 errors |
| 20,000 | 1,049 req/s · p95 15.81 s · 1.55% errors | 1,118 req/s · p95 14.65 s · 0.04% errors |
| 30,000 | **1,136 req/s** · p95 at the 60 s timeout · 9.50% errors | **1,232 req/s** · p95 at the 60 s timeout · 8.15% errors |

Neither server crashed: `server.txt` records `service_NRestarts=0` for both. After the 30,000-user run, `/health` did
not answer within 10 s because it waited behind the queued requests, so the ladder stopped there. Past about
1,000–1,200 req/s the single vCPU is full: extra users wait longer, and requests time out rather than fail.

## Connection capacity

`make connections` (`bench/connections.js`) measures how many keep-alive connections the server holds at once. It
does not measure how many challenge users the server serves:
- one k6 client opens ~64,500 connections per server address, so the test uses ten: the server's IPv4 and IPv6,
  and eight addresses of an IPv6 /64 routed to it (`deploy/linode/main.tf`);
- each VU holds one connection to each address and asks `GET /health` (a StardustDB read) on each about every
  connections / 1,000 seconds, so the server sees a steady ~1,000 req/s at every step, ramp included;
- a step is the same 5-minute hold with the same limits as the score; the ladder stops at the first step that misses
  them.

| Server | Held (5-minute hold) | At the highest held | Next step | Session |
|---|---:|---|---|---|
| Nanode 1 GB | **150,000** | p95 1.48 ms · p99 4.69 ms · 0 of 471,800 failed ([log](20261017T125625Z-g6-nanode-1-tuned-connections/conns-150000.log)) | 175,000: the kernel OOM-killed the server ([`dmesg-oom.txt`](20261017T125625Z-g6-nanode-1-tuned-connections/dmesg-oom.txt)) | [`…125625Z`](20261017T125625Z-g6-nanode-1-tuned-connections/) |
| Linode 2 GB | **375,000** | p95 14.09 ms · p99 114.4 ms · 0 of 704,370 failed ([log](20261018T221151Z-g6-standard-1-tuned-connections/conns-375000.log)) | 400,000: reached 394,043, the page cache ran out, and the kernel OOM-killed the server ([`dmesg-end.txt`](20261018T222802Z-g6-standard-1-tuned-connections/dmesg-end.txt)) | [`…221151Z`](20261018T221151Z-g6-standard-1-tuned-connections/) |

Every Nanode step held: 70,000, 100,000, 125,000 and 150,000, each with 0 errors. Each connection cost ~3.4 KB of
kernel memory: available memory went from 677 MB to 177 MB at 150,000, and the page cache was down to 40 MB. At
175,000 it ran out. The first errors at 13:31:02 were timeouts and resets. The kernel killed `stardust-uring` at
13:31:26, and the remaining ~287,000 errors were "connection refused".

**Linode 2 GB, one step per fresh boot.** Each step ran on a freshly rebooted server, because a second ramp in the
same session is not a fair measure (see below):

| Connections | Result (k6's own output) | Kernel slab · available · page cache at the peak | Session |
|---:|---|---|---|
| 300,000 | PASS · p95 2.76 ms · p99 10.49 ms · 0 of 627,040 failed | 1,047 MB · 628 MB · 308 MB | [`…212604Z`](20261018T212604Z-g6-standard-1-tuned-connections/) |
| 325,000 | PASS · p95 2.87 ms · p99 10.84 ms · 0 of 652,590 failed | 1,127 MB · 551 MB · 244 MB | [`…214051Z`](20261018T214051Z-g6-standard-1-tuned-connections/) |
| 350,000 | PASS · p95 3.22 ms · p99 11.37 ms · 0 of 678,580 failed | 1,210 MB · 427 MB · 86 MB | [`…215609Z`](20261018T215609Z-g6-standard-1-tuned-connections/) |
| 375,000 | PASS · p95 14.09 ms · p99 114.4 ms · 0 of 704,370 failed | 1,297 MB · 407 MB · 53 MB | [`…221151Z`](20261018T221151Z-g6-standard-1-tuned-connections/) |
| 400,000 | FAIL · p95 19.56 ms · p99 27.28 s · 279,097 of 720,550 failed (38.73%) ([log](20261018T222802Z-g6-standard-1-tuned-connections/conns-400000.log.gz)) | 1,345 MB · 360 MB · 1 MB at 394,043 connections | [`…222802Z`](20261018T222802Z-g6-standard-1-tuned-connections/) |

At 400,000 the step reached **394,043** connections at 22:35:18 UTC. With the page cache at 1 MB, StardustDB re-read its pages from disk at up to 212 MB/s. The kernel ran out of memory at 22:36:36 and killed `stardust-uring` at 22:36:39. Almost all of the errors came after that: about 275,000 "connection refused".

The raw log of each step is `conns-<n>.log` in its session.

What a connection costs, measured from the new sampler columns at 300,000 connections on a fresh kernel:
- **Kernel slab:** each connection takes **3.41 KB**; slab went from 47 MB to 1,047 MB, and available memory fell by
  the same amount;
- **The server process:** RSS stayed at 50 MB; the connections live in one io_uring ring of 524,280 registered
  descriptors;
- **CPU:** ~34% busy during the 325,000 hold, at ~1,000 StardustDB reads/s;
- **Release:** after the step, the sockets closed cleanly, with 0 orphans, and slab returned to 126 MB.

As the slab grows it squeezes out the page cache that holds the database's pages. At 375,000 the cache was down to
53 MB, the database started reading from disk again (up to 565 KB/s), and p99 rose from ~11 ms to 114 ms.

**A second ramp in the same session fails early.** Two sessions show this:
- **2026-10-17** ([`…134424Z`](20261017T134424Z-g6-standard-1-tuned-connections/)): 125,000, 200,000 and 250,000 held.
  The 300,000 step was OOM-killed at ~160,000 connections.
- **2026-10-18** ([`…205225Z`](20261018T205225Z-g6-standard-1-tuned-connections/)): 275,000 held (p95 8.72 ms,
  p99 39.71 ms, 0 of 600,840 failed). The 300,000 step was OOM-killed at ~142,000.

In both, available memory did not recover when the previous step's connections closed. In the 2026-10-18 session,
~880 MB stayed taken with only ~24,000 connections open, and ~22,500 connections the client had already closed
stayed open on the server through the 120 s pause between steps. The cause was not isolated. The fresh-boot steps
above do not have this problem.

**2026-10-16, the first method** ([`…224612Z`](20261016T224612Z-g6-standard-1-tuned-connections/)): two server
addresses and 500 req/s. 70,000, 100,000 and 125,000 held. There the limit was the client: ~129,000 ports to two
addresses, and k6 used 19.9 GB of RAM at one connection per VU.

## Incidents, logged as they happened

- **2026-10-17, Linode 2 GB redline:** the first attempt died before it started a session: SSH to the fresh server
  timed out during the banner exchange. `bench.sh` now retries its first SSH.
- **2026-10-17, session [`…142505Z`](20261017T142505Z-g6-standard-1-tuned-redline/):** the repository was edited while the run was in progress. The running `bench.sh`
  read the changed file, started a second, unintended scoring run, then stopped on a syntax error. That second run
  overwrote `warmup-1000.*` and `search-2500.*`. Its two rows are the last two in `runs.csv`. The first run's
  values for those two steps are rows 1–2 of `runs.csv` and the top of `summary.txt` and `bench.log`: warm-up p95
  25.95 ms, 2,500 users p95 27.13 ms. Every other file in the session is from the scored run.
- **2026-10-18, session [`…203555Z-…-aborted`](20261018T203555Z-g6-standard-1-tuned-connections-aborted/):** one SSH
  poll to the busy client timed out at ~249,000 connections, and `bench.sh` took that to mean k6 had finished. It
  collected and exited, and the next step tore everything down. k6 wrote no output; the server's `app-stats.log` and
  `host.csv` show it healthy at 248,953 connections. Fixed in `deploy/linode/bench.sh`:
  - one persistent SSH connection per host for the session;
  - an SSH failure is never read as "finished";
  - copies from the client retry.

**PR #19 (SQLite), for comparison.** Its own published numbers come from one core of a Xeon E5-2690 v3, with k6 over
loopback on the same host:
- 68,750 users, stopped by its 65,535 descriptors;
- with that limit lifted, 189,500 users, and 80,000 connections in a separate check.

Its requests cost far less CPU (27,000–40,000 feed req/s on one core). So once connections were no longer the limit,
its user score kept growing. StardustDB's per-query floor holds this server near 1,000–1,200 req/s per vCPU.

## Nanode 1 GB vs Linode 2 GB

Both boxes report the same CPU, an AMD EPYC 7713 with 1 vCPU, and near-zero steal. Yet on 2026-10-16 the same load
cost the Nanode 27–34% more CPU at 2,500–5,000 users, and its average read took 38–59% longer. These are averages
over each run's steady part, from `host.csv` and `app-stats.log`:

| Users | Nanode: CPU busy | Nanode: read time | Nanode: p95 | Linode 2 GB: CPU busy | Linode 2 GB: read time | Linode 2 GB: p95 |
|---:|---:|---:|---:|---:|---:|---:|
| 2,500 | 45% | 1.25 ms | 30 ms | 34% | 0.79 ms | 26 ms |
| 5,000 | 71% | 1.10 ms | 46 ms | 56% | 0.76 ms | 28 ms |
| 10,000 | 98% (saturated) | 1.01 ms | **2,187 ms (fail)** | 86% | 0.73 ms | 43 ms (pass) |

Steal was 0.3–1.3% on the Nanode and 0% on the 2 GB, so the hypervisor did not take the difference. Two things
differ, and neither was isolated:
- **Page cache:** the Nanode had ~560 MB for the database file against ~1.5 GB on the 2 GB, and it read 50–70 KB/s
  from disk where the 2 GB read none.
- **Neighbors:** the Nanode shares its host's caches and memory bandwidth with other tenants, and that does not show
  as steal.

For connections, memory is the whole difference: both pay ~3.4 KB of kernel memory per connection. The Nanode
starts with ~680 MB available and the 2 GB with ~1,650 MB.

## How the Nanode score got there

| Server version | Result | Session |
|---|---|---|
| First deploy: 41 queries per feed | Not scored: a single 1,000-user run failed with p95 21.8 s at 52 req/s, and half of the CPU was kernel time (49.6% system in `host.csv`) | [`…161257Z-g6-nanode-1-tuned-1000`](20261016T161257Z-g6-nanode-1-tuned-1000/) |
| Layout 2: allocator setting, 2-query feed, `in_feed` marker | No score: read time grew from 1.33 ms to 2.69 ms as the session went on, so confirms from 5,000 down to 4,500 failed and the session was stopped. The marker's retractions accumulated. | [`…170245Z-g6-nanode-1-tuned`](20261016T170245Z-g6-nanode-1-tuned/) |
| Layout 3: 20 feed slots instead of the marker | **4,250** | [`…181113Z-g6-nanode-1-tuned`](20261016T181113Z-g6-nanode-1-tuned/) |
| Layout 4: 1 query per feed and per post | **4,750** | [`…184328Z-g6-nanode-1-tuned`](20261016T184328Z-g6-nanode-1-tuned/) |
| + 15 ms group-commit window, writer at nice 5 | **7,250** | [`…193737Z-g6-nanode-1-tuned`](20261016T193737Z-g6-nanode-1-tuned/) |
| + at most 20 new posts per write round (the StardustDB reference audit in `DESIGN.md`), on a different Nanode, 2026-10-17 | **8,500** | [`…120045Z-g6-nanode-1-tuned-redline`](20261017T120045Z-g6-nanode-1-tuned-redline/) |
