// Imports the challenge seed (the TSV files of seed/generate.mjs) into a new
// Stardust database.
//
//   import <tsv-dir> <database>
//
// Layout (DESIGN.md):
//   post  {body, created_at, author {#link user}, post {#link itself}}
//   user  {username, created_at}
//   like  {user {#link user}, post {#link post}, created_at}
//   slot  {feed_slot 0..19, feed_post {#link one of the 20 newest posts}}
//   meta  {layout, user_base}
//
// A post's API id is its entity id. Stardust numbers new entities in patch
// order from 1, so the first transaction writes the 500,000 posts first and
// they receive ids 1..500,000; the importer checks every one and fails
// otherwise. Users follow, so user N is entity user_base + N. 20 feed slots
// link to the 20 newest posts in (created_at, id) order: the feed reads them in
// one query instead of sorting every post, and the server's writer moves them.
// Every post links to itself through `post`, the attribute likes use, so a
// grouped like count always has a row (like_count = count - 1).

#[path = "../setup.rs"]
mod setup;

use serde::ser::{Serialize, SerializeMap, Serializer};
use stardust::Link;
use std::{collections::HashMap, time::Instant};

type R<T = ()> = Result<T, Box<dyn std::error::Error>>;

const LIKE_BATCH: usize = 50_000;

/// A link to a temporary entity of the same patch: {#link "#_name"}.
struct Temp(String);
impl Serialize for Temp {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut m = s.serialize_map(Some(1))?;
        m.serialize_entry("#link", &self.0)?;
        m.end()
    }
}

#[derive(serde::Serialize)]
struct PostFields<'a> {
    body: &'a str,
    created_at: &'a str,
    author: Temp,
    post: Temp,
}
#[derive(serde::Serialize)]
struct SlotFields {
    feed_slot: i64,
    feed_post: Temp,
}
#[derive(serde::Serialize)]
struct UserFields<'a> {
    username: &'a str,
    created_at: &'a str,
}
#[derive(serde::Serialize)]
struct MetaFields {
    layout: &'static str,
}
#[derive(serde::Serialize)]
struct LikeFields<'a> {
    user: Link,
    post: Link,
    created_at: &'a str,
}

struct Post {
    id: i64,
    user: i64,
    body: String,
    created_at: String,
}
struct User {
    id: i64,
    username: String,
    created_at: String,
}

/// The first transaction: posts in id order, then users, then the meta
/// entity. A map serializer keeps this order; patch order is id order.
struct Base<'a> {
    posts: &'a [Post],
    users: &'a [User],
    feed: &'a [i64],
}
impl Serialize for Base<'_> {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut m = s.serialize_map(Some(self.posts.len() + self.users.len() + 1))?;
        for p in self.posts {
            m.serialize_entry(
                &format!("#_p{}", p.id),
                &PostFields {
                    body: &p.body,
                    created_at: &p.created_at,
                    author: Temp(format!("#_u{}", p.user)),
                    post: Temp(format!("#_p{}", p.id)),
                },
            )?;
        }
        for u in self.users {
            m.serialize_entry(
                &format!("#_u{}", u.id),
                &UserFields { username: &u.username, created_at: &u.created_at },
            )?;
        }
        m.serialize_entry("#_meta", &MetaFields { layout: setup::LAYOUT })?;
        for (i, post) in self.feed.iter().enumerate() {
            m.serialize_entry(
                &format!("#_s{i}"),
                &SlotFields { feed_slot: i as i64, feed_post: Temp(format!("#_p{post}")) },
            )?;
        }
        m.end()
    }
}

struct Likes<'a>(&'a [(i64, i64, &'a str)], i64, usize);
impl Serialize for Likes<'_> {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let Likes(rows, user_base, offset) = *self;
        let mut m = s.serialize_map(Some(rows.len()))?;
        for (i, (user, post, at)) in rows.iter().enumerate() {
            m.serialize_entry(
                &format!("#_l{}", offset + i),
                &LikeFields { user: Link(user_base + user), post: Link(*post), created_at: at },
            )?;
        }
        m.end()
    }
}

fn tsv(dir: &str, name: &str) -> R<String> {
    let path = format!("{dir}/{name}.tsv");
    std::fs::read_to_string(&path).map_err(|e| format!("{path}: {e}").into())
}
fn fields<'a, const N: usize>(line: &'a str, file: &str) -> R<[&'a str; N]> {
    let parts: Vec<&str> = line.split('\t').collect();
    parts
        .try_into()
        .map_err(|_| format!("{file}: expected {N} tab-separated fields in {line:?}").into())
}

fn main() -> R {
    let mut args = std::env::args().skip(1);
    let (Some(dir), Some(out), None) = (args.next(), args.next(), args.next()) else {
        return Err("usage: import <tsv-dir> <database>".into());
    };
    let start = Instant::now();
    setup::activate()?;

    let users_text = tsv(&dir, "users")?;
    let mut users = Vec::with_capacity(50_000);
    for line in users_text.lines() {
        let [id, username, created_at] = fields(line, "users.tsv")?;
        users.push(User { id: id.parse()?, username: username.into(), created_at: created_at.into() });
    }
    let posts_text = tsv(&dir, "posts")?;
    let mut posts = Vec::with_capacity(500_000);
    for line in posts_text.lines() {
        let [id, user, body, created_at] = fields(line, "posts.tsv")?;
        posts.push(Post { id: id.parse()?, user: user.parse()?, body: body.into(), created_at: created_at.into() });
    }
    // Patch order must be id order 1..N for ids to match.
    for (i, p) in posts.iter().enumerate() {
        if p.id != i as i64 + 1 {
            return Err(format!("posts.tsv: row {} has id {}, expected {}", i + 1, p.id, i + 1).into());
        }
    }
    for (i, u) in users.iter().enumerate() {
        if u.id != i as i64 + 1 {
            return Err(format!("users.tsv: row {} has id {}, expected {}", i + 1, u.id, i + 1).into());
        }
    }
    // The feed: the 20 newest posts in (created_at, id) order.
    let mut order: Vec<usize> = (0..posts.len()).collect();
    order.sort_by(|&a, &b| {
        (posts[b].created_at.as_str(), posts[b].id).cmp(&(posts[a].created_at.as_str(), posts[a].id))
    });
    let feed: Vec<i64> = order.iter().take(20).map(|&i| posts[i].id).collect();

    let db = setup::open(&out, true)?;
    let t = Instant::now();
    let base = stardust::merge_patch_value(&db, &Base { posts: &posts, users: &users, feed: &feed }, None)?;
    for p in &posts {
        let got = base.ids.get(&format!("#_p{}", p.id)).copied();
        if got != Some(p.id) {
            return Err(format!("post {} received entity id {got:?}; the layout needs ids to match", p.id).into());
        }
    }
    let user_base = base.ids["#_u1"] - 1;
    for u in &users {
        if base.ids[&format!("#_u{}", u.id)] != user_base + u.id {
            return Err(format!("user {} is not entity {}", u.id, user_base + u.id).into());
        }
    }
    let meta = base.ids["#_meta"];
    let set = stardust::merge_patch_value(&db, &HashMap::from([(meta.to_string(), HashMap::from([("user_base", user_base)]))]), None)?;
    if set.status != stardust::CommitStatus::COMMITTED {
        return Err("meta user_base did not commit".into());
    }
    eprintln!(
        "posts 1..{} and {} users (user_base {user_base}, meta {meta}) in {:.1?}",
        posts.len(),
        users.len(),
        t.elapsed()
    );
    drop((posts, posts_text, feed, order));

    let t = Instant::now();
    let likes_text = tsv(&dir, "likes")?;
    let mut likes = Vec::with_capacity(2_100_000);
    for line in likes_text.lines() {
        let [user, post, created_at] = fields(line, "likes.tsv")?;
        likes.push((user.parse::<i64>()?, post.parse::<i64>()?, created_at));
    }
    for (i, chunk) in likes.chunks(LIKE_BATCH).enumerate() {
        let c = stardust::merge_patch_value(&db, &Likes(chunk, user_base, i * LIKE_BATCH), None)?;
        if c.ids.len() != chunk.len() {
            return Err(format!("like batch {i}: {} of {} committed", c.ids.len(), chunk.len()).into());
        }
    }
    eprintln!("{} likes in {:.1?}", likes.len(), t.elapsed());
    db.close();
    eprintln!("imported {out} in {:.1?}", start.elapsed());
    Ok(())
}
