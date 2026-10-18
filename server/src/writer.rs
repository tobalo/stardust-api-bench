//! Group commit on a dedicated thread. Stardust has no begin/commit: every
//! merge_patch is one transaction that returns once it is durable, and that
//! sync takes milliseconds of wall time but microseconds of CPU. Committing on
//! a ring thread would stall every connection of that ring, so writes queue
//! here instead. Each round takes everything queued, checks it, commits it as
//! one merge_patch and replies; whatever arrives during a sync joins the next
//! round.
//!
//! This thread is the only writer, so its checks and its patch cannot
//! interleave with another write: Stardust holds the file lock for this
//! process and every write passes through here.
use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::{Arc, Condvar, Mutex},
    time::{Duration, Instant, SystemTime},
};

use serde::ser::{Serialize, SerializeMap, Serializer};
use stardust::{Database, Link, Query};

use crate::db::{self, Layout, P, Res};

pub enum Op {
    Create { user: i64, username: String, body: String },
    Like { user: i64, post: i64 },
}

/// Receives the status and body of a write once it is durable (or failed).
pub type Reply = Box<dyn FnOnce(u16, Vec<u8>) + Send>;

pub struct Writer {
    queue: Mutex<VecDeque<(Op, Reply)>>,
    ready: Condvar,
    window: Duration,
}

/// How long a round keeps collecting writes after the first one arrives.
/// Each commit rewrites the index pages it touches (about 480 KB per commit on
/// the bench), so fewer, larger commits cost less CPU and disk. Writes wait at
/// most this long before their commit starts.
pub const WINDOW: Duration = Duration::from_millis(15);

/// The writer's nice value. On one vCPU the writer and the ring thread compete;
/// when both are runnable, serving requests goes first and writes follow.
#[cfg(target_os = "linux")]
const NICE: i32 = 5;

impl Writer {
    pub fn start(database: Arc<Database>, layout: Layout, window: Duration) -> Arc<Writer> {
        let writer = Arc::new(Writer { queue: Mutex::new(VecDeque::new()), ready: Condvar::new(), window });
        let shared = Arc::clone(&writer);
        std::thread::Builder::new()
            .name("writer".into())
            .spawn(move || {
                // PRIO_PROCESS with who = 0 sets this thread's nice value on Linux.
                #[cfg(target_os = "linux")]
                unsafe {
                    libc::setpriority(libc::PRIO_PROCESS, 0, NICE);
                }
                Round::new(database, layout).run(&shared)
            })
            .expect("start writer thread");
        writer
    }

    pub fn submit(&self, op: Op, reply: Reply) {
        self.queue.lock().unwrap().push_back((op, reply));
        self.ready.notify_one();
    }
}

enum Entity {
    /// A new post; `this` is its own #_ name, for the self-link.
    Post { body: String, created_at: String, author: i64, this: String },
    Like { user: i64, post: i64, created_at: String },
    /// A feed slot now links to a post created in the same patch (its #_ name).
    Slot(String),
}
impl Serialize for Entity {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut m = s.serialize_map(None)?;
        match self {
            Entity::Post { body, created_at, author, this } => {
                m.serialize_entry("body", body)?;
                m.serialize_entry("created_at", created_at)?;
                m.serialize_entry("author", &Link(*author))?;
                // Every post links to itself through `post`, so like counts always
                // have a row for it (see db.rs).
                m.serialize_entry("post", &HashMap::from([("#link", this)]))?;
            }
            Entity::Like { user, post, created_at } => {
                m.serialize_entry("user", &Link(*user))?;
                m.serialize_entry("post", &Link(*post))?;
                m.serialize_entry("created_at", created_at)?;
            }
            Entity::Slot(post) => m.serialize_entry("feed_post", &HashMap::from([("#link", post)]))?,
        }
        m.end()
    }
}

/// Patch entries in order: a map serializer keeps it.
struct Patch(Vec<(String, Entity)>);
impl Serialize for Patch {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut m = s.serialize_map(Some(self.0.len()))?;
        for (key, entity) in &self.0 {
            m.serialize_entry(key, entity)?;
        }
        m.end()
    }
}

/// What one op answers. `Commit` answers depend on this round's commit.
enum Answer {
    Now(u16, Vec<u8>),
    Created { temp: String, created_at: String },
    Liked { post: i64, already: bool },
}

struct Round {
    database: Arc<Database>,
    layout: Layout,
    post_exists: Query,
    user_exists: Query,
    both_exist: Query,
    liked: Query,
    feed: Query,
}

impl Round {
    fn new(database: Arc<Database>, layout: Layout) -> Self {
        Self {
            post_exists: db::query(&database, "{find [?b] where [[?p body ?b]]}"),
            both_exist: db::query(&database, "{find [?b ?name] where [[?p body ?b] [?u username ?name]]}"),
            user_exists: db::query(&database, "{find [?name] where [[?p username ?name]]}"),
            liked: db::query(&database, "{find [?l] where [[?l post ?p] [?l user ?u]] limit 1}"),
            feed: db::query(&database, "{find [?s ?p ?at] where [[?s feed_slot ?i] [?s feed_post ?p] [?p created_at ?at]]}"),
            database,
            layout,
        }
    }

    fn run(mut self, writer: &Writer) -> ! {
        let mut batch = Vec::new();
        loop {
            {
                let mut queue = writer.queue.lock().unwrap();
                while queue.is_empty() {
                    queue = writer.ready.wait(queue).unwrap();
                }
                // Collect for the window after the first write: one commit instead of several.
                let deadline = Instant::now() + writer.window;
                loop {
                    let now = Instant::now();
                    if now >= deadline {
                        break;
                    }
                    queue = writer.ready.wait_timeout(queue, deadline - now).unwrap().0;
                }
                // At most FEED new posts per round: they all carry this round's
                // created_at, the newest, so all of them enter the feed and the
                // slots never depend on the order of the ids StardustDB assigns
                // (commit.ids maps each #_name to its id, but promises no order).
                let mut creates = 0;
                while let Some((op, _)) = queue.front() {
                    if matches!(op, Op::Create { .. }) {
                        if creates == db::FEED {
                            break;
                        }
                        creates += 1;
                    }
                    batch.push(queue.pop_front().unwrap());
                }
            }
            let answers = self.apply(&batch);
            for ((_, reply), (status, body)) in batch.drain(..).zip(answers) {
                reply(status, body);
            }
        }
    }

    fn exists(&self, query: &Query, id: i64) -> Res<bool> {
        Ok(db::first_row(&db::page(query, &P { p: Link(id) })?)?.is_some())
    }

    /// The post and the user both exist: one query for the common case.
    fn both_exist(&self, user: i64, post: i64) -> Res<bool> {
        #[derive(serde::Serialize)]
        struct UP {
            #[serde(rename = "?u")]
            u: Link,
            #[serde(rename = "?p")]
            p: Link,
        }
        Ok(db::first_row(&db::page(&self.both_exist, &UP { u: Link(user), p: Link(post) })?)?.is_some())
    }

    fn liked(&self, user: i64, post: i64) -> Res<bool> {
        #[derive(serde::Serialize)]
        struct UP {
            #[serde(rename = "?u")]
            u: Link,
            #[serde(rename = "?p")]
            p: Link,
        }
        Ok(db::first_row(&db::page(&self.liked, &UP { u: Link(user), p: Link(post) })?)?.is_some())
    }

    /// The feed slots, the posts they link to and those posts' created_at, read
    /// live once a round.
    fn feed(&self) -> Res<FeedSet> {
        let none = std::collections::BTreeMap::<String, i64>::new();
        let doc = db::page(&self.feed, &none)?;
        let mut set = FeedSet { slots: Vec::with_capacity(db::FEED), posts: Vec::with_capacity(db::FEED + 1) };
        for row in db::rows(&doc)? {
            let post = db::link(&doc, row, "p")?;
            set.slots.push((db::link(&doc, row, "s")?, post));
            set.posts.push((Feed::Existing(post), db::text(&doc, row, "at")?.to_owned()));
        }
        Ok(set)
    }

    fn decide(&self, op: &Op, now: &str, round: &mut State) -> Res<Answer> {
        match op {
            Op::Like { user, post } => {
                // Each Stardust query has a fixed cost, so the common paths use
                // few: a repeat like is one query, a new like two.
                let user = self.layout.user_base + user;
                if round.likes.contains(&(user, *post)) || self.liked(user, *post)? {
                    // A like links to an existing post, so the post exists.
                    return Ok(Answer::Liked { post: *post, already: true });
                }
                if !self.both_exist(user, *post)? {
                    if !self.exists(&self.post_exists, *post)? {
                        return Ok(Answer::Now(404, error_body("post not found")));
                    }
                    // A signed token for a user the database does not have: a
                    // like must link to an existing user.
                    return Ok(Answer::Now(500, error_body("internal server error")));
                }
                round.likes.insert((user, *post));
                round.patch.push((
                    format!("#_l{}", round.patch.len()),
                    Entity::Like { user, post: *post, created_at: now.to_owned() },
                ));
                Ok(Answer::Liked { post: *post, already: false })
            }
            Op::Create { user, body, .. } => {
                let author = self.layout.user_base + user;
                if !self.exists(&self.user_exists, author)? {
                    return Ok(Answer::Now(500, error_body("internal server error")));
                }
                if round.feed.is_none() {
                    round.feed = Some(self.feed()?);
                }
                let created_at = now.to_owned();
                let temp = format!("#_p{}", round.patch.len());
                round.feed.as_mut().unwrap().posts.push((Feed::New(round.patch.len()), created_at.clone()));
                round.patch.push((
                    temp.clone(),
                    Entity::Post { body: body.clone(), created_at: created_at.clone(), author, this: temp.clone() },
                ));
                Ok(Answer::Created { temp, created_at })
            }
        }
    }

    fn apply(&mut self, batch: &[(Op, Reply)]) -> Vec<(u16, Vec<u8>)> {
        let now = crate::setup::timestamp(SystemTime::now());
        let mut round = State::default();
        let mut answers = Vec::with_capacity(batch.len());
        for (op, _) in batch {
            answers.push(self.decide(op, &now, &mut round).unwrap_or_else(|e| {
                eprintln!("write check: {e}");
                Answer::Now(500, error_body("internal server error"))
            }));
        }
        if let Some(mut feed) = round.feed.take() {
            // The slots must link to the 20 newest by (created_at, id). This round's
            // new posts share the newest created_at and number at most FEED, so
            // all of them belong; the existing posts compare by their real ids.
            feed.posts.sort_by(|a, b| (b.1.as_str(), b.0).cmp(&(a.1.as_str(), a.0)));
            let newest: Vec<Feed> = feed.posts.iter().take(db::FEED).map(|(p, _)| *p).collect();
            // Slots whose post left the top 20 take the new posts that entered it.
            let mut entering = newest.iter().filter_map(|p| match p {
                Feed::New(i) => Some(*i),
                Feed::Existing(_) => None,
            });
            for (slot, post) in feed.slots {
                if newest.contains(&Feed::Existing(post)) {
                    continue;
                }
                let Some(i) = entering.next() else { break };
                round.patch.push((slot.to_string(), Entity::Slot(round.patch[i].0.clone())));
            }
        }
        let commit = if round.patch.is_empty() {
            Ok(None)
        } else {
            let started = std::time::Instant::now();
            let result = stardust::merge_patch_value(&self.database, &Patch(std::mem::take(&mut round.patch)), None);
            crate::stats::STATS.commit(started);
            result.map(Some)
        };
        let ids = match commit {
            Ok(Some(c)) if c.status == stardust::CommitStatus::COMMITTED => Some(c.ids),
            Ok(Some(c)) => {
                eprintln!("commit: status {}", c.status.name());
                None
            }
            Ok(None) => Some(Default::default()),
            Err(e) => {
                eprintln!("commit: {e}");
                None
            }
        };
        let stats = &crate::stats::STATS;
        stats.writes.fetch_add(batch.len() as u64, std::sync::atomic::Ordering::Relaxed);
        if ids.is_none() {
            stats.write_errors.fetch_add(batch.len() as u64, std::sync::atomic::Ordering::Relaxed);
        }
        answers
            .into_iter()
            .zip(batch)
            .map(|(answer, (op, _))| match (answer, &ids) {
                (Answer::Now(status, body), _) => (status, body),
                // Every other answer relies on this round's commit.
                (_, None) => (500, error_body("internal server error")),
                (Answer::Liked { post, already }, Some(_)) => {
                    let mut out = Vec::with_capacity(64);
                    out.extend_from_slice(if already {
                        b"{\"liked\":true,\"already_liked\":true,\"post_id\":"
                    } else {
                        b"{\"liked\":true,\"already_liked\":false,\"post_id\":"
                    });
                    crate::number(post as u64, &mut out);
                    out.push(b'}');
                    (if already { 200 } else { 201 }, out)
                }
                (Answer::Created { temp, created_at }, Some(ids)) => {
                    let (Some(&id), Op::Create { username, body, .. }) = (ids.get(&temp), op) else {
                        return (500, error_body("internal server error"));
                    };
                    let mut out = Vec::with_capacity(body.len() + 128);
                    out.extend_from_slice(b"{\"post\":{\"id\":");
                    crate::number(id as u64, &mut out);
                    out.extend_from_slice(b",\"body\":");
                    crate::json_string(body.as_bytes(), &mut out);
                    out.extend_from_slice(b",\"created_at\":");
                    crate::json_string(created_at.as_bytes(), &mut out);
                    out.extend_from_slice(b",\"author\":");
                    crate::json_string(username.as_bytes(), &mut out);
                    out.extend_from_slice(b",\"like_count\":0}}");
                    (201, out)
                }
            })
            .collect()
    }
}

#[derive(Default)]
struct State {
    patch: Vec<(String, Entity)>,
    likes: HashSet<(i64, i64)>,
    /// The feed for this round: the live slots, plus this round's new posts.
    feed: Option<FeedSet>,
}

struct FeedSet {
    /// (slot entity, the post it links to)
    slots: Vec<(i64, i64)>,
    /// Feed candidates with their created_at: the slots' posts and new posts.
    posts: Vec<(Feed, String)>,
}

/// A feed member: an existing post, or a new post at its index in the patch.
/// New posts sort after existing posts only when created_at ties, which needs
/// an existing post from the same millisecond: rounds are at least the write
/// window apart, so that does not happen.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Feed {
    Existing(i64),
    New(usize),
}

fn error_body(message: &str) -> Vec<u8> {
    let mut out = Vec::new();
    crate::error(&mut out, 0, message);
    out
}

#[cfg(test)]
mod tests {
    use crate::setup::timestamp;
    use std::time::{Duration, UNIX_EPOCH};

    #[test]
    fn formats_utc_milliseconds() {
        let at = |ms| timestamp(UNIX_EPOCH + Duration::from_millis(ms));
        assert_eq!(at(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(at(1_767_225_599_409), "2025-12-31T23:59:59.409Z");
        assert_eq!(at(951_782_400_000), "2000-02-29T00:00:00.000Z");
        assert_eq!(at(1_772_323_200_001), "2026-03-01T00:00:00.001Z");
    }
}
