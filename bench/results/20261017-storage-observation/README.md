# Storage observation, 2026-10-17

The Stardust seed is substantially larger than the raw input. A fresh local import also reproduced the
remembered 7.4 GB RAM peak. These are separate costs.

| Measurement | Bytes | Readable size |
|---|---:|---:|
| users.tsv, 50,000 rows | 2,482,690 | 2.37 MiB |
| posts.tsv, 500,000 rows | 83,493,309 | 79.63 MiB |
| likes.tsv, 2,016,005 rows | 75,709,498 | 72.20 MiB |
| Total TSV input | 161,685,497 | **154.20 MiB** |
| Existing compressed seed upload | 217,549,076 | **207.47 MiB** |
| Server seed, apparent length | 4,294,967,296 | **4.00 GiB** |
| Server seed, allocated blocks | 3,898,347,520 | **3.63 GiB** |
| Fresh local import, allocated blocks | 3,903,275,008 | **3.64 GiB** |
| Fresh local import, peak RSS | 7,437,336,576 | **6.93 GiB / 7.44 GB** |

The server seed's allocated size is **24.11×** the TSV bytes. This ratio includes the database representation;
it does not isolate data, indexes, allocator slack or history. The local import took **81.04 seconds**, using
the existing macOS arm64 importer whose SHA-256 is in [seed-import.json](seed-import.json). Generation,
compilation, hashing and compression are excluded from that timer. The newly generated database and TSVs
were temporary fixtures; the existing local seed and server database were preserved.

## Live observation window

The service was already active, with a start time of **14:25:26 UTC**. Two read-only snapshots, without a
restart, observed the same database device/inode and process PID/start counter:

| Metric | 15:33:12 UTC | 15:38:05 UTC | Change over 293 seconds |
|---|---:|---:|---:|
| Run file, apparent | 4.000 GiB | 4.000 GiB | **0 bytes** |
| Run file, allocated | 2.9227 GiB | 2.9332 GiB | **+10.78 MiB** |
| Process write counter | 53,972,385,792 bytes | 55,627,546,624 bytes | **+1.54 GiB** |
| Process cancelled-write counter | 0 | 0 | 0 |

The file can receive considerable write traffic without increasing its apparent length. During this window,
its allocation did grow. These endpoint observations do not identify individual requests or attribute growth
to a particular database feature, and do not establish a sustained growth rate.

**Whole-session growth remains unknown.** There was no allocation baseline when this session started.
The service's `cp --reflink=auto --sparse=always` can give the run copy a different allocation from the seed,
so subtracting the seed's 3.63 GiB from the run's 2.93 GiB would not measure session growth.

## Evidence and method

- [storage-snapshots.csv](storage-snapshots.csv): raw Linux file metadata and process counters, collected by
  `deploy/host/storage.sh` sent over SSH stdin. Neither the service nor its installed sampler was changed.
- [server.txt](server.txt): service start, PID, kernel and the deployment's recorded compressed-seed hash.
  That recorded hash matches the local archive; the live database was not scanned or hashed.
- [seed-observation.json](seed-observation.json): local archive/file metadata and regenerated TSV byte
  counts, rows and hashes. The generator hash matches `bench/upstream.sh`'s pin. Tokens are excluded.
- [seed-import.json](seed-import.json): a fresh import measurement using those TSVs. This is evidence for
  this local import, not a measurement recovered from the old import or old benchmark sessions.

Apparent bytes come from file length; allocation is the file's reported blocks times their byte unit.
Allocation may include shared extents. Filesystem free space includes other files. Process writes and
cancelled writes use Linux [`/proc/PID/io`](https://man7.org/linux/man-pages/man5/proc_pid_io.5.html);
they are not physical-device write amplification. Peak import RSS uses the import child's `getrusage`
high-water mark, normalized to bytes on macOS and Linux. No `sync`, compaction or database queries were used
for the live snapshots.

New benchmark sessions now capture before-reset, fresh-run-start and end-of-collection snapshots, plus
one-second samples, so future reports can measure growth against the run's own baseline.
