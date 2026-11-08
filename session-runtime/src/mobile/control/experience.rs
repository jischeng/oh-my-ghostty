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

pub(super) fn quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

fn projects_path(config: &Config) -> io::Result<PathBuf> {
    config
        .support
        .as_ref()
        .map(|p| p.join("mobile-projects.json"))
        .ok_or_else(|| io::Error::other("A desktop Application Support directory is required"))
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
                json!({"id":id,"name":saved.name,"path":saved.path,"workspaceID":saved.workspace,
            "workspaceName":workspace_name,"branch":"","kind":"folder","sessions":[]}),
            ),
        );
    }
    Ok(())
}

fn helper(config: &Config, mut request: Value) -> io::Result<Value> {
    let executable = std::env::current_exe()?
        .parent()
        .unwrap()
        .join("omg-mobile-support");
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
    helper(config, json!({"operation":"sshCommand","host":host}))
}

pub(super) fn request(config: &Config, request: &Value) -> io::Result<Value> {
    match text(request, "t")? {
        "workspaces" => Ok(
            json!({"t":"workspaces","workspaces":desktop(config).workspaces.into_iter().map(|(id,name)|json!({"id":id,"name":name})).collect::<Vec<_>>()}),
        ),
        "hosts" => helper(config, json!({"operation":"hosts"})),
        "directories" => helper(
            config,
            json!({"operation":"directories","host":text(request,"host")?,
            "path":request["path"].as_str().unwrap_or("")}),
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
            let resolved = helper(
                config,
                json!({"operation":"directories","host":host,"path":text(request,"path")?}),
            )?;
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
        let _ = fs::remove_dir_all(directory);
    }
}
