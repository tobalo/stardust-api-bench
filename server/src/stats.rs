//! Server counters, printed every INTERVAL as one `stats` line on stderr
//! (journald under systemd): the request mix, read service time, Stardust
//! group-commit rounds and commit time, and open connections. Counting costs
//! relaxed atomic adds on the request path; bench/report.py charts the lines.
use std::{
    sync::atomic::{AtomicI64, AtomicU64, Ordering::Relaxed},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const INTERVAL: Duration = Duration::from_secs(5);

pub struct Stats {
    pub feed: AtomicU64,
    pub post: AtomicU64,
    pub other: AtomicU64,
    read_us: AtomicU64,
    read_max_us: AtomicU64,
    pub writes: AtomicU64,
    pub write_errors: AtomicU64,
    rounds: AtomicU64,
    commit_us: AtomicU64,
    commit_max_us: AtomicU64,
    pub connections: AtomicI64,
}

pub static STATS: Stats = Stats {
    feed: AtomicU64::new(0),
    post: AtomicU64::new(0),
    other: AtomicU64::new(0),
    read_us: AtomicU64::new(0),
    read_max_us: AtomicU64::new(0),
    writes: AtomicU64::new(0),
    write_errors: AtomicU64::new(0),
    rounds: AtomicU64::new(0),
    commit_us: AtomicU64::new(0),
    commit_max_us: AtomicU64::new(0),
    connections: AtomicI64::new(0),
};

impl Stats {
    /// Time spent serving one feed or post read, Stardust queries included.
    pub fn read(&self, since: Instant) {
        let us = since.elapsed().as_micros() as u64;
        self.read_us.fetch_add(us, Relaxed);
        self.read_max_us.fetch_max(us, Relaxed);
    }
    /// One writer round that committed: its merge_patch time.
    pub fn commit(&self, since: Instant) {
        let us = since.elapsed().as_micros() as u64;
        self.rounds.fetch_add(1, Relaxed);
        self.commit_us.fetch_add(us, Relaxed);
        self.commit_max_us.fetch_max(us, Relaxed);
    }
}

pub fn start() {
    std::thread::Builder::new()
        .name("stats".into())
        .spawn(|| {
            loop {
                std::thread::sleep(INTERVAL);
                let s = &STATS;
                let take = |a: &AtomicU64| a.swap(0, Relaxed);
                let (feed, post, other) = (take(&s.feed), take(&s.post), take(&s.other));
                let (read_us, read_max) = (take(&s.read_us), take(&s.read_max_us));
                let (writes, errors) = (take(&s.writes), take(&s.write_errors));
                let (rounds, commit_us, commit_max) = (take(&s.rounds), take(&s.commit_us), take(&s.commit_max_us));
                let reads = feed + post;
                let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
                eprintln!(
                    "stats t={now} interval_s={} feed={feed} post={post} other={other} read_avg_us={} read_max_us={read_max} \
                     writes={writes} write_errors={errors} rounds={rounds} batch={:.1} commit_avg_ms={:.2} commit_max_ms={:.2} conns={}",
                    INTERVAL.as_secs(),
                    read_us.checked_div(reads).unwrap_or(0),
                    if rounds > 0 { writes as f64 / rounds as f64 } else { 0.0 },
                    if rounds > 0 { commit_us as f64 / rounds as f64 / 1000.0 } else { 0.0 },
                    commit_max as f64 / 1000.0,
                    s.connections.load(Relaxed),
                );
            }
        })
        .expect("start stats thread");
}
