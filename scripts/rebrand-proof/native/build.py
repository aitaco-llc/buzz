#!/usr/bin/env python3
"""Build the private Rebrand integration outside Buzz's OSS workspace."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tomllib

source = Path(os.environ["REBRAND_SOURCE"]).resolve()
here = Path(__file__).resolve().parent
build = Path(os.environ["NATIVE_BUILD_DIR"]).resolve()
build.mkdir(parents=True, exist_ok=True)
root = tomllib.loads((source / "Cargo.toml").read_text())["workspace"]

def toml(value):
    if isinstance(value, dict):
        return "{ " + ", ".join(f"{json.dumps(k)} = {toml(v)}" for k, v in value.items()) + " }"
    return json.dumps(value)

# Resolve the two source manifests locally, without consulting the private
# published registry or changing the shared Rebrand checkout.
for name in ("of", "of-agent"):
    original = source / "crates" / name
    metadata = tomllib.loads((original / "Cargo.toml").read_text())
    local = build / name
    local.mkdir(exist_ok=True)
    lines = ["[package]", f'name = "{name}"', f'version = {toml(root["package"]["version"])}',
             f'edition = {toml(root["package"]["edition"])}', "[lib]",
             f'path = {toml(str(original / "src/lib.rs"))}']
    for section in ("dependencies", "dev-dependencies"):
        lines.append(f"[{section}]")
        for dep, value in metadata.get(section, {}).items():
            if isinstance(value, dict) and value.get("workspace"):
                value = root["dependencies"][dep]
            if dep == "of":
                value = {"path": str(build / "of")}
            lines.append(f"{json.dumps(dep)} = {toml(value)}")
    (local / "Cargo.toml").write_text("\n".join(lines) + "\n")
manifest = f'''[package]
name = "buzz-rebrand-proof"
version = "0.1.0"
edition = "2024"
[workspace]
[[bin]]
name = "buzz-rebrand-proof"
path = {json.dumps(str(here / "main.rs"))}
[dependencies]
of = {{ path = {json.dumps(str(build / "of"))} }}
of-agent = {{ path = {json.dumps(str(build / "of-agent"))} }}
anyhow = "1"
async-trait = "0.1"
serde = {{ version = "1", features = ["derive"] }}
serde_json = "1"
tokio = {{ version = "1", features = ["full"] }}
reqwest = {{ version = "0.13", default-features = false, features = ["json", "rustls"] }}
nostr = "0.44"
base64 = "0.22"
sha2 = "0.10"
uuid = {{ version = "1", features = ["v4"] }}
'''
(build / "Cargo.toml").write_text(manifest)
subprocess.run(["cargo", *sys.argv[1:], "--manifest-path", str(build / "Cargo.toml")], check=True)
