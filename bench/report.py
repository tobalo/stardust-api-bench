#!/usr/bin/env python3
"""Builds a self-contained HTML report from bench results (stdlib only).

    python3 bench/report.py bench/results/<session>             # -> <session>/report.html
    python3 bench/report.py <session> <session> ... -o compare.html

A session folder holds what deploy/linode/bench.sh collects: runs.csv (one row
per k6 run, from bench/score.sh), summary.txt, host.csv (the server sampled
every second by deploy/host/sample-host.sh), app-stats.log (the server's 5-second
`stats` lines) and server.txt (machine and service facts). Missing files only
drop their charts. With several sessions it compares their load curves.
"""
import csv
import html
import math
import os
import re
import sys
from datetime import datetime, timezone

PALETTE = ["var(--c1)", "var(--c2)", "var(--c3)", "var(--c4)", "var(--c5)", "var(--c6)"]


# ---------- data ----------

def read_kv(path):
    out = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8", errors="replace"):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                out[k.strip()] = v.strip()
            elif line.startswith("listening"):
                out[line.split()[0].rstrip(":")] = line.strip()
    return out


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def num(v, default=None):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def read_stats(path):
    rows = []
    if os.path.exists(path):
        for line in open(path, encoding="utf-8", errors="replace"):
            if line.startswith("stats "):
                rows.append({k: num(v, 0.0) for k, v in re.findall(r"(\w+)=([-\d.]+)", line)})
    return rows


def load_session(folder):
    s = {"dir": folder, "name": os.path.basename(os.path.normpath(folder))}
    s["server"] = read_kv(os.path.join(folder, "server.txt"))
    s["runs"] = read_csv(os.path.join(folder, "runs.csv"))
    s["host"] = read_csv(os.path.join(folder, "host.csv"))
    s["storage"] = read_csv(os.path.join(folder, "storage-snapshots.csv"))
    s["stats"] = read_stats(os.path.join(folder, "app-stats.log"))
    summary = os.path.join(folder, "summary.txt")
    s["summary"] = open(summary, encoding="utf-8").read() if os.path.exists(summary) else ""
    m = re.search(r"SCORE .*?users=(\d+)", s["summary"])
    s["score"] = int(m.group(1)) if m else None
    m = re.search(r"CONNECTIONS held (\d+)", s["summary"])
    s["held"] = int(m.group(1)) if m else None
    times = [num(r["t"]) for r in s["host"] if num(r.get("t"))] + [num(r["start"]) for r in s["runs"] if num(r.get("start"))]
    s["t0"] = min(times) if times else 0
    return s


def storage_delta(rows, key):
    """Never subtract across a missing/replaced file or a process restart."""
    if len(rows) < 2 or any(not r.get("db_id") for r in rows):
        return None
    if len({r["db_id"] for r in rows}) != 1:
        return None
    generations = {(r.get("svc_pid"), r.get("svc_start_ticks")) for r in rows
                   if r.get("svc_start_ticks")}
    if len(generations) > 1:
        return None
    counter = key in ("svc_write_bytes", "svc_cancelled_write_bytes")
    if counter and any(not r.get("svc_start_ticks") for r in rows):
        return None
    values = [num(r.get(key)) for r in rows]
    if any(v is None for v in values):
        return None
    if counter and any(b < a for a, b in zip(values, values[1:])):
        return None
    return values[-1] - values[0]


def storage_window(host, start, end):
    """Use samples inside the run, and require coverage within 3 s of each edge."""
    if start is None or end is None or end <= start:
        return []
    rows = sorted((r for r in host if start <= num(r.get("t"), -1) <= end), key=lambda r: num(r["t"]))
    if len(rows) < 2 or num(rows[0]["t"]) - start > 3 or end - num(rows[-1]["t"]) > 3:
        return []
    return rows


# ---------- charts ----------

def ticks(lo, hi, n=5):
    if hi <= lo:
        hi = lo + 1
    raw = (hi - lo) / n
    step = 10 ** math.floor(math.log10(raw))
    for m in (1, 2, 2.5, 5, 10):
        if raw <= step * m:
            step *= m
            break
    v, out = math.floor(lo / step) * step, []
    while True:
        out.append(round(v, 10))
        if v >= hi - step * 1e-9:
            return out, step
        v += step


def fmt(v, step):
    if step >= 1 or v == 0:
        return f"{v:,.0f}"
    return f"{v:,.{max(0, -math.floor(math.log10(step)))}f}"


def chart(title, series, x_label, y_label, *, stacked=False, scatter=False, shade=(), hlines=(), y_min=0.0,
          width=920, height=260, note=""):
    """series: [(name, color, [(x, y), ...])]. shade: [(x0, x1, text, ok)]. hlines: [(y, text)]."""
    pts = [p for _, _, data in series for p in data if p[1] is not None]
    if not pts:
        return ""
    left, right, top, bottom = 64, 16, 30, 40
    w, h = width - left - right, height - top - bottom
    xs = [p[0] for p in pts] + [a for a, _, _, _ in shade] + [b for _, b, _, _ in shade]
    x_lo, x_hi = min(xs), max(xs)
    if stacked:
        by_x = {}
        for _, _, data in series:
            for x, y in data:
                by_x[x] = by_x.get(x, 0) + (y or 0)
        y_hi = max(by_x.values()) if by_x else 1
    else:
        y_hi = max(p[1] for p in pts)
    y_hi = max([y_hi] + [y for y, _ in hlines]) * 1.08 or 1
    xt, xstep = ticks(x_lo, x_hi, 8)
    yt, ystep = ticks(y_min, y_hi, 5)
    x_lo, x_hi = min(x_lo, xt[0]), max(x_hi, xt[-1])
    y_hi = yt[-1]
    sx = lambda x: left + (x - x_lo) / ((x_hi - x_lo) or 1) * w
    sy = lambda y: top + h - (y - y_min) / ((y_hi - y_min) or 1) * h
    o = [f'<figure class="chart"><svg viewBox="0 0 {width} {height}" role="img" aria-label="{html.escape(title)}">']
    o.append(f'<text x="{left}" y="18" class="title">{html.escape(title)}</text>')
    for x0, x1, text, ok in shade:
        o.append(f'<rect x="{sx(x0):.1f}" y="{top}" width="{max(1, sx(x1) - sx(x0)):.1f}" height="{h}" '
                 f'class="{"shade-ok" if ok else "shade-fail"}"/>')
    for y in yt:
        o.append(f'<line x1="{left}" x2="{left + w}" y1="{sy(y):.1f}" y2="{sy(y):.1f}" class="grid"/>')
        o.append(f'<text x="{left - 6}" y="{sy(y) + 4:.1f}" class="tick" text-anchor="end">{fmt(y, ystep)}</text>')
    for x in xt:
        o.append(f'<text x="{sx(x):.1f}" y="{top + h + 16}" class="tick" text-anchor="middle">{fmt(x, xstep)}</text>')
    o.append(f'<text x="{left + w / 2:.1f}" y="{height - 4}" class="axis" text-anchor="middle">{html.escape(x_label)}</text>')
    o.append(f'<text x="14" y="{top + h / 2:.1f}" class="axis" text-anchor="middle" '
             f'transform="rotate(-90 14 {top + h / 2:.1f})">{html.escape(y_label)}</text>')
    if stacked:
        base = {}
        for name, color, data in series:
            data = sorted((x, y or 0) for x, y in data)
            if not data:
                continue
            upper = [(x, base.get(x, 0) + y) for x, y in data]
            lower = [(x, base.get(x, 0)) for x, _ in reversed(data)]
            poly = " ".join(f"{sx(x):.1f},{sy(y):.1f}" for x, y in upper + lower)
            o.append(f'<polygon points="{poly}" style="fill:{color}" class="area"/>')
            for x, y in upper:
                base[x] = y
    else:
        for name, color, data in series:
            data = sorted(p for p in data if p[1] is not None)
            if scatter:
                o.append(f'<polyline points="{" ".join(f"{sx(x):.1f},{sy(y):.1f}" for x, y in data)}" '
                         f'style="stroke:{color}" class="line thin"/>')
                for x, y in data:
                    o.append(f'<circle cx="{sx(x):.1f}" cy="{sy(y):.1f}" r="4" style="fill:{color}"/>')
            elif data:
                o.append(f'<polyline points="{" ".join(f"{sx(x):.1f},{sy(y):.1f}" for x, y in data)}" '
                         f'style="stroke:{color}" class="line"/>')
    for x0, x1, text, ok in shade:  # labels above the data
        o.append(f'<text x="{(sx(x0) + sx(x1)) / 2:.1f}" y="{top + 12}" class="shade-label">{html.escape(text)}</text>')
    for y, text in hlines:
        if y <= y_hi:
            o.append(f'<line x1="{left}" x2="{left + w}" y1="{sy(y):.1f}" y2="{sy(y):.1f}" class="limit"/>')
            o.append(f'<text x="{left + w - 4}" y="{sy(y) - 4:.1f}" class="limit-label" text-anchor="end">{html.escape(text)}</text>')
    o.append('</svg><figcaption>')
    for name, color, _ in series:
        o.append(f'<span class="key"><i style="background:{color}"></i>{html.escape(name)}</span>')
    if note:
        o.append(f'<span class="note">{html.escape(note)}</span>')
    o.append('</figcaption></figure>')
    return "".join(o)


# ---------- report ----------

CSS = """
:root{--bg:#fbfbfa;--fg:#1d1d1b;--muted:#6b6b66;--line:#e3e2dd;--card:#fff;
--c1:#2f6fd6;--c2:#e0703a;--c3:#2e9e6a;--c4:#9b59c9;--c5:#c9a227;--c6:#d14d72;--ok:#2e9e6a;--fail:#d14d4d}
@media (prefers-color-scheme:dark){:root{--bg:#141413;--fg:#ecebe6;--muted:#a3a29c;--line:#34332f;--card:#1c1c1a;
--c1:#6ea2ff;--c2:#ff9a62;--c3:#4fd394;--c4:#c290ff;--c5:#f0cd55;--c6:#ff7aa0;--ok:#4fd394;--fail:#ff7070}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,Segoe UI,sans-serif}
main{max-width:980px;margin:0 auto;padding:28px 16px 64px}h1{font-size:26px;margin:0 0 4px}h2{font-size:18px;margin:36px 0 10px}
.sub{color:var(--muted);margin:0 0 20px}.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 12px}.tile b{display:block;font-size:22px;font-variant-numeric:tabular-nums}
.tile span{color:var(--muted);font-size:13px}table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums;font-size:14px;background:var(--card)}
th,td{padding:6px 8px;border-bottom:1px solid var(--line);text-align:right}th:first-child,td:first-child{text-align:left}
th{color:var(--muted);font-weight:600}.pass{color:var(--ok);font-weight:600}.fail{color:var(--fail);font-weight:600}
.chart{margin:14px 0;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:6px 8px}
.chart svg{width:100%;height:auto;display:block}.title{font-weight:600;fill:var(--fg);font-size:14px}
.tick{fill:var(--muted);font-size:11px}.axis{fill:var(--muted);font-size:12px}.grid{stroke:var(--line)}
.line{fill:none;stroke-width:1.8}.thin{stroke-width:1.2;opacity:.6}.area{opacity:.72}
.limit{stroke:var(--fail);stroke-dasharray:5 4}.limit-label{fill:var(--fail);font-size:11px}
.shade-ok{fill:var(--ok);opacity:.08}.shade-fail{fill:var(--fail);opacity:.09}.shade-label{fill:var(--fg);font-size:10px;text-anchor:middle;paint-order:stroke;stroke:var(--card);stroke-width:3px}
figcaption{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:13px;color:var(--muted);padding:2px 4px 4px}
.key i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;vertical-align:-1px}.note{margin-left:auto}
pre{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px;overflow:auto;font-size:12.5px}
a{color:var(--c1)}.wrap{overflow-x:auto}
"""


def tile(value, label):
    return f'<div class="tile"><b>{html.escape(str(value))}</b><span>{html.escape(label)}</span></div>'


def storage_report(s, shade):
    host, snapshots = s["host"], s.get("storage", [])
    if not snapshots and not any("db_apparent_bytes" in r for r in host):
        return '<h2>Database storage</h2><p class="sub">Not collected in this session. File growth and import peak RAM cannot be recovered from disk throughput.</p>'
    gib = lambda value: "—" if value is None else f"{value / 2**30:,.3f}"
    mib_delta = lambda value: "—" if value is None else f"{value / 2**20:+,.2f}"
    out = ['<h2>Database storage</h2><p class="sub">Apparent size is file length; allocated size is filesystem blocks '
           'charged to the file. Sparse copies and shared extents can change allocation without changing content. '
           'Process write bytes are cumulative I/O accounting, separate from file growth. GiB = 2³⁰ bytes; MiB = 2²⁰ bytes.</p>']
    if snapshots:
        out.append('<div class="wrap"><table><tr><th>snapshot</th><th>UTC</th><th>run apparent GiB</th>'
                   '<th>run allocated GiB</th><th>seed apparent GiB</th><th>seed allocated GiB</th><th>free GiB</th></tr>')
        for r in snapshots:
            t = num(r.get("t"))
            when = datetime.fromtimestamp(t, timezone.utc).strftime("%H:%M:%S") if t else "—"
            out.append(f'<tr><td>{html.escape(r.get("phase", "snapshot"))}</td><td>{when}</td>' + "".join(
                f'<td>{gib(num(r.get(k)))}</td>' for k in ("db_apparent_bytes", "db_allocated_bytes",
                "seed_apparent_bytes", "seed_allocated_bytes", "fs_available_bytes")) + '</tr>')
        out.append('</table></div>')
    start = next((r for r in snapshots if r.get("phase") == "session_start"), None)
    end = next((r for r in reversed(snapshots) if r.get("phase") == "session_end"), None)
    if start and end and num(start.get("t")) is not None and num(end.get("t")) is not None:
        rows = [start] + sorted((r for r in host if num(start["t"]) <= num(r.get("t"), -1) <= num(end["t"])),
                                key=lambda r: num(r["t"])) + [end]
        out.append('<div class="tiles">' +
                   tile(mib_delta(storage_delta(rows, "db_apparent_bytes")) + ' MiB', 'session apparent-size change') +
                   tile(mib_delta(storage_delta(rows, "db_allocated_bytes")) + ' MiB', 'session allocation change') +
                   tile(gib(storage_delta(rows, "svc_write_bytes")) + ' GiB', 'process write bytes during session') + '</div>')
    else:
        out.append('<p class="sub">Session growth unavailable: no complete start/end baseline.</p>')
    if host:
        col = lambda key: [((num(r["t"]) - s["t0"]) / 60, num(r[key]) / 2**30)
                           for r in host if num(r.get("t")) is not None and num(r.get(key)) is not None]
        out.append(chart("Database file size", [("apparent", PALETTE[0], col("db_apparent_bytes")),
                                                ("allocated", PALETTE[1], col("db_allocated_bytes"))],
                         "minutes", "GiB", shade=shade))
        out.append(chart("Filesystem available space", [("available", PALETTE[2], col("fs_available_bytes"))],
                         "minutes", "GiB", shade=shade, note="filesystem-wide; other files also consume this space"))
    if s["runs"]:
        out.append('<h2>Storage change by run (sampled)</h2><div class="wrap"><table><tr><th>run</th>'
                   '<th>sampled/run seconds</th><th>apparent Δ MiB</th><th>allocated Δ MiB</th>'
                   '<th>process writes GiB</th><th>cancelled writes GiB</th></tr>')
        for r in s["runs"]:
            a, b = num(r.get("start")), num(r.get("end"))
            rows = storage_window(host, a, b)
            coverage = f'{num(rows[-1]["t"]) - num(rows[0]["t"]):.0f}/{b - a:.0f}' if rows else '—'
            label = html.escape(f'{r.get("label", "")} {r.get("users", "")}')
            out.append(f'<tr><td>{label}</td><td>{coverage}</td>' +
                       f'<td>{mib_delta(storage_delta(rows, "db_apparent_bytes"))}</td>' +
                       f'<td>{mib_delta(storage_delta(rows, "db_allocated_bytes"))}</td>' +
                       f'<td>{gib(storage_delta(rows, "svc_write_bytes"))}</td>' +
                       f'<td>{gib(storage_delta(rows, "svc_cancelled_write_bytes"))}</td></tr>')
        out.append('</table></div><p class="sub">Each interval includes its ramp and hold. Samples must fall within 3 seconds '
                   'of both boundaries; the covered duration is shown. Server and k6 clocks must agree. '
                   'Missing measurements, file replacement, process restart, or decreasing I/O counters produce —. '
                   'Cancelled writes are shown separately; these counters do not measure physical-device write amplification.</p>')
    return "".join(out)


def session_report(s):
    sv, runs, host, stats, t0 = s["server"], s["runs"], s["host"], s["stats"], s["t0"]
    mins = lambda t: (t - t0) / 60.0
    shade = []
    for r in runs:
        a, b = num(r.get("start")), num(r.get("end"))
        if a and b:
            shade.append((mins(a), mins(b), f'{r["label"]} {int(num(r["users"], 0)):,}', r.get("result") == "PASS"))
    when = datetime.fromtimestamp(t0, timezone.utc).strftime("%Y-%m-%d %H:%M UTC") if t0 else ""
    head = [f'<h1>StardustDB Nanode and Linode 2GB Challenge: {html.escape(sv.get("plan", "server"))}, {html.escape(sv.get("profile", ""))}</h1>',
            f'<p class="sub">{html.escape(s["name"])} · {when} · Rust io_uring server, embedded Stardust, '
            f'k6 from {html.escape(sv.get("client_os", "the client"))}</p>']
    passed = [int(num(r["users"], 0)) for r in runs if r.get("result") == "PASS"]
    best = max(runs, key=lambda r: num(r.get("rps"), 0), default=None)
    peak_rss = max((num(r.get("svc_rss_mb"), 0) for r in host), default=0)
    steal = [num(r.get("cpu_steal"), 0) for r in host]
    conns = max((num(r.get("conns"), 0) for r in stats), default=0)
    if s["held"] is not None:
        first = [tile(f'{s["held"]:,}', "connections held (5-min hold)"), tile(f"{conns:,.0f}", "open connections peak")]
    else:
        first = [tile(f'{s["score"]:,} users' if s["score"] is not None else (f"{max(passed):,} users" if passed else "—"),
                      "score (5-min hold)" if s["score"] is not None else "highest passing run")]
    tiles = [*first,
             tile(f'{num(best["rps"], 0):,.0f} req/s' if best else "—", "best run throughput"),
             tile(f"{peak_rss:,.0f} MB", "server RSS peak"),
             tile(f"{max(steal):.1f}%" if steal else "—", "CPU steal peak"),
             tile(sv.get("vcpus", "?") + " vCPU", sv.get("plan_cpu", "")[:40] or "CPU"),
             tile(sv.get("service_LimitNOFILE", "?"), "service LimitNOFILE")]
    out = head + ['<div class="tiles">', *tiles, '</div>']

    if runs:
        out.append("<h2>Load and latency</h2>")
        by = lambda key, pred=lambda r: True: [(num(r["users"]), num(r.get(key))) for r in runs if pred(r)]
        out.append(chart("Latency against users (each k6 run)",
                         [("p95", PALETTE[0], by("p95_ms")), ("p99", PALETTE[1], by("p99_ms"))],
                         "virtual users", "ms", scatter=True, hlines=[(500, "p95 limit 500 ms"), (1000, "p99 limit 1 s")]))
        out.append(chart("Throughput against users", [("requests/s", PALETTE[2], by("rps"))],
                         "virtual users", "requests/s", scatter=True))
        out.append(chart("Errors against users", [("errors %", PALETTE[5], by("errors_pct"))],
                         "virtual users", "% of requests", scatter=True, hlines=[(1, "limit 1%")]))
        if any(num(r.get("client_rx_kbps")) for r in runs):
            out.append(chart("Client download (k6 data received, whole run)",
                             [("Mbit/s", PALETTE[3], [(u, (v or 0) / 1000) for u, v in by("client_rx_kbps")])],
                             "virtual users", "Mbit/s", scatter=True,
                             note="flat while latency climbs: the client link, not the server, is the limit"))
        rows = ["<div class='wrap'><table><tr><th>run</th><th>users</th><th>hold</th><th>result</th><th>p95 ms</th>"
                "<th>p99 ms</th><th>errors %</th><th>requests</th><th>req/s</th><th>k6 dashboard</th></tr>"]
        for r in runs:
            dash = f'{r["label"]}-{r["users"]}.html'
            link = f'<a href="{html.escape(dash)}">open</a>' if os.path.exists(os.path.join(s["dir"], dash)) else ""
            cls = "pass" if r.get("result") == "PASS" else "fail"
            rows.append(f'<tr><td>{html.escape(r["label"])}</td><td>{int(num(r["users"], 0)):,}</td><td>{html.escape(r["hold"])}</td>'
                        f'<td class="{cls}">{html.escape(r["result"])}</td><td>{num(r.get("p95_ms"), 0):,.1f}</td>'
                        f'<td>{num(r.get("p99_ms"), 0):,.1f}</td><td>{num(r.get("errors_pct"), 0):.2f}</td>'
                        f'<td>{int(num(r.get("requests"), 0)):,}</td><td>{num(r.get("rps"), 0):,.0f}</td><td>{link}</td></tr>')
        out.append("".join(rows) + "</table></div>")

    if host:
        out.append("<h2>Server: system, sampled every second</h2>")
        col = lambda key, scale=1.0: [(mins(num(r["t"])), num(r.get(key), 0) * scale) for r in host if num(r.get("t"))]
        out.append(chart("CPU", [("user", PALETTE[0], col("cpu_user")), ("system", PALETTE[1], col("cpu_system")),
                                 ("softirq", PALETTE[3], col("cpu_softirq")), ("steal", PALETTE[5], col("cpu_steal"))],
                         "minutes", "% of CPU time", stacked=True, shade=shade,
                         note="steal: time the hypervisor gave to other tenants. iowait is left out: Linux 6.8 counts "
                              "a thread waiting in io_uring_enter as iowait, so here it is idle time."))
        out.append(chart("Memory", [("service RSS", PALETTE[0], col("svc_rss_mb")), ("page cache", PALETTE[2], col("mem_cached_mb")),
                                    ("available", PALETTE[4], col("mem_available_mb"))],
                         "minutes", "MB", shade=shade))
        out.append(chart("Network", [("in", PALETTE[0], col("net_rx_kbps", 1 / 1000)), ("out", PALETTE[1], col("net_tx_kbps", 1 / 1000))],
                         "minutes", "Mbit/s", shade=shade))
        out.append(chart("Disk", [("read", PALETTE[2], col("disk_read_kbs", 1 / 1024)), ("write", PALETTE[1], col("disk_write_kbs", 1 / 1024))],
                         "minutes", "MB/s", shade=shade, note="writes: Stardust commits and page writeback"))
        out.append(chart("TCP sockets", [("sockets in use", PALETTE[0], col("tcp_inuse")), ("TIME_WAIT", PALETTE[4], col("tcp_tw"))],
                         "minutes", "sockets", shade=shade))
        out.append(chart("Load average (1 min)", [("load1", PALETTE[3], col("load1"))], "minutes", "runnable tasks", shade=shade))

    out.append(storage_report(s, shade))

    if stats:
        out.append("<h2>Server: Rust io_uring + Stardust, 5-second stats</h2>")
        st = lambda f: [(mins(r["t"] - r.get("interval_s", 5) / 2), f(r)) for r in stats]
        per_s = lambda key: st(lambda r: r.get(key, 0) / (r.get("interval_s") or 5))
        out.append(chart("Requests served", [("GET /feed", PALETTE[0], per_s("feed")), ("GET /posts/:id", PALETTE[2], per_s("post")),
                                             ("writes", PALETTE[1], per_s("writes")), ("other", PALETTE[4], per_s("other"))],
                         "minutes", "requests/s", shade=shade))
        out.append(chart("Read service time (Stardust queries included)",
                         [("average", PALETTE[0], st(lambda r: r.get("read_avg_us", 0) / 1000)),
                          ("max", PALETTE[1], st(lambda r: r.get("read_max_us", 0) / 1000))],
                         "minutes", "ms", shade=shade, note="a feed is 41 queries; a post is 2"))
        out.append(chart("Stardust group commit: time per round",
                         [("average", PALETTE[2], st(lambda r: r.get("commit_avg_ms", 0) if r.get("rounds") else None)),
                          ("max", PALETTE[1], st(lambda r: r.get("commit_max_ms", 0) if r.get("rounds") else None))],
                         "minutes", "ms", shade=shade, note="durable merge_patch: the sync dominates"))
        out.append(chart("Stardust group commit: writes per round",
                         [("batch", PALETTE[3], st(lambda r: r.get("batch", 0) if r.get("rounds") else None))],
                         "minutes", "writes", shade=shade))
        out.append(chart("Open connections", [("connections", PALETTE[0], st(lambda r: r.get("conns", 0)))],
                         "minutes", "connections", shade=shade))

    facts = {k: v for k, v in sv.items()}
    if facts:
        out.append("<h2>Setup</h2><div class='wrap'><table>")
        for k, v in facts.items():
            out.append(f"<tr><td>{html.escape(k)}</td><td style='text-align:left'>{html.escape(v)}</td></tr>")
        out.append("</table></div>")
    if s["summary"]:
        out.append(f"<h2>score.sh log</h2><pre>{html.escape(s['summary'])}</pre>")
    out.append('<p class="sub">How to read this: k6 runs on the client, so every latency includes the network round '
               'trip to the server. Shaded bands mark k6 runs (green: passed p95 &lt; 500 ms, p99 &lt; 1 s, errors &lt; 1%). '
               'Generated by bench/report.py.</p>')
    return "".join(out)


def compare_report(sessions):
    out = ["<h1>StardustDB Nanode and Linode 2GB Challenge: comparison</h1>", f'<p class="sub">{len(sessions)} sessions</p>',
           "<div class='wrap'><table><tr><th>session</th><th>plan</th><th>profile</th><th>score</th><th>best req/s</th><th>runs</th></tr>"]
    for s in sessions:
        sv = s["server"]
        best = max((num(r.get("rps"), 0) for r in s["runs"]), default=0)
        score = f'{s["score"]:,}' if s["score"] is not None else "—"
        out.append(f'<tr><td><a href="{html.escape(os.path.relpath(os.path.join(s["dir"], "report.html")))}">{html.escape(s["name"])}</a></td>'
                   f'<td>{html.escape(sv.get("plan", ""))}</td><td>{html.escape(sv.get("profile", ""))}</td><td>{score}</td>'
                   f'<td>{best:,.0f}</td><td>{len(s["runs"])}</td></tr>')
    out.append("</table></div>")
    label = lambda s: f'{s["server"].get("plan", s["name"])} {s["server"].get("profile", "")}'.strip()
    pts = lambda s, key: [(num(r["users"]), num(r.get(key))) for r in s["runs"]]
    out.append(chart("p95 latency against users", [(label(s), PALETTE[i % 6], pts(s, "p95_ms")) for i, s in enumerate(sessions)],
                     "virtual users", "ms", scatter=True, hlines=[(500, "p95 limit 500 ms")]))
    out.append(chart("p99 latency against users", [(label(s), PALETTE[i % 6], pts(s, "p99_ms")) for i, s in enumerate(sessions)],
                     "virtual users", "ms", scatter=True, hlines=[(1000, "p99 limit 1 s")]))
    out.append(chart("Throughput against users", [(label(s), PALETTE[i % 6], pts(s, "rps")) for i, s in enumerate(sessions)],
                     "virtual users", "requests/s", scatter=True))
    return "".join(out)


def page(title, body):
    return (f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" '
            f'content="width=device-width,initial-scale=1"><title>{html.escape(title)}</title><style>{CSS}</style></head>'
            f"<body><main>{body}</main></body></html>")


def main(argv):
    args, out_path = [], None
    it = iter(argv)
    for a in it:
        if a in ("-o", "--out"):
            out_path = next(it)
        else:
            args.append(a)
    if not args:
        sys.exit(__doc__)
    sessions = [load_session(d) for d in args]
    if len(sessions) == 1:
        s = sessions[0]
        path = out_path or os.path.join(s["dir"], "report.html")
        open(path, "w", encoding="utf-8").write(page(f'Bench report: {s["name"]}', session_report(s)))
    else:
        path = out_path or "compare.html"
        open(path, "w", encoding="utf-8").write(page("Bench comparison", compare_report(sessions)))
    print(path)


if __name__ == "__main__":
    main(sys.argv[1:])
