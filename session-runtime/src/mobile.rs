//! Authenticated LAN transport for existing runtime sockets; never owns a PTY.
//! Handshake token selection and WebSocket/Unix splice adapted from Termio
//! 819658751635eb298a467f4d84e793729c5242bc, termiod/src/wss.rs (MIT).
//! See LICENSE.termio and THIRD-PARTY-NOTICES.
use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    fs, io,
    net::{IpAddr, SocketAddr},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::tungstenite::{
    handshake::server::{ErrorResponse, Request, Response},
    http::{HeaderValue, StatusCode},
    protocol::WebSocketConfig,
    Message,
};

mod control;
const PREFIX: &str = "omg.";
const HELP: &str = "\
Usage: omgd mobile [--listen IP:PORT] [--app-support PATH | --socket PATH]
                   --token-file PATH [--allow-origin ORIGIN] [--print-invite]

Listens on loopback by default. For LAN use, choose the Mac's LAN IP explicitly.
The private token file is created once and reused. Restart after rotating it.
Explicit phone controls can create/close sessions and access selected projects.
The gateway is independent of the Mac app. Stop it to disable mobile access.
--print-invite prints a private omg://device pairing link without starting a listener.
";

#[derive(Clone, Serialize)]
struct Endpoint {
    id: String,
    name: String,
    #[serde(skip)]
    socket: PathBuf,
}

struct Config {
    endpoints: Vec<Endpoint>,
    support: Option<PathBuf>,
    token: String,
    origin: Option<String>,
    control: control::State,
}
enum Route {
    Catalogue,
    Control,
    Session(PathBuf),
}
impl Config {
    fn endpoints(&self) -> io::Result<Vec<Endpoint>> {
        if let Some(support) = &self.support {
            targets(super::session_cli::mobile_targets(support)?)
        } else {
            Ok(self.endpoints.clone())
        }
    }
}

fn targets(values: Vec<(String, PathBuf)>) -> io::Result<Vec<Endpoint>> {
    values
        .into_iter()
        .map(|(name, socket)| {
            let parent = socket
                .parent()
                .ok_or_else(|| io::Error::other("Socket must have a private parent"))?;
            private(parent, true)?;
            let meta = fs::symlink_metadata(&socket)?;
            if meta.uid() != unsafe { libc::geteuid() } || meta.file_type().is_symlink() {
                return Err(io::Error::other(
                    "Runtime socket has an invalid owner or type",
                ));
            }
            Ok(Endpoint {
                id: format!("{:x}", Sha256::digest(socket.to_string_lossy().as_bytes())),
                name,
                socket,
            })
        })
        .collect()
}

fn private(path: &Path, directory: bool) -> io::Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o077 != 0
        || if directory {
            !meta.is_dir()
        } else {
            !meta.is_file()
        }
    {
        return Err(io::Error::other(
            "Path must be private and owned by the current user",
        ));
    }
    Ok(())
}

fn token(path: &Path) -> io::Result<String> {
    if !path.exists() {
        use std::io::Write;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)?;
        writeln!(
            file,
            "{}{}",
            omg_session_runtime::record::nonce()?,
            omg_session_runtime::record::nonce()?
        )?;
    }
    private(path, false)?;
    let value = fs::read_to_string(path)?;
    let value = value.trim();
    if value.len() < 32 || value.len() > 256 || !value.bytes().all(|c| c.is_ascii_alphanumeric()) {
        return Err(io::Error::other(
            "Token must contain 32–256 ASCII letters or digits",
        ));
    }
    Ok(value.into())
}

// From Termio's wss.rs: the secret travels in a subprotocol, not a logged URL.
fn select_subprotocol(offered: Option<&str>, expected: &str) -> Option<String> {
    offered?
        .split(',')
        .map(str::trim)
        .find(|entry| {
            entry.strip_prefix(PREFIX).is_some_and(|candidate| {
                candidate.len() == expected.len()
                    && candidate
                        .bytes()
                        .zip(expected.bytes())
                        .fold(0u8, |d, (a, b)| d | a ^ b)
                        == 0
            })
        })
        .map(str::to_owned)
}

pub fn run(args: &[String]) -> io::Result<()> {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("{HELP}");
        return Ok(());
    }
    let (mut listen, mut support, mut socket, mut key, mut origin) =
        ("127.0.0.1:8791".to_owned(), None, None, None, None);
    let mut print_invite = false;
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        if arg == "--print-invite" {
            print_invite = true;
            continue;
        }
        let value = args
            .next()
            .ok_or_else(|| io::Error::other("Missing option value"))?;
        match arg.as_str() {
            "--listen" => listen = value.clone(),
            "--app-support" => support = Some(PathBuf::from(value)),
            "--socket" => socket = Some(PathBuf::from(value)),
            "--token-file" => key = Some(PathBuf::from(value)),
            "--allow-origin" => origin = Some(value.clone()),
            _ => return Err(io::Error::other(format!("Unknown option: {arg}"))),
        }
    }
    let address: SocketAddr = listen.parse().map_err(io::Error::other)?;
    if address.ip().is_unspecified() || address.ip().is_multicast() {
        return Err(io::Error::other(
            "Choose a specific loopback or LAN address",
        ));
    }
    if let IpAddr::V4(ip) = address.ip() {
        if !ip.is_loopback() && !ip.is_private() && !ip.is_link_local() {
            return Err(io::Error::other("The first mobile transport is LAN-only"));
        }
    } else if !address.ip().is_loopback() {
        return Err(io::Error::other("Use an IPv4 LAN address or loopback"));
    }
    if support.is_some() && socket.is_some() {
        return Err(io::Error::other("--app-support and --socket are exclusive"));
    }
    let endpoints = if let Some(socket) = socket {
        targets(vec![("This Mac".into(), socket)])?
    } else {
        support = Some(
            support
                .map(Ok)
                .unwrap_or_else(super::session_cli::default_support)?,
        );
        Vec::new()
    };
    let key = key.ok_or_else(|| io::Error::other("--token-file is required"))?;
    let config = Arc::new(Config {
        endpoints,
        support,
        token: token(&key)?,
        origin,
        control: control::State::default(),
    });
    if print_invite {
        if address.port() == 0 {
            return Err(io::Error::other("Choose a fixed port for pairing"));
        }
        println!("omg://device?url=ws://{address}&token={}", config.token);
        return Ok(());
    }
    tokio::runtime::Runtime::new()?.block_on(async move {
        let listener = tokio::net::TcpListener::bind(address).await?;
        eprintln!(
            "OMG mobile listening on ws://{}/catalogue",
            listener.local_addr()?
        );
        eprintln!("Pairing token file: {}", key.display());
        let permits = Arc::new(tokio::sync::Semaphore::new(16));
        loop {
            let (stream, _) = listener.accept().await?;
            let Ok(permit) = permits.clone().try_acquire_owned() else {
                continue;
            };
            let config = config.clone();
            tokio::spawn(async move {
                let _permit = permit;
                if let Err(error) = serve(stream, config).await {
                    eprintln!("OMG mobile connection ended: {error}");
                }
            });
        }
    })
}

async fn serve(stream: tokio::net::TcpStream, config: Arc<Config>) -> io::Result<()> {
    let endpoints = config.endpoints()?;
    let destinations = endpoints.clone();
    let key = config.token.clone();
    let allowed_origin = config.origin.clone();
    let (tx, rx) = tokio::sync::oneshot::channel();
    let mut tx = Some(tx);
    let handshake = tokio_tungstenite::accept_hdr_async_with_config(
        stream,
        #[allow(clippy::result_large_err)]
        move |request: &Request, mut response: Response| {
            let refuse = |status| {
                let mut response = ErrorResponse::new(None);
                *response.status_mut() = status;
                response
            };
            let selected = select_subprotocol(
                request
                    .headers()
                    .get("sec-websocket-protocol")
                    .and_then(|v| v.to_str().ok()),
                &key,
            )
            .ok_or_else(|| refuse(StatusCode::UNAUTHORIZED))?;
            // Native clients send no Origin. Browser clients must be explicitly allowed.
            if let Some(origin) = request.headers().get("origin") {
                if origin.to_str().ok() != allowed_origin.as_deref() {
                    return Err(refuse(StatusCode::FORBIDDEN));
                }
            }
            let destination = if request.uri().path() == "/catalogue" {
                Route::Catalogue
            } else if request.uri().path() == "/control" {
                Route::Control
            } else {
                let id = request
                    .uri()
                    .path()
                    .strip_prefix("/ws/")
                    .ok_or_else(|| refuse(StatusCode::NOT_FOUND))?;
                Route::Session(
                    destinations
                        .iter()
                        .find(|e| e.id == id)
                        .ok_or_else(|| refuse(StatusCode::NOT_FOUND))?
                        .socket
                        .clone(),
                )
            };
            response.headers_mut().insert(
                "sec-websocket-protocol",
                HeaderValue::from_str(&selected).map_err(|_| refuse(StatusCode::BAD_REQUEST))?,
            );
            if let Some(tx) = tx.take() {
                let _ = tx.send(destination);
            }
            Ok(response)
        },
        Some(
            WebSocketConfig::default()
                .max_message_size(Some(omg_session_runtime::MAX_FRAME))
                .max_frame_size(Some(omg_session_runtime::MAX_FRAME)),
        ),
    );
    let mut ws = tokio::time::timeout(Duration::from_secs(10), handshake)
        .await
        .map_err(io::Error::other)?
        .map_err(io::Error::other)?;
    let destination = rx.await.map_err(io::Error::other)?;
    let destination = match destination {
        Route::Control => return control::serve(ws, config).await,
        Route::Catalogue => {
            ws.send(Message::Text(
                serde_json::json!({"endpoints": endpoints})
                    .to_string()
                    .into(),
            ))
            .await
            .map_err(io::Error::other)?;
            return ws.close(None).await.map_err(io::Error::other);
        }
        Route::Session(path) => path,
    };
    // Adapted from Termio's splice. WebSocket messages are transport chunks,
    // never assumed to coincide with OMG's framed messages.
    let daemon = tokio::net::UnixStream::connect(destination).await?;
    let (mut read, mut write) = daemon.into_split();
    let mut buffer = vec![0u8; 64 * 1024];
    let mut ping = tokio::time::interval(Duration::from_secs(15));
    ping.tick().await;
    let mut awaiting_pong = false;
    loop {
        tokio::select! {
            incoming = ws.next() => match incoming {
                Some(Ok(Message::Binary(bytes))) => {
                    tokio::time::timeout(Duration::from_secs(10), write.write_all(&bytes))
                        .await.map_err(io::Error::other)??;
                }
                Some(Ok(Message::Pong(_))) => awaiting_pong = false,
                Some(Ok(Message::Ping(_))) => { ws.flush().await.map_err(io::Error::other)?; }
                Some(Ok(Message::Frame(_))) => {},
                _ => break,
            },
            result = read.read(&mut buffer) => {
                let count = result?;
                if count == 0 { break; }
                tokio::time::timeout(Duration::from_secs(10),
                    ws.send(Message::Binary(buffer[..count].to_vec().into())))
                    .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
            },
            _ = ping.tick() => {
                if awaiting_pong { break; }
                awaiting_pong = true;
                tokio::time::timeout(Duration::from_secs(10), ws.send(Message::Ping(Vec::new().into())))
                    .await.map_err(io::Error::other)?.map_err(io::Error::other)?;
            }
        }
    }
    let _ = write.shutdown().await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn token_requires_exact_prefix_and_value() {
        assert_eq!(
            select_subprotocol(Some("other, omg.secret"), "secret"),
            Some("omg.secret".into())
        );
        assert!(select_subprotocol(Some("omg.secreu"), "secret").is_none());
        assert!(select_subprotocol(Some("termiod.secret"), "secret").is_none());
    }
}
