# Design

How the server works, and how it lays the data out in StardustDB, with the measurements behind each choice.
Results are in [`bench/results/`](bench/results/README.md).

## Server architecture

`server/` is one Rust process: a raw io_uring HTTP/1.1 server with StardustDB embedded (statically linked). There is
no async runtime, HTTP framework or ORM. On a 1-vCPU box it runs one ring thread, one writer thread and a stats
thread.

```
             k6 (one keep-alive connection per virtual user)
                                  │
        ┌─────────────────────────▼──────────────────────────────┐
        │ ring thread (uring.rs)                                 │
        │  multishot accept ─► registered (direct) descriptor    │
        │  multishot recv into provided buffers                  │
        │  parse HTTP (httparse) ─► route ─► verify JWT (HS256)  │
        │     │                                   │              │
        │   read: Db::read ── 1 StardustDB query  write: queue ──┼──► writer thread (writer.rs)
        │     │  (db.rs)                          │  WAITING     │      take everything queued
        │     ▼                                   │              │      check (1–2 queries each)
        │   response ─► send                      ◄──eventfd─────┼───── one merge_patch (durable)
        └────────────────────────────────────────────────────────┘      reply per request
```

### Network: io_uring

The network layer is the design of PR #19 of the
[$12 server challenge](https://github.com/arjaythedev/twelve-dollar-server-challenge/pull/19) (MIT; the
license is at the top of `server/src/uring.rs`).

- **Rings:** each ring is set up with `COOP_TASKRUN`, `SINGLE_ISSUER` and `DEFER_TASKRUN`, an 8,192-entry completion
  queue and a 1,024-entry submission queue. One thread issues on each ring.
- **Descriptors:** multishot accept places sockets straight into a sparse registered file table, so they never use
  the process's fd table. The server sizes its rings from the descriptor hard limit. `LimitNOFILE=65535` gives 8 rings
  of 65,535 slots; the tuned profile's 1,048,576 gives 1 ring of 524,280.
- **Receive:** multishot recv reads into a provided buffer ring (1,024 × 2 KiB per ring). Idle keep-alive connections
  hold no receive buffer, and bytes are parsed in place.
- **Batching:** one `io_uring_enter` submits and waits for up to 32 completions or 250 µs under load, then the loop
  processes the whole batch.
- **Connections:** each connection record is 64 bytes. Send buffers come from a pool and stay pinned while the kernel
  holds them. Backpressure pauses reads when output backs up.

Changes for StardustDB:

- **Writes leave the ring.** A durable StardustDB commit takes milliseconds of wall time but microseconds of CPU, so
  committing on the ring thread would stall every connection on it. A request that writes is queued to the writer, and
  its connection enters `WAITING`. Further input is buffered, not parsed, so replies stay in request order. The writer
  answers through the ring's inbox, and an always-armed eventfd read wakes the ring.
- **Listen backlog** is 65,535; the kernel caps it at `net.core.somaxconn`.
- **IPv4 and IPv6 on one socket:** the deploy sets `HOST=::`. With Linux's default `bindv6only=0`, IPv4 clients
  arrive on the same socket. With an IPv6 /64 routed to the server, the connection test reaches ten server addresses,
  ~64,500 connections each from one k6 client. The Linode 2 GB held 375,000 connections at ~50 MB RSS; the kernel's
  ~3.4 KB per connection is the limit ([`bench/results/`](bench/results/README.md)).

`--portable` (and every non-Linux build) uses a plain thread-per-connection server instead, for development on macOS.

### Reads (`db.rs`)

Every StardustDB query has a fixed cost: it zeroes a 4 MiB scratch arena, about 0.4 ms on a Nanode. So each read is
**one query**:

- `GET /feed`: the 20 feed slots → their posts' fields, authors and like counts, grouped.
- `GET /posts/:id`: the post's fields, author and like count.

Like counts are computed live in that query. Each post links to itself, so a post with no likes still has a row.
Queries are opened once as inline definitions and reused, with an explicit 5 s CPU budget, because the engine's
dynamic budget refuses the first queries on a cold file. [The data model](#stardustdb-data-model-and-measurements) has the layout and the
measurements behind it.

### Writes (`writer.rs`)

One writer thread is the only writer in the process, and StardustDB holds an exclusive lock on the file for the
process. Each round:

1. waits for the first write, keeps collecting for a **15 ms window**, then takes everything queued, up to 20 new
   posts (writes that arrive during a sync, and any 21st post, join the next round);
2. checks each write: a repeat like is 1 query; a new like is 2 (already liked? + post and user exist); a new post's
   user is 1 query;
3. builds one `merge_patch`: new likes, new posts (each linking to itself) and, if posts were created, the feed slots
   moved onto them;
4. commits it (durable on return), then replies to every request in the round. If the round fails, every request in
   it gets a 500.

Because the writer is the only one, a round's checks cannot interleave with another write. Likes within one round
are deduplicated in memory before the patch is built.

A round's new posts all carry the round's `created_at`, the newest in the database. With at most 20 of them, every one
belongs in the feed, so choosing the slots needs no entity ids. StardustDB returns the ids in `commit.ids` and
promises no order among them. Reads order the feed by `(created_at, id)` using the real ids.

The writer runs at **nice 5**. On one vCPU it competes with the ring thread for the CPU, and each StardustDB commit
rewrites the index pages it touches (about 480 KB per commit on the bench). An off-CPU profile at 4,750 users showed
the ring thread being preempted by the writer, not blocked on I/O. Every endpoint then shared the same tail (p99 about
660 ms). The window roughly halves the number of commits (batch 1.1 → 1.8 writes), and the priority lets request
serving win when both threads are runnable:

| 4,750 users, Nanode 1 GB | p99 (all) | max | commits/s | writes p50 |
|---|---:|---:|---:|---:|
| commit per write | 661 ms | 1,163 ms | ~35 | 24 ms |
| 15 ms window + nice 5 | **142 ms** | 506 ms | 19 | 38 ms |
| 40 ms window + nice 5 | 160 ms | 494 ms | 13 | 59 ms |

`--write-window-ms` overrides the window.

### Observability (`stats.rs`)

Relaxed atomic counters, printed every 5 s as one `stats` line on stderr (journald under systemd):

- requests by kind;
- read service time (average and max);
- group-commit rounds, writes per round, and commit time (average and max);
- open connections.

`bench/report.py` charts these lines next to the host sampler's one-second CPU, memory, network and disk data.

### Process settings

- **Static linking:** StardustDB is linked from its static archive, so the binary is the only file a server needs,
  plus the seed and the license.
- **License:** activated once at start from `$STARDUST_LICENSE`, `$STARDUST_LICENSE_FILE` or
  `~/.config/stardustdb/stardust.license`. `--license-check` reports the tier and expiry, never the token.
- **Allocator:** `GLIBC_TUNABLES=glibc.malloc.mmap_threshold=67108864:glibc.malloc.trim_threshold=1073741824`, set in
  the systemd unit. It keeps the per-query 4 MiB arenas in the heap instead of `mmap`/`munmap` on every query, which
  took kernel time on a Nanode from 45% of the CPU to 2%.

## StardustDB data model and measurements

How the API's data (users, posts and likes) is modeled in StardustDB, and the measurements behind each choice. Engine
timings come from an Apple M5 Max (macOS) against the full seed: 50,000 users, 500,000 posts and 2,016,005 likes. The
server profiles come from the benchmark target, a Linode Nanode (1 shared vCPU, 1 GB). The ratios are what matter.

### Entities (layout `stardust-api-bench/4`)

| Entity | Fields |
|---|---|
| post | `body`, `created_at` (UTC text with millisecond precision, as the API returns it), `author {#link user}`, `post {#link itself}` |
| user | `username`, `created_at` |
| like | `user {#link user}`, `post {#link post}`, `created_at` |
| feed slot (20) | `feed_slot` (0–19), `feed_post {#link post}`: the 20 newest posts |
| meta (one) | `layout`, `user_base` |

**A post's API id is its entity id.** Stardust numbers new entities in patch order from 1, and the transaction entity
takes the next id after them. The importer writes all 500,000 posts first, in one transaction, so they receive ids
1..500,000. It then checks every id and fails if any differs. Users follow, so user N is entity `user_base + N`
(500,000 + N). Posts created later receive the next free entity id. Those ids are larger than any seeded id but not
consecutive, because likes and transactions take ids too. The API only promises an integer id, and the tests read it
from the response.

**The feed is 20 slots, not a sort.** The feed is the 20 newest posts by `(created_at, id)`. Sorting 500,000 posts on
every request would cost 50–140 ms. Instead, 20 fixed slot entities link to those posts, and the feed query starts
from `[?s feed_slot ?i]`, which has only 20 entities. When posts are created, the writer moves the slots of
pushed-out posts onto the new ones, in the same transaction. A slot's link is overwritten, never retracted. An
earlier layout marked posts with `in_feed true` and retracted the marker as they aged out, and the retractions
accumulated: after 20,000 feed changes, the marker lookup was 8.5× slower (0.13 → 1.13 ms), while slots stayed flat
(0.19 → 0.16 ms).

**`like_count` is counted live, in the same query.** Every read counts the `post` links to the post. Each post also
links to itself through `post`, so the grouped count always returns a row for it, even with no likes, like a left
join. `like_count` is that count minus one. Likes are never stored as a counter, and the server keeps nothing
between requests.

| Request | Stardust queries |
|---|---|
| `GET /feed` | 1: the 20 slot posts with fields, author and like counts |
| `GET /posts/:id` | 1: fields, author and like count |
| `POST /posts/:id/like` | 1 for a repeat like (already liked); 2 for a new like (already liked? + post and user exist) |
| `POST /posts` | 1 (user exists), plus 1 per commit round (the slots) |

### Why so few queries: the fixed cost of a query

Profiling the server on the Nanode under load found most of the CPU outside our code:

| Version (Nanode, 500 users) | Server CPU | Read time (avg) | Where the CPU went |
|---|---:|---:|---|
| First deploy: 41 queries per feed | 85% (saturated) | 18.3 ms | 45% kernel: page faults and page zeroing under `free()` |
| + glibc heap reuse (`GLIBC_TUNABLES`) | 43% | 7.9 ms | 52% `memset` |
| + 2-query feed, 1–2-query post (layout 2) | **12%** | **1.4 ms** | `memset` is 29% of what is left |

Every query reserves a fixed **4 MiB scratch arena** and zeroes all of it, though a query uses tens of KB. Explain
reports `arena_capacity` 4,194,304 bytes and peak use about 19 KB, and `page_size` does not change it. On a Nanode,
that zeroing costs about 0.4–0.5 ms per query, so the number of queries per request sets the throughput.

- **Allocator:** glibc serves 4 MiB blocks with `mmap` and returns them on `free`, so each query faulted in fresh
  pages. The systemd unit keeps them in the heap instead
  (`GLIBC_TUNABLES=glibc.malloc.mmap_threshold=67108864:glibc.malloc.trim_threshold=1073741824`): kernel time went
  from 45% to 2%. Forcing a fresh `mmap` for every arena (threshold 1 MB) was worse: 24% CPU and 4.1 ms reads.
- **Queries:** the feed went from 41 queries (a 20-hop chain plus fields and a count per post) to 2, then to 1 with
  the self-link. A post went from 2 queries to 1.

### Engine measurements (M5 Max)

| Query | Time | Notes |
|---|---:|---|
| Feed: 20 slot posts with fields, author and like counts | 374 µs | one grouped query (two separate queries: 355 µs) |
| One post's fields + author + like count | 82–94 µs | grouped; the self-link guarantees a row |
| Post fields + author by entity id | 59 µs | a missing id or a non-post entity gives no row (the 404) |
| Already liked? (`post` + `user` links) | 54–58 µs hit, 167 µs miss | |
| Lookup by an integer field value (`[?e n ?n]`) | 42 ms | a scan: plain numbers have no value index |
| `orderBy [[?at desc]] limit 20` over 100k posts | 50–140 ms | sorts every match |
| A list-valued field used as a join (`[?m recent ?p]`, `[in ?p ?list]`) | 0 rows / scans | a list is one value, not one fact per element |
| Durable `merge_patch`, 1 like | 8.2 ms wall, 9 µs CPU | the sync dominates (macOS APFS); 11–19 ms on a Nanode |
| Durable `merge_patch`, 64 likes | 12.8 ms wall | a group commit costs about the same as one write |

Explain splits a small read into about 18 µs to load the definition, 2 µs for parameters, 2–5 µs to compile, 1–2 µs
to plan and 10–30 µs to run. Stored definitions (`patch_definition` + `query("path")`) were slower to load (45 µs),
so the server opens inline definitions once and reuses the handles. The dynamic CPU budget (`max_cost` 0) refuses
the first queries on a freshly copied, cold file, so the server sets an explicit 5 s budget.

### Size

The seed database is 3.4 GB on disk (4 GiB mapped) and compresses to 197 MiB with zstd for upload. The import takes
about 80 s and peaks at 7.4 GB RSS. Its first transaction holds every post and user, because their ids must come out in
order, so it runs on a large machine rather than the server. The file is portable across OS and architecture: a seed
built on macOS serves unchanged on Linux x86_64 and arm64. At run time the load test touches only the newest posts,
their likes and authors, so the working set is a small part of the mapped file. The Nanode's server process stays
under 100 MB RSS.

## StardustDB API usage, checked against the Rust reference

Every StardustDB call the server and the importer make, checked on 2026-10-17 against:
- the StardustDB reference (Overview, Database, Queries and mutations, Linking, Bounds, Grouping, Explain);
- the doc comments of the Rust binding in the release bundle we build against.

The reference pages render Go examples; the rules they state are the same for every binding, and the Rust signatures
come from the binding.

| Call | What the reference says | What this code does | |
|---|---|---|---|
| `check_version`, `activate`, `license` | Activate the core with a license token before creating resources; check the ABI version | `setup::activate` checks the version, activates once per process before `open`, and prints the tier and expiry, never the token | ✓ |
| `open(path, Options)` | `plugins: Some({})` enables none; a positive `lock_timeout` waits up to that long | No plugins; `lock_timeout` 10 s; everything else default | ✓ |
| `parse(text, DUST)` + `Database::query` | An inline definition is copied into the query handle; a query runs any number of times; the database and every handle may be used from any thread | Each query is opened once at start and reused; the ring thread and the writer each use their own handles | ✓ |
| Query parameters | An entity position takes `{#link id}`, never a bare number | Every entity parameter is a `Link` (serializes as `{#link id}`) | ✓ |
| `RunOptions` | `max_cost` is the thread-CPU limit of one run; 0 selects a budget derived from the query's structure and rows; `page_size` 0 is the default page (100 rows) | `max_cost` 5 s, because the derived budget refused queries on a cold, freshly copied file; `page_size` 0 | ✓ |
| `Rows::next_page` | Every page reads the run's snapshot; a page outlives the rows, the query and the database | One page per run (results are at most 20 rows); the rows handle drops right after | ✓ |
| `find … [count ?l ?n] … groupBy […]`, `limit 1` | An aggregate column is the name, its argument and the result variable; `groupBy` names the grouping variables | The post and feed reads group on every non-aggregated variable; the like check uses `limit 1` | ✓ |
| `merge_patch` | Top-level keys are existing ids as decimal strings, or `#_name` for new entities; `{#link "#_name"}` links within the patch; one transaction, durable on return | Slots are keyed by id string, new posts and likes by `#_` names, self-links and slot links by `{#link "#_…"}` | ✓ |
| `Commit` | `status`; `ids` maps each `#_name` to its entity id | Answers only after `CommitStatus::COMMITTED`; a new post's id comes from `commit.ids` | ✓ |
| Entity id order | `ids` is a map: the reference gives no order for new ids | The importer checks every post's id in `commit.ids` and stops if any differs. The writer used to rank a round's new posts by patch order; it now takes at most 20 new posts per round, so their order never matters | fixed |
| Concurrent writes, `commit_batch` | Write calls return once durable, and concurrent writes share a sync | One writer thread batches a round into one `merge_patch` (the 15 ms window), so there are no concurrent writes to share | ✓ |
| Static linking | Rust links `libstardust_full.a`, and the executable is the only file; `ldd` shows no StardustDB library | `features = ["static"]`; the deploy prints `0 shared StardustDB libraries` after each build | ✓ |
| Explain | `arena_capacity` reports the scratch arena a call reserved: 4,194,304 bytes in the reference's own example | That 4 MiB arena, zeroed by every query, is the per-query floor measured above | ✓ |

