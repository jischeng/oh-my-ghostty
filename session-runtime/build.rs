use std::{env, path::PathBuf, process::Command};
fn main() {
    let root = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .parent()
        .unwrap()
        .to_owned();
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
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
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib.display());
    if env::var("CARGO_CFG_TARGET_OS").unwrap() == "linux" {
        println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN");
    }
    println!("cargo:rerun-if-changed=src/vt.c");
    println!("cargo:rerun-if-changed={}", lib.display());
}
