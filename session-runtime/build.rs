use std::{env, fs, path::Path, path::PathBuf, process::Command};

fn parse_zig_string_literal(input: &str) -> Result<(String, &str), String> {
    let rest = input
        .strip_prefix('"')
        .ok_or_else(|| "expected opening quote".to_string())?;
    let mut out = String::new();
    let mut chars = rest.char_indices();
    while let Some((idx, ch)) = chars.next() {
        match ch {
            '"' => return Ok((out, &rest[idx + 1..])),
            '\\' => {
                let (_, esc) = chars.next().ok_or_else(|| "unterminated escape".to_string())?;
                match esc {
                    '\\' => out.push('\\'),
                    '"' => out.push('"'),
                    '\'' => out.push('\''),
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    'x' => {
                        let (_, h1) = chars.next().ok_or_else(|| "short hex escape".to_string())?;
                        let (_, h2) = chars.next().ok_or_else(|| "short hex escape".to_string())?;
                        let byte = u8::from_str_radix(&format!("{h1}{h2}"), 16)
                            .map_err(|e| format!("bad hex escape: {e}"))?;
                        out.push(byte as char);
                    }
                    other => return Err(format!("unsupported Zig escape \\{other}")),
                }
            }
            other => out.push(other),
        }
    }
    Err("unterminated Zig string literal".into())
}

fn generate_ghostty_terminfo(src_path: &Path, out_path: &Path) {
    let src = fs::read_to_string(src_path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", src_path.display()));
    let mut names = Vec::new();
    let mut caps = Vec::new();
    let mut section = "";
    for raw_line in src.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with("//") {
            continue;
        }
        if line.starts_with(".names = &.{") {
            section = "names";
            continue;
        }
        if line.starts_with(".capabilities = &.{") {
            section = "caps";
            continue;
        }
        if line == "}," || line == "};" {
            section = "";
            continue;
        }
        match section {
            "names" => {
                if line.starts_with('"') {
                    let (name, _) = parse_zig_string_literal(line)
                        .unwrap_or_else(|e| panic!("bad terminfo name line {line:?}: {e}"));
                    names.push(name);
                }
            }
            "caps" => {
                if let Some(after_name) = line.split(".name = ").nth(1) {
                    let (cap_name, rest) = parse_zig_string_literal(after_name)
                        .unwrap_or_else(|e| panic!("bad terminfo cap name {line:?}: {e}"));
                    let after_val = rest
                        .split(".value = .{ ")
                        .nth(1)
                        .unwrap_or_else(|| panic!("missing .value in {line:?}"));
                    if after_val.starts_with(".boolean") {
                        caps.push(format!("\t{cap_name},"));
                    } else if after_val.starts_with(".canceled") {
                        caps.push(format!("\t{cap_name}@,"));
                    } else if let Some(num_rest) = after_val.strip_prefix(".numeric = ") {
                        let digits: String = num_rest
                            .chars()
                            .take_while(|c| c.is_ascii_digit())
                            .collect();
                        assert!(!digits.is_empty(), "empty numeric in {line:?}");
                        caps.push(format!("\t{cap_name}#{digits},"));
                    } else if let Some(str_rest) = after_val.strip_prefix(".string = ") {
                        let (val, _) = parse_zig_string_literal(str_rest)
                            .unwrap_or_else(|e| panic!("bad terminfo cap str {line:?}: {e}"));
                        caps.push(format!("\t{cap_name}={val},"));
                    } else {
                        panic!("unknown terminfo capability variant: {line:?}");
                    }
                }
            }
            _ => {}
        }
    }
    assert!(
        names.iter().any(|n| n == "xterm-ghostty") && caps.len() > 100,
        "unexpected parsed terminfo counts: names={names:?} caps={}",
        caps.len()
    );
    let mut encoded = format!("{},\n", names.join("|"));
    for cap in caps {
        encoded.push_str(&cap);
        encoded.push('\n');
    }
    fs::write(out_path, encoded).unwrap();
}

fn main() {
    let root = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .parent()
        .unwrap()
        .to_owned();
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let terminfo_src = root.join("src/terminfo/ghostty.zig");
    generate_ghostty_terminfo(&terminfo_src, &out.join("ghostty.terminfo"));
    println!("cargo:rerun-if-changed={}", terminfo_src.display());
    let cc = env::var("OMG_RUNTIME_CC").unwrap_or_else(|_| "cc".into());
    let lib = env::var_os("OMG_VT_LIB_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| root.join("zig-out/lib"));
    println!("cargo:rerun-if-env-changed=OMG_RUNTIME_CC");
    println!("cargo:rerun-if-env-changed=OMG_VT_LIB_DIR");
    assert!(Command::new(cc)
        .args(["-c", "-std=c11", "-Wall", "-Wextra", "-Werror", "src/vt.c", "-o"])
        .arg(out.join("vt.o"))
        .arg(format!("-I{}", root.join("include").display()))
        .status()
        .unwrap()
        .success());
    println!("cargo:rerun-if-env-changed=OMG_RUNTIME_AR");
    assert!(
        Command::new(env::var("OMG_RUNTIME_AR").unwrap_or_else(|_| "ar".into()))
            .arg("crs")
            .arg(out.join("libomg_vt.a"))
            .arg(out.join("vt.o"))
            .status()
            .unwrap()
            .success()
    );
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=omg_vt");
    println!("cargo:rustc-link-search=native={}", lib.display());
    println!("cargo:rustc-link-lib=dylib=ghostty-vt");
    if env::var("CARGO_CFG_TARGET_OS").unwrap() == "linux" {
        println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN");
    } else {
        println!("cargo:rustc-link-arg=-Wl,-rpath,@executable_path");
    }
    // Development tests use the build directory; packaged artifacts find their
    // sibling library first and never depend on the checkout being present.
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib.display());
    println!("cargo:rerun-if-changed=src/vt.c");
    println!("cargo:rerun-if-changed={}", lib.display());
}
