//! Stamp the build's commit into the binary, so a running bridge can say what
//! it was built from (`--version`, and the `build_sha` field on every log).
//!
//! `VOICE_BRIDGE_BUILD_SHA` overrides it for builds made outside a checkout.

use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=VOICE_BRIDGE_BUILD_SHA");
    let sha = std::env::var("VOICE_BRIDGE_BUILD_SHA")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .map(|value| value.trim().to_owned())
        .or_else(git_sha)
        .unwrap_or_else(|| "unknown".to_owned());
    println!("cargo:rustc-env=BUILD_SHA={sha}");
}

fn git_sha() -> Option<String> {
    let dir = env!("CARGO_MANIFEST_DIR");
    // Rebuild when the commit or the working tree moves. Without these, cargo
    // caches this script's output and the stamped sha goes stale silently.
    for path in ["HEAD", "index"] {
        if let Some(path) = git(dir, &["rev-parse", "--git-path", path]) {
            println!("cargo:rerun-if-changed={path}");
        }
    }
    let sha = git(dir, &["rev-parse", "--short=12", "HEAD"])?;
    let dirty = git(dir, &["status", "--porcelain", "--untracked-files=no"])
        .is_some_and(|status| !status.is_empty());
    Some(if dirty { format!("{sha}-dirty") } else { sha })
}

fn git(dir: &str, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}
