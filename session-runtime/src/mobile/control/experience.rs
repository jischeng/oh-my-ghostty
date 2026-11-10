use super::*;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};

#[derive(Serialize, Deserialize)]
struct SavedProject {
    id: String,
    workspace: String,
    host: String,
    path: PathBuf,
    name: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(super) struct RememberedSshHost {
    pub alias: String,
    pub host_name: String,
    #[serde(default)]
    pub user: String,
    #[serde(default = "default_ssh_port")]
    pub port: u16,
    #[serde(default)]
    pub options: Vec<String>,
}

fn default_ssh_port() -> u16 {
    22
}

const REMOTE_PYTHON_SCRIPT: &str = r#"
import base64, errno, json, os, subprocess, sys

req = json.loads(sys.stdin.read())
op = req.get("op", "")
limit = int(req.get("limit", 1048576))
raw_root = req.get("root", "") or "~"
expanded = os.path.expanduser(raw_root)
if not os.path.exists(expanded) and op == "directories":
    expanded = os.path.expanduser("~")
root = os.path.realpath(expanded)

if op != "directories" and raw_root not in ("", "~"):
    cur = root
    home_real = os.path.realpath(os.path.expanduser("~"))
    while cur and cur != "/" and cur != home_real:
        if os.path.exists(os.path.join(cur, ".git")):
            root = cur
            break
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent

def reply(obj):
    sys.stdout.write(json.dumps(obj))
    sys.exit(0)

def fail(msg):
    reply({"t": "error", "message": str(msg)})

if not os.path.isdir(root):
    fail("Not a folder: " + raw_root)

def confine(base, rel):
    if not rel:
        return base
    norm = rel.replace("\\", "/")
    if "\0" in norm or ".." in norm.split("/"):
        fail("Path escapes project")
    joined = os.path.join(base, rel)
    real = os.path.realpath(joined)
    prefix = base.rstrip("/") + "/"
    if real != base and not real.startswith(prefix):
        fail("Path escapes project")
    return real

def mtime_ms(st):
    return int(st.st_mtime * 1000)

def run_git(args):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", LC_ALL="C")
    p = subprocess.run(["git", "-C", root] + args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, timeout=5)
    if p.returncode not in (0, 1):
        raise RuntimeError("git failed")
    return p.stdout

def compute_changes():
    if not os.path.exists(os.path.join(root, ".git")):
        return []
    try:
        status_bytes = run_git(["status", "--porcelain=v1", "-z"])
    except Exception:
        return []
    try:
        stat_bytes = run_git(["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", "HEAD"])
    except Exception:
        try:
            stat_bytes = run_git(["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z"])
        except Exception:
            stat_bytes = b""
    counts = {}
    s_items = [x for x in stat_bytes.split(b"\0") if x]
    idx = 0
    while idx < len(s_items):
        row = s_items[idx]
        idx += 1
        parts = row.split(b"\t", 2)
        if len(parts) < 3:
            continue
        add_b, del_b, path_b = parts[0], parts[1], parts[2]
        if not path_b and idx + 1 < len(s_items):
            idx += 1
            path_b = s_items[idx]
            idx += 1
        binary = (add_b == b"-" or del_b == b"-")
        try:
            add_n = int(add_b.decode("utf-8", "replace"))
        except Exception:
            add_n = 0
        try:
            del_n = int(del_b.decode("utf-8", "replace"))
        except Exception:
            del_n = 0
        counts[path_b.decode("utf-8", "replace")] = (add_n, del_n, binary)
    f_items = [x for x in status_bytes.split(b"\0") if x]
    idx = 0
    out = []
    while idx < len(f_items) and len(out) < 2000:
        entry = f_items[idx]
        idx += 1
        if len(entry) < 4:
            continue
        x = chr(entry[0])
        y = chr(entry[1])
        path_s = entry[3:].decode("utf-8", "replace")
        if x in ("R", "C") and idx < len(f_items):
            idx += 1
        if x == "?":
            st = "U"
        elif x == "U" or y == "U":
            st = "!"
        elif y != " ":
            st = y
        else:
            st = x
        if path_s in counts:
            add_n, del_n, binary = counts[path_s]
        elif st == "U":
            try:
                t = confine(root, path_s)
                with open(t, "rb") as fp:
                    data = fp.read(limit + 1)
                if len(data) <= limit:
                    try:
                        data.decode("utf-8")
                        binary = (b"\0" in data)
                    except Exception:
                        binary = True
                    if binary or not data:
                        add_n, del_n = 0, 0
                    else:
                        add_n = data.count(b"\n") + (0 if data.endswith(b"\n") else 1)
                        del_n = 0
                else:
                    add_n, del_n, binary = -1, -1, False
            except Exception:
                add_n, del_n, binary = -1, -1, False
        else:
            add_n, del_n, binary = -1, -1, False
        out.append({
            "path": path_s,
            "status": st,
            "add": add_n,
            "del": del_n,
            "binary": binary,
            "staged": (x != " " and y == " ")
        })
    return out

if op == "directories":
    names = []
    try:
        for e in os.scandir(root):
            if not e.name.startswith(".") and e.is_dir():
                names.append(e.name)
                if len(names) >= 1000:
                    break
    except Exception as ex:
        fail(ex)
    names.sort()
    parent = os.path.dirname(root.rstrip("/")) or "/"
    reply({"t": "directories", "path": root, "parent": parent, "names": names})

rel_path = req.get("path", "")
if len(rel_path) > 4096 or "\0" in rel_path:
    fail("Invalid project path")

if op == "listFiles":
    directory = confine(root, rel_path)
    changed_paths = [c["path"] for c in compute_changes()]
    entries = []
    try:
        raw_entries = list(os.scandir(directory))[:2001]
    except Exception as ex:
        fail(ex)
    raw_entries.sort(key=lambda e: e.name)
    for e in raw_entries[:2000]:
        if e.name in (".git", ".hg", ".svn"):
            continue
        try:
            resolved = confine(root, os.path.relpath(e.path, root))
        except Exception:
            continue
        rel = os.path.relpath(e.path, root).replace("\\", "/")
        prefix = rel + "/"
        is_changed = any(p == rel or p.startswith(prefix) for p in changed_paths)
        entries.append({"name": e.name, "dir": os.path.isdir(resolved), "changed": is_changed})
    reply({"t": "fileList", "path": rel_path, "entries": entries})

elif op == "readFile":
    target = confine(root, rel_path)
    try:
        st = os.stat(target)
        with open(target, "rb") as fp:
            data = fp.read(limit + 1)
    except Exception as ex:
        fail(ex)
    truncated = len(data) > limit
    data = data[:limit]
    try:
        data.decode("utf-8")
        binary = (b"\0" in data)
    except Exception:
        binary = True
    reply({
        "t": "file",
        "path": rel_path,
        "data": base64.b64encode(data).decode("ascii"),
        "size": st.st_size,
        "binary": binary,
        "truncated": truncated,
        "mtime": mtime_ms(st),
    })

elif op == "writeFile":
    target = confine(root, rel_path)
    expected = int(req.get("baseMtime", 0))
    try:
        st = os.stat(target)
    except Exception as ex:
        fail(ex)
    if expected != 0 and mtime_ms(st) != expected:
        fail("conflict: File changed on the host; reload before saving")
    raw = base64.b64decode(req.get("data", ""))
    if len(raw) > limit:
        fail("File exceeds edit limit")
    flags = os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(target, flags)
    try:
        st2 = os.fstat(fd)
        if expected != 0 and mtime_ms(st2) != expected:
            fail("conflict: File changed on the host")
        os.ftruncate(fd, 0)
        os.write(fd, raw)
        os.fsync(fd)
        st3 = os.fstat(fd)
    finally:
        os.close(fd)
    reply({"t": "written", "path": rel_path, "mtime": mtime_ms(st3)})

elif op == "upload":
    name = req.get("name", "")
    if not name or os.path.basename(name) != name or name in (".", ".."):
        fail("Invalid upload name")
    raw = base64.b64decode(req.get("data", ""))
    if len(raw) > 8 * limit:
        fail("Upload exceeds 8 MiB")
    up_dir = os.path.join(root, ".omg-mobile-uploads")
    if os.path.islink(up_dir):
        fail("Path escapes project")
    if not os.path.exists(up_dir):
        os.mkdir(up_dir, 0o700)
    up_dir = confine(root, ".omg-mobile-uploads")
    target = os.path.join(up_dir, req.get("nonce", "upload") + "-" + name)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(target, flags, 0o600)
    try:
        os.write(fd, raw)
    finally:
        os.close(fd)
    reply({"t": "uploaded", "path": target})

elif op == "searchFiles":
    query = req.get("query", "").lower()
    paths = []
    stack = [root]
    visited = 0
    while stack:
        d = stack.pop()
        try:
            sc = list(os.scandir(d))[:2000]
        except Exception:
            continue
        for e in sc:
            visited += 1
            if visited > 10000 or len(paths) >= 200:
                break
            if e.name in (".git", "node_modules", ".build", "target"):
                continue
            try:
                if e.is_dir(follow_symlinks=False):
                    stack.append(e.path)
                elif e.is_file(follow_symlinks=False):
                    rel = os.path.relpath(e.path, root).replace("\\", "/")
                    if query in rel.lower():
                        paths.append(rel)
            except Exception:
                continue
        if visited > 10000 or len(paths) >= 200:
            break
    truncated = (visited > 10000 or len(paths) >= 200)
    reply({"t": "searchResults", "query": req.get("query", ""), "paths": paths, "truncated": truncated})

elif op == "listChanges":
    reply({"t": "changes", "files": compute_changes()})

elif op == "readDiff":
    if not rel_path or rel_path.startswith("/") or ".." in rel_path.replace("\\", "/").split("/"):
        fail("Invalid diff path")
    st_code = req.get("status", "")
    try:
        if st_code == "U":
            target = confine(root, rel_path)
            diff_bytes = run_git(["diff", "--no-ext-diff", "--no-textconv", "--no-index", "--", "/dev/null", target])
        else:
            try:
                diff_bytes = run_git(["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", rel_path])
            except Exception:
                diff_bytes = run_git(["diff", "--no-ext-diff", "--no-textconv", "--", rel_path])
    except Exception as ex:
        fail(ex)
    binary = (b"Binary files" in diff_bytes)
    reply({"t": "diff", "path": rel_path, "text": diff_bytes.decode("utf-8", "replace"), "binary": binary})

else:
    fail("Unsupported operation")
"#;

pub(super) fn quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

fn ssh_hosts_path(config: &Config) -> Option<PathBuf> {
    config
        .support
        .as_ref()
        .map(|p| p.join("mobile-ssh-hosts.json"))
        .or_else(|| {
            config
                .endpoints
                .first()?
                .socket
                .parent()
                .map(|p| p.join("mobile-ssh-hosts.json"))
        })
}

pub(super) fn load_remembered_ssh_hosts(config: &Config) -> Vec<RememberedSshHost> {
    ssh_hosts_path(config)
        .and_then(|p| bounded(&p, FILE_LIMIT).ok())
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

pub(super) fn remember_ssh_target(
    config: &Config,
    target: &omg_session_runtime::location::SshTarget,
) {
    let destination = target.destination.trim();
    if destination.is_empty() || destination.len() > 256 || destination.contains('\0') {
        return;
    }
    let Some(path) = ssh_hosts_path(config) else {
        return;
    };
    let (user, host_name) = match destination.split_once('@') {
        Some((u, h)) if !h.is_empty() => (u.to_owned(), h.to_owned()),
        _ => (String::new(), destination.to_owned()),
    };
    let mut port = 22u16;
    let mut idx = 0;
    while idx < target.options.len() {
        if target.options[idx] == "-p" {
            if let Some(p) = target.options.get(idx + 1).and_then(|s| s.parse::<u16>().ok()) {
                port = p;
            }
            idx += 2;
        } else {
            idx += 1;
        }
    }
    let entry = RememberedSshHost {
        alias: destination.to_owned(),
        host_name,
        user,
        port,
        options: target.options.clone(),
    };
    let mut existing = load_remembered_ssh_hosts(config);
    if existing.first() == Some(&entry) {
        return;
    }
    existing.retain(|h| h.alias != entry.alias);
    existing.insert(0, entry);
    existing.truncate(128);
    if let Ok(nonce) = record::nonce() {
        let temporary = path.with_extension(format!("{nonce}.tmp"));
        let written = (|| -> io::Result<()> {
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temporary)?;
            file.write_all(&serde_json::to_vec(&existing)?)?;
            fs::rename(&temporary, &path)
        })();
        if written.is_err() {
            let _ = fs::remove_file(temporary);
        }
    }
}

pub(super) fn host_display_name(host: &str) -> String {
    if let Ok(target) = serde_json::from_str::<omg_session_runtime::location::SshTarget>(host) {
        return target.destination;
    }
    if let Some(alias) = host.strip_prefix("ssh:") {
        return alias.to_owned();
    }
    host.to_owned()
}

pub(super) fn resolve_remote_ssh(
    config: &Config,
    host: &str,
) -> io::Result<(String, Vec<String>)> {
    if let Ok(target) = serde_json::from_str::<omg_session_runtime::location::SshTarget>(host) {
        if !target.destination.is_empty() {
            return Ok((target.destination, target.options));
        }
    }
    if let Some(alias) = host.strip_prefix("ssh:") {
        if let Some(saved) = load_remembered_ssh_hosts(config)
            .into_iter()
            .find(|h| h.alias == alias)
        {
            return Ok((saved.alias, saved.options));
        }
        return Ok((alias.to_owned(), Vec::new()));
    }
    if let Ok(remote) = helper(config, json!({"operation":"sshCommand","host":host})) {
        if let Ok(destination) = text(&remote, "destination") {
            let options = remote["options"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect::<Vec<_>>();
            return Ok((destination.to_owned(), options));
        }
    }
    if let Some(saved) = load_remembered_ssh_hosts(config)
        .into_iter()
        .find(|h| h.alias == host)
    {
        return Ok((saved.alias, saved.options));
    }
    Ok((host.to_owned(), Vec::new()))
}

fn remote_python(config: &Config, host: &str, payload: &Value) -> io::Result<Value> {
    let (destination, options) = resolve_remote_ssh(config, host)?;
    let input = serde_json::to_vec(payload)?;
    if input.len() > 12 * FILE_LIMIT {
        return Err(io::Error::other("Remote request exceeds size limit"));
    }
    let remote_cmd = format!(
        "if command -v python3 >/dev/null 2>&1; then exec python3 -c {}; elif command -v python >/dev/null 2>&1; then exec python -c {}; else printf '%s' '{{\"t\":\"error\",\"message\":\"python3 is required on the remote SSH host\"}}'; fi",
        quote(REMOTE_PYTHON_SCRIPT),
        quote(REMOTE_PYTHON_SCRIPT),
    );
    let mut cmd = Command::new("/usr/bin/ssh");
    cmd.process_group(0)
        .args([
            "-T",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=6",
            "-o",
            "ControlMaster=auto",
            "-o",
            "ControlPath=/tmp/omg-ssh-mux-%C",
            "-o",
            "ControlPersist=120s",
        ])
        .args(&options)
        .arg(&destination)
        .arg(&remote_cmd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(&input);
    }
    let output = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = output
            .take((2 * FILE_LIMIT + 1) as u64)
            .read_to_end(&mut bytes);
        let mut err_bytes = Vec::new();
        let _ = stderr.take(4096).read_to_end(&mut err_bytes);
        let _ = tx.send((result.map(|_| bytes), err_bytes));
    });
    let received = rx.recv_timeout(Duration::from_secs(12));
    let deadline = Instant::now() + Duration::from_secs(1);
    let mut status = child.try_wait()?;
    while status.is_none() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
        status = child.try_wait()?;
    }
    if status.is_none() || !matches!(&received, Ok((Ok(data), _)) if data.len() <= 2 * FILE_LIMIT) {
        unsafe {
            libc::kill(-(child.id() as i32), libc::SIGKILL);
        }
    }
    let status = child.wait()?;
    let _ = reader.join();
    let (bytes_res, err_bytes) =
        received.map_err(|_| io::Error::other("Remote SSH operation timed out"))?;
    let bytes = bytes_res?;
    if bytes.len() > 2 * FILE_LIMIT {
        return Err(io::Error::other("Remote SSH response exceeds size limit"));
    }
    if let Ok(result) = serde_json::from_slice::<Value>(&bytes) {
        if result["t"] == "error" {
            return Err(io::Error::other(
                result["message"]
                    .as_str()
                    .unwrap_or("Remote SSH operation failed"),
            ));
        }
        return Ok(result);
    }
    if !status.success() {
        let detail = String::from_utf8_lossy(&err_bytes).trim().to_owned();
        return Err(io::Error::other(if detail.is_empty() {
            format!("SSH connection to {destination} failed")
        } else {
            format!("SSH {destination}: {detail}")
        }));
    }
    Err(io::Error::other("Invalid response from remote SSH host"))
}

pub(super) fn remote_project_control(
    config: &Config,
    project: &Project,
    host: &str,
    kind: &str,
    path: &str,
    request: &Value,
) -> io::Result<Value> {
    let root_str = project.root.to_string_lossy();
    let payload = match kind {
        "listFiles" | "readFile" | "listChanges" => json!({
            "op": kind,
            "root": root_str,
            "path": path,
            "limit": FILE_LIMIT,
        }),
        "writeFile" => json!({
            "op": "writeFile",
            "root": root_str,
            "path": path,
            "data": text(request, "data")?,
            "baseMtime": request["baseMtime"].as_u64().ok_or_else(|| io::Error::other("Missing file version"))?,
            "limit": FILE_LIMIT,
        }),
        "upload" => json!({
            "op": "upload",
            "root": root_str,
            "name": text(request, "name")?,
            "data": text(request, "data")?,
            "nonce": record::nonce()?,
            "limit": FILE_LIMIT,
        }),
        "searchFiles" => json!({
            "op": "searchFiles",
            "root": root_str,
            "query": text(request, "query")?,
            "limit": FILE_LIMIT,
        }),
        "readDiff" => json!({
            "op": "readDiff",
            "root": root_str,
            "path": path,
            "status": request["status"].as_str().unwrap_or(""),
            "limit": FILE_LIMIT,
        }),
        _ => return Err(io::Error::other("Unsupported remote control operation")),
    };
    remote_python(config, host, &payload)
}

fn projects_path(config: &Config) -> io::Result<PathBuf> {
    config
        .support
        .as_ref()
        .map(|p| p.join("mobile-projects.json"))
        .or_else(|| {
            config
                .endpoints
                .first()?
                .socket
                .parent()
                .map(|p| p.join("mobile-projects.json"))
        })
        .ok_or_else(|| io::Error::other("A mobile state directory is required"))
}

fn load_projects(config: &Config) -> Vec<SavedProject> {
    projects_path(config)
        .ok()
        .and_then(|p| bounded(&p, FILE_LIMIT).ok())
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

pub(super) fn append_projects(
    config: &Config,
    desktop: &Desktop,
    endpoint: Option<&Endpoint>,
    projects: &mut BTreeMap<String, (Project, Value)>,
) -> io::Result<()> {
    for saved in load_projects(config).into_iter().take(1000) {
        let Some((_, workspace_name)) = desktop
            .workspaces
            .iter()
            .find(|(id, _)| id == &saved.workspace)
        else {
            continue;
        };
        let id = saved.id;
        let host = (saved.host != "local").then_some(saved.host);
        let mut entry = json!({
            "id": id,
            "name": saved.name,
            "path": saved.path,
            "workspaceID": saved.workspace,
            "workspaceName": workspace_name,
            "branch": "",
            "kind": "folder",
            "sessions": []
        });
        if let Some(ref h) = host {
            entry["deviceAlias"] = Value::String(host_display_name(h));
        }
        projects.insert(
            id.clone(),
            (
                Project {
                    id: id.clone(),
                    root: saved.path.clone(),
                    workspace: saved.workspace.clone(),
                    endpoint: endpoint.cloned(),
                    host,
                },
                entry,
            ),
        );
    }
    Ok(())
}

fn helper_executable() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let candidate = exe.parent()?.join("omg-mobile-support");
    candidate.is_file().then_some(candidate)
}

fn helper(config: &Config, mut request: Value) -> io::Result<Value> {
    let executable = helper_executable().ok_or_else(|| {
        io::Error::other("Desktop SSH helper is not available on this host; use local directories or pair directly with the SSH server")
    })?;
    let domain = match config
        .support
        .as_ref()
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
    {
        Some("OMG") => "com.jischeng.omg",
        Some("OMG Dev Workspace") => "com.jischeng.omg.debug.workspace",
        _ => "com.jischeng.omg.debug",
    };
    request["domain"] = domain.into();
    let mut child = Command::new(executable)
        .process_group(0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let input = serde_json::to_vec(&request)?;
    if input.len() > 16384 {
        let _ = child.kill();
        let _ = child.wait();
        return Err(io::Error::other("Request too large"));
    }
    child.stdin.take().unwrap().write_all(&input)?;
    let output = child.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = output
            .take((2 * FILE_LIMIT + 1) as u64)
            .read_to_end(&mut bytes);
        let _ = tx.send(result.map(|_| bytes));
    });
    let result = rx.recv_timeout(Duration::from_secs(12));
    let deadline = Instant::now() + Duration::from_secs(1);
    let mut status = child.try_wait()?;
    while status.is_none() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
        status = child.try_wait()?;
    }
    if status.is_none() || !matches!(&result, Ok(Ok(data)) if data.len() <= 2 * FILE_LIMIT) {
        unsafe {
            libc::kill(-(child.id() as i32), libc::SIGKILL);
        }
    }
    let status = child.wait()?;
    let _ = reader.join();
    let bytes = result.map_err(|_| io::Error::other("Desktop operation timed out"))??;
    if !status.success() || bytes.len() > 2 * FILE_LIMIT {
        return Err(io::Error::other("Desktop operation failed"));
    }
    let result: Value = serde_json::from_slice(&bytes)?;
    if result["t"] == "error" {
        return Err(io::Error::other(
            result["message"]
                .as_str()
                .unwrap_or("Desktop operation failed"),
        ));
    }
    Ok(result)
}

pub(super) fn ssh_command(config: &Config, host: &str) -> io::Result<Value> {
    if !host.starts_with("ssh:") && !host.starts_with('{') {
        if let Ok(val) = helper(config, json!({"operation":"sshCommand","host":host})) {
            return Ok(val);
        }
    }
    let (destination, options) = resolve_remote_ssh(config, host)?;
    Ok(json!({
        "t": "sshCommand",
        "destination": destination,
        "options": options,
    }))
}

fn local_directories(path: &str) -> io::Result<Value> {
    if !path.is_empty()
        && (!path.starts_with('/')
            || path.contains('\0')
            || path.contains('\n')
            || path.len() > 4096)
    {
        return Err(io::Error::other("Invalid folder path"));
    }
    let candidate = if path.is_empty() {
        home()?
    } else {
        PathBuf::from(path)
    };
    let root = fs::canonicalize(&candidate)?;
    if !root.is_dir() {
        return Err(io::Error::other("Not a folder"));
    }
    let mut names = Vec::new();
    for entry in fs::read_dir(&root)?.take(1000).flatten() {
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        if entry.path().is_dir() {
            names.push(name);
        }
    }
    names.sort();
    let parent = root
        .parent()
        .map(|p| p.to_string_lossy().into_owned())
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| "/".into());
    Ok(json!({
        "t": "directories",
        "path": root.to_string_lossy(),
        "parent": parent,
        "names": names,
    }))
}

fn resolve_directories(config: &Config, host: &str, path: &str) -> io::Result<Value> {
    if host == "local" {
        local_directories(path)
    } else if !host.starts_with("ssh:") && !host.starts_with('{') {
        helper(
            config,
            json!({"operation":"directories","host":host,"path":path}),
        )
        .or_else(|_| {
            remote_python(
                config,
                host,
                &json!({"op":"directories","root":path,"limit":FILE_LIMIT}),
            )
        })
    } else {
        remote_python(
            config,
            host,
            &json!({"op":"directories","root":path,"limit":FILE_LIMIT}),
        )
    }
}

pub(super) fn request(config: &Config, request: &Value) -> io::Result<Value> {
    match text(request, "t")? {
        "workspaces" => Ok(
            json!({"t":"workspaces","workspaces":desktop(config).workspaces.into_iter().map(|(id,name)|json!({"id":id,"name":name})).collect::<Vec<_>>()}),
        ),
        "hosts" => {
            let mut list = vec![json!({"id":"local","name":"Local Machine"})];
            let mut seen_names = std::collections::HashSet::new();
            if helper_executable().is_some() {
                if let Ok(value) = helper(config, json!({"operation":"hosts"})) {
                    if let Some(arr) = value["hosts"].as_array() {
                        for item in arr {
                            if item["id"].as_str() == Some("local") {
                                continue;
                            }
                            if let Some(name) = item["name"].as_str() {
                                seen_names.insert(name.to_owned());
                            }
                            list.push(item.clone());
                        }
                    }
                }
            }
            for h in super::ssh_hosts_for_config(config) {
                if let Some(alias) = h["alias"].as_str() {
                    if seen_names.insert(alias.to_owned()) {
                        list.push(json!({
                            "id": format!("ssh:{alias}"),
                            "name": alias,
                        }));
                    }
                }
            }
            Ok(json!({"t":"hosts","hosts":list}))
        }
        "directories" => resolve_directories(
            config,
            text(request, "host")?,
            request["path"].as_str().unwrap_or(""),
        ),
        "addProject" => {
            let workspace = text(request, "workspace")?;
            if !desktop(config)
                .workspaces
                .iter()
                .any(|(id, _)| id == workspace)
            {
                return Err(io::Error::other("Workspace no longer exists"));
            }
            let host = text(request, "host")?;
            let resolved = resolve_directories(config, host, text(request, "path")?)?;
            let path = PathBuf::from(text(&resolved, "path")?);
            let id = format!(
                "mobile-project-{}",
                &hash(&format!("{workspace}\0{host}\0{}", path.display()))[..24]
            );
            let name = path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned();
            let mut saved = load_projects(config);
            saved.retain(|p| p.id != id);
            if saved.len() >= 1000 {
                return Err(io::Error::other("Project limit reached"));
            }
            saved.push(SavedProject {
                id: id.clone(),
                workspace: workspace.into(),
                host: host.into(),
                path,
                name,
            });
            let path = projects_path(config)?;
            let temporary = path.with_extension(format!("{}.tmp", record::nonce()?));
            let result = (|| {
                let mut file = fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&temporary)?;
                file.write_all(&serde_json::to_vec(&saved)?)?;
                fs::rename(&temporary, &path)
            })();
            if result.is_err() {
                let _ = fs::remove_file(temporary);
            }
            result?;
            config.control.invalidate();
            Ok(json!({"t":"projectAdded","id":id}))
        }
        _ => Err(io::Error::other("Unsupported operation")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saved_projects_keep_workspace_and_host_binding() {
        let directory =
            std::env::temp_dir().join(format!("omg-mobile-project-{}", record::nonce().unwrap()));
        fs::create_dir(&directory).unwrap();
        let demo_dir = directory.join("demo-local");
        fs::create_dir(&demo_dir).unwrap();
        fs::write(
            directory.join("mobile-projects.json"),
            serde_json::to_vec(&vec![SavedProject {
                id: "mobile-project-demo".into(),
                workspace: "workspace-a".into(),
                host: "ssh-host-demo".into(),
                path: PathBuf::from("/srv/demo"),
                name: "demo".into(),
            }])
            .unwrap(),
        )
        .unwrap();
        let config = Config {
            endpoints: vec![],
            support: Some(directory.clone()),
            token: "token".into(),
            origin: None,
            control: Default::default(),
        };
        let desktop = Desktop {
            workspaces: vec![("workspace-a".into(), "Alpha".into())],
            panes: HashMap::new(),
        };
        let mut projects = BTreeMap::new();
        append_projects(&config, &desktop, None, &mut projects).unwrap();
        let (project, roster) = projects.get("mobile-project-demo").unwrap();
        assert_eq!(project.workspace, "workspace-a");
        assert_eq!(project.host.as_deref(), Some("ssh-host-demo"));
        assert_eq!(roster["workspaceName"], "Alpha");

        let dirs = request(
            &config,
            &json!({"t": "directories", "host": "local", "path": directory.to_string_lossy()}),
        )
        .unwrap();
        assert_eq!(dirs["names"], json!(["demo-local"]));

        remember_ssh_target(
            &config,
            &omg_session_runtime::location::SshTarget {
                destination: "deploy@10.20.30.40".into(),
                options: vec!["-p".into(), "2222".into()],
                remote_cwd: Some("/srv/app".into()),
            },
        );
        let remembered = load_remembered_ssh_hosts(&config);
        assert_eq!(remembered.len(), 1);
        assert_eq!(remembered[0].alias, "deploy@10.20.30.40");
        assert_eq!(remembered[0].user, "deploy");
        assert_eq!(remembered[0].host_name, "10.20.30.40");
        assert_eq!(remembered[0].port, 2222);

        let resolved = resolve_remote_ssh(&config, "ssh:deploy@10.20.30.40").unwrap();
        assert_eq!(resolved.0, "deploy@10.20.30.40");
        assert_eq!(resolved.1, vec!["-p".to_owned(), "2222".to_owned()]);

        let _ = fs::remove_dir_all(directory);
    }
}
