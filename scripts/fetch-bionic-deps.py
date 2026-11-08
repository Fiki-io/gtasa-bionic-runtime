#!/usr/bin/env python3
import hashlib
import os
import re
import sys
import urllib.request
from collections import deque

REPOS = [
    ("https://packages.termux.dev/apt/termux-main", "dists/stable/main/binary-aarch64/Packages"),
    ("https://packages.termux.dev/apt/termux-x11", "dists/x11/main/binary-aarch64/Packages"),
]

ROOT_PACKAGES = [
    "hangover-wine",
    "hangover-wowbox64",
    "hangover-libwow64fex",
    "mesa",
    "virglrenderer-android",
    "vulkan-loader-android",
    "pulseaudio",
    "libandroid-shmem",
    "libandroid-spawn",
    "freetype",
    "fontconfig",
    "xorg-xrandr",
]

PREFERRED_ALTERNATIVES = {
    "vulkan-loader-generic": "vulkan-loader-android",
}

SKIP_PACKAGES = {
    "termux-tools",
    "dash",
    "bash",
    "coreutils",
    "command-not-found",
    "debianutils",
    "dos2unix",
    "findutils",
    "gawk",
    "grep",
    "gzip",
    "less",
    "net-tools",
    "patch",
    "procps",
    "psmisc",
    "sed",
    "tar",
    "termux-am",
    "termux-am-socket",
    "termux-Coaching",
    "termux-exec",
    "termux-keyring",
    "termux-licenses",
    "unzip",
    "util-linux",
    "xz-utils",
    "gtk3",
    "adwaita-icon-theme",
    "adwaita-icon-theme-legacy",
    "hicolor-icon-theme",
    "gtk-update-icon-cache",
    "at-spi2-core",
    "shared-mime-info",
    "desktop-file-utils",
    "python",
    "gdbm",
    "readline",
}


def fetch_index():
    pkg_map = {}
    provides_map = {}
    for base_url, rel_path in REPOS:
        url = f"{base_url}/{rel_path}"
        req = urllib.request.Request(url, headers={"User-Agent": "curl/8.0"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            content = resp.read().decode("utf-8", errors="replace")
        for block in content.split("\n\n"):
            if not block.strip():
                continue
            entry = {}
            for line in block.splitlines():
                if ": " in line and not line.startswith(" "):
                    k, v = line.split(": ", 1)
                    entry[k.strip()] = v.strip()
            name = entry.get("Package")
            if not name:
                continue
            entry["BaseUrl"] = base_url
            pkg_map[name] = entry
            provides = entry.get("Provides", "")
            if provides:
                for p in provides.split(","):
                    p_clean = re.sub(r"\(.*?\)", "", p).strip()
                    if p_clean:
                        provides_map.setdefault(p_clean, []).append(name)
    return pkg_map, provides_map


def parse_depends(dep_str):
    if not dep_str:
        return []
    result = []
    for group in dep_str.split(","):
        alternatives = [ re.sub(r"\(.*?\)", "", alt).strip() for alt in group.split("|") ]
        alternatives = [ a for a in alternatives if a ]
        if not alternatives:
            continue
        chosen = alternatives[0]
        for alt in alternatives:
            if alt in PREFERRED_ALTERNATIVES:
                chosen = PREFERRED_ALTERNATIVES[alt]
                break
        result.append(chosen)
    return result


def resolve_dependencies(pkg_map, provides_map, roots):
    resolved = {}
    queue = deque(roots)
    while queue:
        pkg_name = queue.popleft()
        if pkg_name in SKIP_PACKAGES or pkg_name in resolved:
            continue
        if pkg_name not in pkg_map:
            providers = provides_map.get(pkg_name, [])
            if providers:
                pkg_name = providers[0]
                if pkg_name in resolved or pkg_name in SKIP_PACKAGES:
                    continue
            else:
                print(f"WARN: Package '{pkg_name}' not found in index, skipping", file=sys.stderr)
                continue
        entry = pkg_map[pkg_name]
        resolved[pkg_name] = entry
        for dep in parse_depends(entry.get("Depends", "")):
            if dep not in resolved and dep not in SKIP_PACKAGES:
                queue.append(dep)
    return resolved


def download_and_verify(resolved, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for name, entry in sorted(resolved.items()):
        filename = os.path.basename(entry["Filename"])
        dest_path = os.path.join(out_dir, filename)
        expected_sha256 = entry["SHA256"].lower()
        url = f"{entry['BaseUrl']}/{entry['Filename']}"

        if os.path.exists(dest_path):
            h = hashlib.sha256()
            with open(dest_path, "rb") as f:
                for chunk in iter(lambda: f.read(65536), b""):
                    h.update(chunk)
            if h.hexdigest().lower() == expected_sha256:
                print(f"[CACHED] {name} ({filename})")
                continue

        print(f"[DOWNLOADING] {name} -> {filename}")
        req = urllib.request.Request(url, headers={"User-Agent": "curl/8.0"})
        with urllib.request.urlopen(req, timeout=300) as resp, open(dest_path, "wb") as out_f:
            h = hashlib.sha256()
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                out_f.write(chunk)
                h.update(chunk)

        actual_sha256 = h.hexdigest().lower()
        if actual_sha256 != expected_sha256:
            os.remove(dest_path)
            raise RuntimeError(
                f"SHA256 mismatch for {filename}: expected {expected_sha256}, got {actual_sha256}"
            )
    print(f"Successfully downloaded and verified {len(resolved)} Bionic packages.")


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "./debs"
    pkg_map, provides_map = fetch_index()
    resolved = resolve_dependencies(pkg_map, provides_map, ROOT_PACKAGES)
    download_and_verify(resolved, out_dir)


if __name__ == "__main__":
    main()
