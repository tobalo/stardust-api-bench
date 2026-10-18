//! Stardust reads on the request path. Ring threads run them while they hold
//! the App mutex. Every request reads the database while it is served: the
//! only state kept between requests is the layout (two entity ids that never
//! change) and the prepared query handles.
//!
//! Every Stardust query has a fixed cost (it zeroes a 4 MB scratch arena: about
//! 0.4 ms on a Nanode), so each request is one query. A feed reads the posts the
//! 20 feed slots link to (the writer keeps them on the 20 newest) with their
//! fields and like counts; a post reads its fields and like count. Every post
//! links to itself through `post`, the attribute likes use, so a grouped count
//! always has a row for it (a left join): like_count is that count minus one.
//! Lookups start from a bound entity or a rare attribute, never a scan (see
//! DESIGN.md).
use std::{sync::Arc, time::Duration};

use stardust::{Database, Document, Format, Link, NodeId, Query, RunOptions};

/// Rows the feed returns.
pub const FEED: usize = 20;

pub type Res<T> = Result<T, stardust::Error>;

/// The two entity ids the importer records in the meta entity.
#[derive(Clone, Copy)]
pub struct Layout {
    pub meta: i64,
    /// User N is entity user_base + N.
    pub user_base: i64,
}

pub fn query(db: &Database, dust: &str) -> Query {
    let definition = stardust::parse(dust, Format::DUST).expect("query text");
    db.query(&definition).expect("query definition")
}

#[derive(serde::Serialize)]
pub struct P {
    #[serde(rename = "?p")]
    pub p: Link,
}
#[derive(serde::Serialize)]
pub struct M {
    #[serde(rename = "?m")]
    pub m: Link,
}

/// Run options. max_cost is the thread-CPU limit of one run: without a positive
/// value the engine derives a budget from the query's structure and rows, and
/// that budget refused the first queries on a freshly copied, cold file
/// (work_limit_exceeded) while its pages faulted in. page_size 0 selects the
/// default page of 100 rows.
const RUN: RunOptions = RunOptions { page_size: 0, max_cost: Duration::from_secs(5), as_of: 0 };

/// Runs a query and returns its first page. Every query here returns at most
/// 20 rows, so the first page holds the whole result; dropping the rows
/// releases the cursor, and the page stays valid on its own.
pub fn page<T: serde::Serialize>(query: &Query, params: &T) -> Res<Document> {
    let mut rows = stardust::run_query_value(query, Some(params), &RUN, None)?;
    rows.next_page()
}
pub fn first_row(doc: &Document) -> Res<Option<NodeId>> {
    let root = doc.root()?;
    Ok(doc.read(root)?.first_child)
}
pub fn text<'a>(doc: &'a Document, row: NodeId, key: &str) -> Res<&'a str> {
    Ok(doc.read(doc.member(row, key)?)?.text)
}
pub fn int(doc: &Document, row: NodeId, key: &str) -> Res<i64> {
    doc.i64(doc.member(row, key)?)
}
pub fn link(doc: &Document, row: NodeId, key: &str) -> Res<i64> {
    let value = doc.member(row, key)?;
    doc.i64(doc.member(value, "#link")?)
}

/// Finds the meta entity the importer wrote and checks its layout version.
pub fn layout(db: &Database) -> Result<Layout, String> {
    let q = query(db, "{find [?m ?layout ?base] where [[?m layout ?layout] [?m user_base ?base]]}");
    let none = std::collections::BTreeMap::<String, i64>::new();
    let doc = page(&q, &none).map_err(|e| format!("read layout: {e}"))?;
    let row = first_row(&doc)
        .map_err(|e| format!("read layout: {e}"))?
        .ok_or("the database has no meta entity: build it with seed/make-seed.sh")?;
    let version = text(&doc, row, "layout").map_err(|e| e.to_string())?;
    if version != crate::setup::LAYOUT {
        return Err(format!(
            "database layout {version:?}, server expects {:?}: rebuild the seed with seed/make-seed.sh",
            crate::setup::LAYOUT
        ));
    }
    Ok(Layout {
        meta: link(&doc, row, "m").map_err(|e| e.to_string())?,
        user_base: int(&doc, row, "base").map_err(|e| e.to_string())?,
    })
}

/// The row ids of a result page, in order.
pub fn rows(doc: &Document) -> Res<Vec<NodeId>> {
    let mut out = Vec::with_capacity(FEED);
    let mut next = first_row(doc)?;
    while let Some(row) = next {
        out.push(row);
        next = doc.read(row)?.next_sibling;
    }
    Ok(out)
}

/// The fields of one post, in the order of the response object.
fn write_post(out: &mut Vec<u8>, id: i64, body: &str, at: &str, author: &str, likes: i64) {
    out.extend_from_slice(b"{\"id\":");
    crate::number(id as u64, out);
    out.extend_from_slice(b",\"body\":");
    crate::json_string(body.as_bytes(), out);
    out.extend_from_slice(b",\"created_at\":");
    crate::json_string(at.as_bytes(), out);
    out.extend_from_slice(b",\"author\":");
    crate::json_string(author.as_bytes(), out);
    out.extend_from_slice(b",\"like_count\":");
    crate::number(likes as u64, out);
    out.push(b'}');
}

pub struct Db {
    pub layout: Layout,
    post: Query,
    feed: Query,
    health: Query,
    // Keep the database alive after the query handles: declared last, dropped last.
    _db: Arc<Database>,
}

impl Db {
    pub fn open(db: Arc<Database>, layout: Layout) -> Self {
        const FIELDS: &str = "[?p body ?body] [?p created_at ?at] [?p author ?u] [?u username ?name]";
        Self {
            layout,
            // like_count is counted now: every `post` link to the post, minus its own.
            post: query(
                &db,
                &format!("{{find [?body ?at ?name [count ?l ?n]] where [{FIELDS} [?l post ?p]] groupBy [?body ?at ?name]}}"),
            ),
            // Feed slots: 20 fixed entities whose `feed_post` link the writer
            // overwrites. (A marker added to and retracted from posts left history
            // that every lookup paid for: the feed slowed 8x over 20,000 changes.)
            feed: query(
                &db,
                &format!(
                    "{{find [?p ?body ?at ?name [count ?l ?n]] where [[?s feed_slot ?i] [?s feed_post ?p] {FIELDS} [?l post ?p]] groupBy [?p ?body ?at ?name]}}"
                ),
            ),
            health: query(&db, "{find [?b] where [[?m user_base ?b]]}"),
            _db: db,
        }
    }

    /// Writes one post object. Ok(false): no post has this id.
    fn post(&self, id: i64, out: &mut Vec<u8>) -> Res<bool> {
        let doc = page(&self.post, &P { p: Link(id) })?;
        let Some(row) = first_row(&doc)? else {
            return Ok(false);
        };
        let likes = int(&doc, row, "n")? - 1;
        write_post(out, id, text(&doc, row, "body")?, text(&doc, row, "at")?, text(&doc, row, "name")?, likes);
        Ok(true)
    }

    /// The 20 newest posts, ORDER BY created_at DESC, id DESC.
    fn feed(&self, out: &mut Vec<u8>) -> Res<()> {
        let none = std::collections::BTreeMap::<String, i64>::new();
        let doc = page(&self.feed, &none)?;
        let mut posts = Vec::with_capacity(FEED);
        for row in rows(&doc)? {
            posts.push((text(&doc, row, "at")?, link(&doc, row, "p")?, row));
        }
        // created_at is stored in a fixed-width format, so text order is time order.
        posts.sort_unstable_by(|a, b| (b.0, b.1).cmp(&(a.0, a.1)));
        out.extend_from_slice(b"{\"posts\":[");
        for (i, (at, id, row)) in posts.into_iter().take(FEED).enumerate() {
            if i > 0 {
                out.push(b',');
            }
            let likes = int(&doc, row, "n")? - 1;
            write_post(out, id, text(&doc, row, "body")?, at, text(&doc, row, "name")?, likes);
        }
        out.extend_from_slice(b"]}");
        Ok(())
    }

    /// GET /feed (id None) or GET /posts/:id.
    pub fn read(&mut self, id: Option<i64>, out: &mut Vec<u8>) -> u16 {
        let result = match id {
            Some(id) => {
                out.extend_from_slice(b"{\"post\":");
                self.post(id, out).map(|found| {
                    out.push(b'}');
                    found
                })
            }
            None => self.feed(out).map(|()| true),
        };
        match result {
            Ok(true) => 200,
            Ok(false) => crate::error(out, 404, "post not found"),
            Err(e) => {
                eprintln!("read: {e}");
                crate::error(out, 500, "internal server error")
            }
        }
    }

    pub fn health(&mut self, seconds: u64, out: &mut Vec<u8>) -> u16 {
        match page(&self.health, &M { m: Link(self.layout.meta) }) {
            Ok(_) => {
                out.extend_from_slice(b"{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":");
                crate::number(seconds, out);
                out.push(b'}');
                200
            }
            Err(e) => {
                out.extend_from_slice(b"{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":");
                crate::json_string(e.to_string().as_bytes(), out);
                out.push(b'}');
                503
            }
        }
    }
}
