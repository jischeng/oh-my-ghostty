//! Deployment uses exact system-SSH arguments and bundled, hash-verified artifacts.
use crate::lifecycle::Policy;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::mpsc,
    time::{Duration, Instant},
};
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Connection {
    pub executable: String,
    pub arguments: Vec<String>,
    pub cwd: String,
    pub bundle: PathBuf,
    pub policy: Policy,
    pub revision: Option<String>,
    #[serde(default)]
    pub hooks: Option<String>,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Manifest {
    pub revision: String,
    pub platform: String,
    pub files: Vec<Artifact>,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Artifact {
    pub name: String,
    pub sha256: String,
}
fn valid_component(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}
pub fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
fn ssh(config: &Connection, script: &str) -> io::Result<Command> {
    if !config.executable.starts_with('/')
        || config.arguments.is_empty()
        || config.arguments.iter().any(|s| s.contains('\0'))
    {
        return Err(io::Error::other("invalid SSH connection"));
    }
    let mut c = Command::new(&config.executable);
    c.current_dir(&config.cwd)
        .args(&config.arguments)
        .arg(format!("exec /bin/sh -c {}", quote(script)))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    Ok(c)
}
fn run(config: &Connection, script: &str, input: Option<&[u8]>) -> io::Result<Vec<u8>> {
    execute(
        ssh(config, script)?,
        std::io::Cursor::new(input.unwrap_or_default().to_vec()),
    )
}
fn execute(mut command: Command, mut input: impl Read + Send + 'static) -> io::Result<Vec<u8>> {
    let mut child = command.spawn()?;
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = child.stdout.take().unwrap();
    let (tx, rx) = mpsc::channel();
    let writer = std::thread::spawn(move || io::copy(&mut input, &mut stdin));
    let reader = std::thread::spawn(move || {
        let mut output = Vec::new();
        let result = stdout.by_ref().take(64 * 1024 + 1).read_to_end(&mut output);
        let result = result.and_then(|_| {
            if output.len() > 64 * 1024 {
                Err(io::Error::other("SSH setup output exceeded limit"))
            } else {
                Ok(output)
            }
        });
        let _ = tx.send(result);
    });
    let deadline = Instant::now() + Duration::from_secs(120);
    let mut output = None;
    let result = loop {
        if let Ok(received) = rx.try_recv() {
            match received {
                Ok(bytes) => output = Some(bytes),
                Err(error) => break Err(error),
            }
        }
        if let Some(status) = child.try_wait()? {
            if !status.success() {
                break Err(io::Error::other("SSH runtime setup failed; check authentication, platform and remote permissions"));
            }
            if let Some(bytes) = output.take() {
                break Ok(bytes);
            }
        }
        if Instant::now() >= deadline {
            break Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "SSH runtime setup timed out",
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    if result.is_err() {
        let _ = child.kill();
    }
    let _ = child.wait();
    let write_result = writer
        .join()
        .map_err(|_| io::Error::other("SSH upload thread failed"))?;
    let _ = reader.join();
    let bytes = result?;
    write_result?;
    Ok(bytes)
}
/// Probe has no writes. Hosts without a conventional shell/tar/sha256 tool fail
/// explicitly; there is never a fallback pretending to be a durable session.
pub fn prepare(config: &Connection) -> io::Result<(String, String)> {
    config.policy.validate()?;
    let probe=run(config,"printf '\\nOMG_RUNTIME_PROBE\\n'; uname -s; uname -m; printf '%s\\n' \"$HOME\"; command -v tar >/dev/null",None)?;
    let text = String::from_utf8(probe).map_err(io::Error::other)?;
    let mut lines = text
        .split("OMG_RUNTIME_PROBE\n")
        .nth(1)
        .ok_or_else(|| io::Error::other("missing remote probe"))?
        .lines();
    let os = lines.next().unwrap_or("");
    let arch = lines.next().unwrap_or("");
    let home = lines.next().unwrap_or("");
    if !home.starts_with('/') || home.contains('\0') || home.len() > 1024 {
        return Err(io::Error::other("invalid remote home"));
    }
    let platform = match (os, arch) {
        ("Linux", "x86_64") => "linux-x86_64",
        ("Linux", "aarch64" | "arm64") => "linux-aarch64",
        ("Darwin", "arm64") => "macos-aarch64",
        ("Darwin", "x86_64") => "macos-x86_64",
        _ => {
            return Err(io::Error::other(format!(
                "unsupported SSH host {os}/{arch}"
            )))
        }
    };
    let local = config.bundle.join(platform);
    let manifest: Manifest = serde_json::from_slice(&fs::read(local.join("manifest.json"))?)?;
    if manifest.platform != platform
        || !valid_component(&manifest.revision)
        || config
            .revision
            .as_ref()
            .is_some_and(|r| r != &manifest.revision)
    {
        return Err(io::Error::other(
            "runtime revision unavailable; retain the original version to resume its sessions",
        ));
    }
    if manifest.files.is_empty()
        || manifest.files.iter().any(|f| {
            !valid_component(&f.name)
                || f.name.starts_with('.')
                || f.sha256.len() != 64
                || !f.sha256.bytes().all(|b| b.is_ascii_hexdigit())
        })
    {
        return Err(io::Error::other("invalid runtime artifact manifest"));
    }
    // Local hashes are checked before upload. The manifest is part of the signed
    // app bundle, never downloaded from an unauthenticated remote endpoint.
    for f in &manifest.files {
        let result = Command::new("/usr/bin/shasum")
            .args(["-a", "256"])
            .arg(local.join(&f.name))
            .output()?;
        if !result.status.success()
            || !String::from_utf8_lossy(&result.stdout).starts_with(&f.sha256)
        {
            return Err(io::Error::other("runtime artifact checksum mismatch"));
        }
    }
    let root = format!("{home}/.local/share/oh-my-ghostty/session-runtime");
    let version = format!("{root}/versions/{}", manifest.revision);
    use sha2::{Digest, Sha256};
    let key = format!("{:x}", Sha256::digest(manifest.revision.as_bytes()));
    // Unix socket paths on macOS are limited to about 104 bytes. Keep runtime
    // sockets short; versioned binaries can remain in the descriptive directory.
    let state = format!("{home}/.omg/run/{}", &key[..12]);
    let exists = run(
        config,
        &format!(
            "if [ -x {v}/omgd ] && [ -f {v}/verified ]; then printf 'OMG_PRESENT'; fi",
            v = quote(&version)
        ),
        None,
    )?;
    if !exists.ends_with(b"OMG_PRESENT") {
        let nonce = crate::record::nonce()?;
        let staging = format!("{root}/.upload-{nonce}");
        let checks = manifest
            .files
            .iter()
            .map(|f| format!("{}  {}", f.sha256, f.name))
            .collect::<Vec<_>>()
            .join("\n");
        let script = format!(
            r#"set -eu
umask 077
root={root}; version={version}; staging={staging}
mkdir -p "$root/versions" "$root/runs"
[ ! -L "$root" ] && [ -O "$root" ] || exit 1
chmod 700 "$root" "$root/versions" "$root/runs"
mkdir "$staging"
trap 'rm -rf "$staging"' EXIT HUP INT TERM
tar -xf - -C "$staging"
cd "$staging"
printf '%s\n' {checks} > checksums
if command -v sha256sum >/dev/null 2>&1; then sha256sum -c checksums >/dev/null
elif command -v shasum >/dev/null 2>&1; then shasum -a 256 -c checksums >/dev/null
else echo 'No SHA-256 verifier on remote host' >&2; exit 1; fi
chmod 700 omgd
./omgd version >/dev/null
printf '%s\n' {revision} > verified
if [ ! -d "$version" ]; then mv "$staging" "$version"; fi
"#,
            root = quote(&root),
            version = quote(&version),
            staging = quote(&staging),
            checks = quote(&checks),
            revision = quote(&manifest.revision)
        );
        let archive = std::env::temp_dir().join(format!("omg-runtime-{nonce}.tar"));
        let mut tar = Command::new("/usr/bin/tar");
        tar.env("COPYFILE_DISABLE", "1")
            .arg("--no-xattrs")
            .arg("-cf")
            .arg(&archive)
            .arg("-C")
            .arg(&local);
        for f in &manifest.files {
            tar.arg(&f.name);
        }
        if !tar.status()?.success() {
            return Err(io::Error::other("cannot package runtime"));
        }
        let result = execute(ssh(config, &script)?, fs::File::open(&archive)?);
        let _ = fs::remove_file(archive);
        result?;
    }
    if let Some(hooks) = &config.hooks {
        if hooks.len() > 1024 * 1024 {
            return Err(io::Error::other("Agent hook installer too large"));
        }
        let available = run(
            config,
            "if command -v python3 >/dev/null 2>&1; then printf PYTHON; fi",
            None,
        )?;
        if available.ends_with(b"PYTHON") {
            run(config, "exec python3 -", Some(hooks.as_bytes()))?;
        } else if config.policy.close_on_agent_done {
            return Err(io::Error::other(
                "Agent completion cleanup requires remote Python 3 for hooks",
            ));
        }
    }
    let policy = serde_json::to_string(&config.policy)?;
    // Policy updates are atomic. Existing sessions retain their policy snapshot;
    // the host reloads the file for newly created sessions without restarting.
    let setup = format!(
        r#"set -eu
umask 077
mkdir -p {state}
[ ! -L {state} ] && [ -O {state} ] || exit 1
chmod 700 {state}
policy_tmp={state}/policy.$$.new
printf '%s\n' {policy} > "$policy_tmp"
mv "$policy_tmp" {state}/policy.json
{binary} ensure-host {state}
printf '\nOMG_RUNTIME_READY\n'
"#,
        state = quote(&state),
        policy = quote(&policy),
        binary = quote(&format!("{version}/omgd"))
    );
    let out = run(config, &setup, None)?;
    if !out.ends_with(b"OMG_RUNTIME_READY\n") {
        return Err(io::Error::other("remote daemon not ready"));
    }
    Ok((format!("{version}/omgd"), state))
}
pub fn command(config: &Connection, binary: &str, state: &str) -> io::Result<Command> {
    ssh(
        config,
        &format!(
            "exec {} bridge {}",
            quote(binary),
            quote(&format!("{state}/host.sock"))
        ),
    )
}
pub fn load(path: &Path) -> io::Result<Connection> {
    let data = fs::read(path)?;
    if data.len() > 2 * 1024 * 1024 {
        return Err(io::Error::other("connection config too large"));
    }
    Ok(serde_json::from_slice(&data)?)
}
