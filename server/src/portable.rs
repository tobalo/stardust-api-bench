//! A thread-per-connection server for platforms without io_uring (local runs
//! on macOS) and for `--portable` on Linux. It shares parsing, routing and the
//! writer with the io_uring server; it is for correctness checks, not for
//! scoring.
use crate::{App, DEFER, Parsed, error, frame};
use std::{
    io::{self, Read, Write},
    net::{TcpListener, TcpStream},
    sync::{Arc, Mutex, mpsc},
};

pub fn run(address: &str, app: App) -> io::Result<()> {
    let listener = TcpListener::bind(address)?;
    eprintln!("listening {address}; portable thread-per-connection server; Stardust");
    let app = Arc::new(Mutex::new(app));
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let app = Arc::clone(&app);
        std::thread::Builder::new()
            .stack_size(256 * 1024)
            .spawn(move || {
                use std::sync::atomic::Ordering::Relaxed;
                crate::stats::STATS.connections.fetch_add(1, Relaxed);
                let _ = connection(stream, &app);
                crate::stats::STATS.connections.fetch_sub(1, Relaxed);
            })?;
    }
    Ok(())
}

fn connection(mut stream: TcpStream, app: &Mutex<App>) -> io::Result<()> {
    stream.set_nodelay(true)?;
    let mut input = Vec::with_capacity(16384);
    let mut chunk = [0u8; 16384];
    let mut body = Vec::with_capacity(16384);
    let mut out = Vec::with_capacity(16384);
    let mut continued = false;
    loop {
        loop {
            let (status, close, consumed) = match frame(&input) {
                Ok(Parsed::Complete(req)) => {
                    continued = false;
                    body.clear();
                    let mut app = app.lock().unwrap();
                    let mut status = app.serve(&req, &mut body);
                    if status == DEFER {
                        let (tx, rx) = mpsc::sync_channel(1);
                        app.defer(Box::new(move |status, reply| {
                            let _ = tx.send((status, reply));
                        }));
                        drop(app);
                        (status, body) = rx.recv().map_err(io::Error::other)?;
                    }
                    (status, req.close, req.consumed)
                }
                Ok(Parsed::Incomplete { expect_continue }) => {
                    if expect_continue && !continued {
                        stream.write_all(b"HTTP/1.1 100 Continue\r\n\r\n")?;
                        continued = true;
                    }
                    break;
                }
                Err(()) => {
                    body.clear();
                    error(&mut body, 400, "malformed request");
                    (400, true, input.len())
                }
            };
            response(status, &body, close, &mut out);
            stream.write_all(&out)?;
            out.clear();
            input.drain(..consumed);
            if close {
                return Ok(());
            }
        }
        let n = stream.read(&mut chunk)?;
        if n == 0 {
            return Ok(());
        }
        input.extend_from_slice(&chunk[..n]);
    }
}

fn response(status: u16, body: &[u8], close: bool, out: &mut Vec<u8>) {
    out.extend_from_slice(match status {
        200 => b"HTTP/1.1 200 OK\r\n",
        201 => b"HTTP/1.1 201 Created\r\n",
        400 => b"HTTP/1.1 400 Bad Request\r\n",
        401 => b"HTTP/1.1 401 Unauthorized\r\n",
        404 => b"HTTP/1.1 404 Not Found\r\n",
        503 => b"HTTP/1.1 503 Service Unavailable\r\n",
        _ => b"HTTP/1.1 500 Internal Server Error\r\n",
    });
    out.extend_from_slice(b"Content-Type: application/json\r\nContent-Length: ");
    out.extend_from_slice(itoa::Buffer::new().format(body.len()).as_bytes());
    out.extend_from_slice(if close { b"\r\nConnection: close\r\n\r\n" } else { b"\r\n\r\n" });
    out.extend_from_slice(body);
}
