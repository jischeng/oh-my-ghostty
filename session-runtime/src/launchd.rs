//! macOS-only detachment of persistent local hosts from the app coalition.
//! A child of the GUI stays in its coalition after `setsid`, so LaunchServices
//! reports the quit app as still running in the background.
//!
//! When running inside an OMG `.app` bundle, a `gui/<uid>` launchd job starts
//! `<App>.app/Contents/MacOS/omg +internal-runtime-host`, which spawns
//! `omgd host-local` in its own session, reports its pid, and waits as its live
//! parent without initializing AppKit or joining the GUI coalition. macOS TCC
//! therefore attributes `omgd` and all terminal shells to OMG (`com.jischeng.omg`
//! / `com.jischeng.omg.debug`), while Cmd-Q still cleanly terminates the GUI app.
//! Unbundled helpers (such as standalone CLI tests) fall back to `omgd detach`.
use std::{
    io,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

const READY_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostApp {
    pub bundle_id: String,
    pub executable: PathBuf,
}

pub fn escape(value: &str) -> io::Result<String> {
    if value
        .chars()
        .any(|c| c.is_control() && c != '\t' && c != '\n')
    {
        return Err(io::Error::other(
            "launchd value contains a control character",
        ));
    }
    Ok(value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;"))
}

pub struct Job<'a> {
    pub label: &'a str,
    pub associated_bundle_id: Option<&'a str>,
    pub arguments: &'a [String],
    pub environment: &'a [(String, String)],
    pub working_directory: &'a Path,
    pub log: &'a Path,
    pub umask: u32,
}

pub fn plist(job: &Job<'_>) -> io::Result<String> {
    let mut out = String::from(concat!(
        r#"<?xml version="1.0" encoding="UTF-8"?>"#,
        "\n",
        r#"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
        "\n<plist version=\"1.0\"><dict>\n"
    ));
    let string = |key: &str, value: &str| -> io::Result<String> {
        Ok(format!(
            "<key>{key}</key><string>{}</string>\n",
            escape(value)?
        ))
    };
    out += &string("Label", job.label)?;
    if let Some(bundle_id) = job.associated_bundle_id {
        out += "<key>AssociatedBundleIdentifiers</key><array>\n";
        out += &format!("<string>{}</string>\n", escape(bundle_id)?);
        out += "</array>\n";
    }
    out += "<key>ProgramArguments</key><array>\n";
    for argument in job.arguments {
        out += &format!("<string>{}</string>\n", escape(argument)?);
    }
    out += "</array>\n<key>EnvironmentVariables</key><dict>\n";
    for (key, value) in job.environment {
        out += &format!(
            "<key>{}</key><string>{}</string>\n",
            escape(key)?,
            escape(value)?
        );
    }
    out += "</dict>\n";
    fn path(p: &Path) -> io::Result<&str> {
        p.to_str()
            .ok_or_else(|| io::Error::other("launchd path is not UTF-8"))
    }
    out += &string("WorkingDirectory", path(job.working_directory)?)?;
    out += &string("StandardInPath", "/dev/null")?;
    out += &string("StandardOutPath", path(job.log)?)?;
    out += &string("StandardErrorPath", path(job.log)?)?;
    out += "<key>RunAtLoad</key><true/>\n<key>KeepAlive</key><false/>\n";
    out += "<key>AbandonProcessGroup</key><true/>\n";
    out += &string("ProcessType", "Interactive")?;
    out += &format!("<key>Umask</key><integer>{}</integer>\n", job.umask);
    out += "</dict></plist>\n";
    Ok(out)
}

/// Environment passed to the detached host. launchd jobs otherwise start with
/// a minimal environment; the login shell must see the app's PATH/LANG/etc.
/// XPC_SERVICE_NAME would attribute the process to the app's launchd job.
pub fn environment(vars: impl Iterator<Item = (String, String)>) -> Vec<(String, String)> {
    let mut vars: Vec<_> = vars
        .filter(|(key, _)| {
            key != "XPC_SERVICE_NAME"
                && !key.starts_with("__CF")
                && key != "OMG_HOST_APP_BUNDLE"
                && key != "OMG_HOST_APP_BUNDLE_ID"
                && key != "OMG_RUNTIME_HOST_LABEL"
        })
        .filter(|(key, value)| escape(key).is_ok() && escape(value).is_ok())
        .map(|(key, value)| {
            if key == "TERM" && (value.trim().is_empty() || value == "dumb") {
                (key, "xterm-256color".into())
            } else {
                (key, value)
            }
        })
        .collect();
    if !vars.iter().any(|(key, _)| key == "TERM") {
        vars.push(("TERM".into(), "xterm-256color".into()));
    }
    vars.sort();
    vars
}

fn extract_xml_plist_string(xml: &str, key: &str) -> Option<String> {
    let needle = format!("<key>{key}</key>");
    let after_key = xml.split_once(&needle)?.1;
    let trimmed = after_key.trim_start();
    let after_open = trimmed.strip_prefix("<string>")?;
    let raw = after_open.split_once("</string>")?.0.trim();
    if raw.is_empty() {
        return None;
    }
    Some(
        raw.replace("&quot;", "\"")
            .replace("&gt;", ">")
            .replace("&lt;", "<")
            .replace("&amp;", "&"),
    )
}

fn extract_plutil_string(plist_path: &Path, key: &str) -> Option<String> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let out = std::process::Command::new("/usr/bin/plutil")
        .args(["-extract", key, "raw", "-o", "-"])
        .arg(plist_path)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8(out.stdout).ok()?;
    let trimmed = text.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

fn is_valid_omg_bundle_id(bundle_id: &str) -> bool {
    bundle_id.starts_with("com.jischeng.omg")
        && bundle_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
}

fn is_executable_file(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .map(|m| m.is_file() && (m.permissions().mode() & 0o111 != 0))
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

pub fn host_app_from_bundle(bundle: &Path, bundle_id_hint: Option<&str>) -> Option<HostApp> {
    if bundle.extension().and_then(|s| s.to_str()) != Some("app") {
        return None;
    }
    let contents = bundle.join("Contents");
    let info_plist = contents.join("Info.plist");
    if !info_plist.is_file() {
        return None;
    }
    let xml = std::fs::read_to_string(&info_plist).ok();
    let bundle_id = bundle_id_hint
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .or_else(|| {
            xml.as_deref()
                .and_then(|t| extract_xml_plist_string(t, "CFBundleIdentifier"))
        })
        .or_else(|| extract_plutil_string(&info_plist, "CFBundleIdentifier"))?;
    if !is_valid_omg_bundle_id(&bundle_id) {
        return None;
    }
    let executable_name = xml
        .as_deref()
        .and_then(|t| extract_xml_plist_string(t, "CFBundleExecutable"))
        .or_else(|| extract_plutil_string(&info_plist, "CFBundleExecutable"))
        .unwrap_or_else(|| "omg".into());
    if executable_name.contains('/') || executable_name.contains('\0') {
        return None;
    }
    let executable = contents.join("MacOS").join(executable_name);
    if !is_executable_file(&executable) {
        return None;
    }
    Some(HostApp {
        bundle_id,
        executable,
    })
}

fn enclosing_app_bundle(path: &Path) -> Option<&Path> {
    path.ancestors()
        .find(|ancestor| ancestor.extension().and_then(|s| s.to_str()) == Some("app"))
}

pub fn resolve_host_app(
    helper: &Path,
    env_bundle: Option<&Path>,
    env_bundle_id: Option<&str>,
) -> Option<HostApp> {
    if let Some(bundle) = env_bundle {
        if let Some(app) = host_app_from_bundle(bundle, env_bundle_id) {
            return Some(app);
        }
    }
    if let Some(bundle) = enclosing_app_bundle(helper) {
        if let Some(app) = host_app_from_bundle(bundle, None) {
            return Some(app);
        }
    }
    if let Ok(current_exe) = std::env::current_exe() {
        if let Some(bundle) = enclosing_app_bundle(&current_exe) {
            if let Some(app) = host_app_from_bundle(bundle, None) {
                return Some(app);
            }
        }
    }
    None
}

fn stable_label_hash(path: &Path) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in path.to_string_lossy().as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn launchctl(args: &[&str]) -> io::Result<bool> {
    Ok(std::process::Command::new("/bin/launchctl")
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()?
        .success())
}

/// Starts `command` outside the caller's coalition. Returns Ok(None) when the
/// GUI launchd domain is unavailable so callers can use direct startup.
pub fn spawn(helper: &Path, command: &[String], log: &Path) -> io::Result<Option<u32>> {
    if !cfg!(target_os = "macos") {
        return Ok(None);
    }
    let uid = unsafe { libc::getuid() };
    let domain = format!("gui/{uid}");
    let nonce = format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default()
    );
    let env_bundle = std::env::var_os("OMG_HOST_APP_BUNDLE").map(PathBuf::from);
    let env_bundle_id = std::env::var("OMG_HOST_APP_BUNDLE_ID").ok();
    let host_app = resolve_host_app(helper, env_bundle.as_deref(), env_bundle_id.as_deref());
    let label = match &host_app {
        Some(app) => format!("{}.host.{:016x}", app.bundle_id, stable_label_hash(log)),
        None => format!("com.jischeng.omg.host.{nonce}"),
    };
    let dir = PathBuf::from(format!("/tmp/omg-launchd-{uid}-{nonce}"));
    std::fs::create_dir(&dir)?;
    let cleanup = |dir: &Path| {
        let _ = std::fs::remove_dir_all(dir);
    };
    let ready = dir.join("ready");
    let mut arguments = match &host_app {
        Some(app) => vec![
            app.executable.to_string_lossy().into_owned(),
            "+internal-runtime-host".into(),
            ready.to_string_lossy().into_owned(),
            "--".into(),
        ],
        None => vec![
            helper.to_string_lossy().into_owned(),
            "detach".into(),
            ready.to_string_lossy().into_owned(),
            "--".into(),
        ],
    };
    arguments.extend(command.iter().cloned());
    let umask = unsafe {
        let current = libc::umask(0o077);
        libc::umask(current);
        current as u32
    };
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
    let job_plist = dir.join("job.plist");
    let mut env = environment(std::env::vars());
    if host_app.is_some() {
        env.push(("OMG_RUNTIME_HOST_LABEL".into(), label.clone()));
        env.sort();
    }
    let text = plist(&Job {
        label: &label,
        associated_bundle_id: host_app.as_ref().map(|app| app.bundle_id.as_str()),
        arguments: &arguments,
        environment: &env,
        working_directory: &cwd,
        log,
        umask,
    });
    let text = match text {
        Ok(text) => text,
        Err(error) => {
            cleanup(&dir);
            return Err(error);
        }
    };
    std::fs::write(&job_plist, text)?;
    let target = format!("{domain}/{label}");
    if host_app.is_some() {
        // Clear any finished job record for this state directory before bootstrapping.
        let _ = launchctl(&["bootout", &target]);
    }
    if !launchctl(&["bootstrap", &domain, &job_plist.to_string_lossy()]).unwrap_or(false) {
        cleanup(&dir);
        return Ok(None);
    }
    let deadline = Instant::now() + READY_TIMEOUT;
    let pid = loop {
        if let Some(pid) = std::fs::read_to_string(&ready)
            .ok()
            .and_then(|s| s.trim().parse::<u32>().ok())
        {
            break Some(pid);
        }
        if Instant::now() >= deadline {
            break None;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    if host_app.is_none() || pid.is_none() {
        // Unbundled fallback exits immediately via `omgd detach`; bundled wrappers
        // stay alive as the OMG-attributed parent until `host-local` exits.
        let _ = launchctl(&["bootout", &target]);
    }
    cleanup(&dir);
    pid.map(Some)
        .ok_or_else(|| io::Error::other("launchd host did not complete the detach handshake"))
}

/// `omgd detach READY -- COMMAND...`: runs as the transient launchd job for unbundled helpers.
pub fn detach(ready: &Path, command: &[String]) -> io::Result<()> {
    use std::os::unix::process::CommandExt;
    let (program, args) = command
        .split_first()
        .ok_or_else(|| io::Error::other("missing detached command"))?;
    let mut child = std::process::Command::new(program);
    child.args(args);
    unsafe {
        child.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            libc::signal(libc::SIGHUP, libc::SIG_IGN);
            Ok(())
        });
    }
    let pid = child.spawn()?.id();
    let staging = ready.with_extension("tmp");
    std::fs::write(&staging, pid.to_string())?;
    std::fs::rename(&staging, ready)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plist_escapes_values_and_abandons_process_group() {
        let args = vec!["/a b/omgd".to_string(), "x<&>\"".to_string()];
        let env = vec![("K".to_string(), "v&w".to_string())];
        let text = plist(&Job {
            label: "l",
            associated_bundle_id: Some("com.jischeng.omg.debug"),
            arguments: &args,
            environment: &env,
            working_directory: Path::new("/"),
            log: Path::new("/tmp/h.log"),
            umask: 0o22,
        })
        .unwrap();
        assert!(text.contains("<string>x&lt;&amp;&gt;&quot;</string>"));
        assert!(text.contains("<key>K</key><string>v&amp;w</string>"));
        assert!(text.contains("<key>AbandonProcessGroup</key><true/>"));
        assert!(text.contains("<key>KeepAlive</key><false/>"));
        assert!(text.contains(
            "<key>AssociatedBundleIdentifiers</key><array>\n<string>com.jischeng.omg.debug</string>\n</array>"
        ));
        assert!(text.contains("<integer>18</integer>"));
    }

    #[test]
    fn rejects_control_characters() {
        assert!(escape("a\u{1}b").is_err());
    }

    #[test]
    fn environment_drops_app_job_and_internal_bundle_attribution() {
        let env = environment(
            [
                ("XPC_SERVICE_NAME", "application.com.x"),
                ("__CFBundleIdentifier", "com.x"),
                ("OMG_HOST_APP_BUNDLE", "/Applications/OMG.app"),
                ("OMG_HOST_APP_BUNDLE_ID", "com.jischeng.omg"),
                ("OMG_RUNTIME_HOST_LABEL", "com.jischeng.omg.host.1"),
                ("PATH", "/bin"),
                ("TERM", "dumb"),
                ("BAD", "a\u{1}"),
            ]
            .into_iter()
            .map(|(k, v)| (k.to_string(), v.to_string())),
        );
        assert_eq!(
            env,
            vec![
                ("PATH".to_string(), "/bin".to_string()),
                ("TERM".to_string(), "xterm-256color".to_string()),
            ]
        );
    }

    #[test]
    fn resolves_enclosing_omg_app_bundle_and_rejects_foreign_bundles() {
        let root = std::env::temp_dir().join(format!("omg-bundle-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let app = root.join("OMG Dev.app");
        let macos = app.join("Contents/MacOS");
        let runtime = app.join("Contents/Resources/session-runtime");
        std::fs::create_dir_all(&macos).unwrap();
        std::fs::create_dir_all(&runtime).unwrap();
        std::fs::write(
            app.join("Contents/Info.plist"),
            r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key>
    <string>com.jischeng.omg.debug</string>
    <key>CFBundleExecutable</key>
    <string>omg</string>
</dict></plist>"#,
        )
        .unwrap();
        let exe = macos.join("omg");
        std::fs::write(&exe, b"#!/bin/sh\n").unwrap();
        let helper = runtime.join("omgd");
        std::fs::write(&helper, b"#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
            std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let resolved = resolve_host_app(&helper, None, None).unwrap();
        assert_eq!(resolved.bundle_id, "com.jischeng.omg.debug");
        assert_eq!(resolved.executable, exe);

        std::fs::write(
            app.join("Contents/Info.plist"),
            r#"<plist><dict><key>CFBundleIdentifier</key><string>com.other.app</string></dict></plist>"#,
        )
        .unwrap();
        assert!(host_app_from_bundle(&app, None).is_none());
        let _ = std::fs::remove_dir_all(&root);
    }
}
