use super::*;

#[derive(Serialize, Deserialize)]
struct SavedProject {
    id: String,
    workspace: String,
    host: String,
    path: PathBuf,
    name: String,
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
        if saved.host != "local" {
            continue;
        }
        let Some((_, workspace_name)) = desktop
            .workspaces
            .iter()
            .find(|(id, _)| id == &saved.workspace)
        else {
            continue;
        };
        let id = saved.id;
        projects.insert(
            id.clone(),
            (
                Project {
                    id: id.clone(),
                    root: saved.path.clone(),
                    workspace: saved.workspace.clone(),
                    endpoint: endpoint.cloned(),
                    host: None,
                },
                json!({"id":id,"name":saved.name,"path":saved.path,"workspaceID":saved.workspace,
            "workspaceName":workspace_name,"branch":"","kind":"folder","sessions":[]}),
            ),
        );
    }
    Ok(())
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

pub(super) fn request(config: &Config, request: &Value) -> io::Result<Value> {
    match text(request, "t")? {
        "workspaces" => Ok(
            json!({"t":"workspaces","workspaces":desktop(config).workspaces.into_iter().map(|(id,name)|json!({"id":id,"name":name})).collect::<Vec<_>>()}),
        ),
        "hosts" => Ok(json!({"t":"hosts","hosts":[{"id":"local","name":"Local Machine"}]})),
        "directories" => {
            let host = text(request, "host")?;
            if host != "local" {
                return Err(io::Error::other(
                    "Mobile gateway only exposes the local machine; run omg +mobile on the SSH server directly",
                ));
            }
            local_directories(request["path"].as_str().unwrap_or(""))
        }
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
            if host != "local" {
                return Err(io::Error::other(
                    "Mobile gateway only exposes the local machine; run omg +mobile on the SSH server directly",
                ));
            }
            let resolved = local_directories(text(request, "path")?)?;
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
                host: "local".into(),
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
    fn saved_projects_expose_only_local_machine_and_ignore_ssh_cloud_entries() {
        let directory =
            std::env::temp_dir().join(format!("omg-mobile-project-{}", record::nonce().unwrap()));
        fs::create_dir(&directory).unwrap();
        let demo_dir = directory.join("demo-local");
        fs::create_dir(&demo_dir).unwrap();
        fs::write(
            directory.join("mobile-projects.json"),
            serde_json::to_vec(&vec![
                SavedProject {
                    id: "mobile-project-ssh".into(),
                    workspace: "workspace-a".into(),
                    host: "ssh-host-demo".into(),
                    path: PathBuf::from("/srv/demo"),
                    name: "demo-ssh".into(),
                },
                SavedProject {
                    id: "mobile-project-local".into(),
                    workspace: "workspace-a".into(),
                    host: "local".into(),
                    path: demo_dir.clone(),
                    name: "demo-local".into(),
                },
            ])
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
        assert!(!projects.contains_key("mobile-project-ssh"));
        let (project, roster) = projects.get("mobile-project-local").unwrap();
        assert_eq!(project.workspace, "workspace-a");
        assert_eq!(project.host, None);
        assert_eq!(roster["workspaceName"], "Alpha");

        let hosts = request(&config, &json!({"t": "hosts"})).unwrap();
        assert_eq!(
            hosts["hosts"],
            json!([{"id": "local", "name": "Local Machine"}])
        );
        let dirs = request(
            &config,
            &json!({"t": "directories", "host": "local", "path": directory.to_string_lossy()}),
        )
        .unwrap();
        assert_eq!(dirs["names"], json!(["demo-local"]));
        assert!(request(
            &config,
            &json!({"t": "directories", "host": "ssh-host-demo", "path": "/"})
        )
        .is_err());
        let _ = fs::remove_dir_all(directory);
    }
}
