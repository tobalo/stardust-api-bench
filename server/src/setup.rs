// StardustDB setup shared by the server and the importer: check the linked
// library against the binding, activate the license once per process, then
// open the file. The token is a credential: it is read from the environment or
// a file and never printed.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// The data layout version the importer writes and the server expects.
pub const LAYOUT: &str = "stardust-api-bench/4";

/// Activates the process license. The token comes from, in order:
/// $STARDUST_LICENSE, $STARDUST_TEST_LICENSE (the variable of the packaged
/// examples), $STARDUST_LICENSE_FILE, then ~/.config/stardustdb/stardust.license.
pub fn activate() -> Result<(), String> {
    stardust::check_version(stardust::version())
        .map_err(|e| format!("Stardust library mismatch: {e}"))?;
    let (token, source) = token()?;
    stardust::activate(&token).map_err(|e| format!("Stardust license from {source} was refused: {e}"))?;
    eprintln!("{}", status(&source));
    Ok(())
}

/// One line about the active license: tier and expiry, never the token or
/// the account identity.
fn status(source: &str) -> String {
    let Ok(info) = stardust::license() else {
        return format!("license: active (from {source})");
    };
    let tier = if info.tier.is_empty() { "unknown tier" } else { info.tier.as_str() };
    let expiry = match info.expires {
        None => "no expiry".to_owned(),
        Some(at) => {
            let left = at.duration_since(SystemTime::now()).map(|d| d.as_secs() / 86_400).unwrap_or(0);
            let warn = if left < 3 { " — renew it soon" } else { "" };
            format!("expires {} ({left} days){warn}", &timestamp(at)[..10])
        }
    };
    format!("license: active, {tier}, {expiry} (from {source})")
}

/// UTC with millisecond precision and a Z suffix: the format the seed stores
/// and the API returns (2025-12-31T23:59:19.409Z).
pub fn timestamp(t: SystemTime) -> String {
    let ms = t.duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0);
    let (days, rem) = (ms.div_euclid(86_400_000), ms.rem_euclid(86_400_000));
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        rem / 3_600_000,
        rem / 60_000 % 60,
        rem / 1000 % 60,
        rem % 1000
    )
}

fn token() -> Result<(String, String), String> {
    for name in ["STARDUST_LICENSE", "STARDUST_TEST_LICENSE"] {
        if let Ok(t) = std::env::var(name) {
            if !t.trim().is_empty() {
                return Ok((t.trim().to_owned(), format!("${name}")));
            }
        }
    }
    let file = match std::env::var("STARDUST_LICENSE_FILE") {
        Ok(f) if !f.is_empty() => f,
        _ => format!(
            "{}/.config/stardustdb/stardust.license",
            std::env::var("HOME").unwrap_or_default()
        ),
    };
    let t = std::fs::read_to_string(&file).map_err(|e| {
        format!("no Stardust license: $STARDUST_LICENSE is unset and {file} is unreadable: {e}")
    })?;
    if t.trim().is_empty() {
        return Err(format!("no Stardust license: {file} is empty"));
    }
    Ok((t.trim().to_owned(), file))
}

/// Opens the database. `fresh` discards any existing contents (import only).
/// No plugins: the bench needs neither history nor reactors.
pub fn open(path: &str, fresh: bool) -> Result<stardust::Database, String> {
    let options = stardust::Options {
        create: fresh,
        clear: fresh,
        // Wait out a previous process whose lock is still being released.
        lock_timeout: Some(Duration::from_secs(10)),
        plugins: Some(Default::default()),
        ..stardust::Options::default()
    };
    stardust::open(path, &options).map_err(|e| format!("open {path}: {e}"))
}
