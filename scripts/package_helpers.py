"""Build or verify the source-only helper downloads. No directory globbing."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
WINDOWS_FILES = (
    ".gitignore", "README.txt", "Start Companion.cmd", "Start-Companion.ps1",
    "check_install.py", "companion.py", "identity.py", "reports.py",
    "requirements.txt", "requirements-windows.lock.txt", "test_companion.py",
    "test_identity.py",
)
CLOUD_FILES = (
    ".gitignore", "RENDER-SETUP.txt", "START-HERE.txt", "TEST-CHECKLIST.txt",
    "core.py", "render_server.py", "requirements.txt", "server.py",
    "test_cloud.py", "test_render.py", "web_apple.py", "web_life360.py", "test_life360.py",
)


def manifests():
    windows = {name: "Companion/" + name for name in WINDOWS_FILES}
    cloud = {"CloudFindMy/" + name: "CloudFindMy/" + name for name in CLOUD_FILES}
    cloud.update({"Companion/" + name: "Companion/" + name
                  for name in ("companion.py", "identity.py", "reports.py")})
    windows["LICENSE"] = cloud["LICENSE"] = "LICENSE"
    return {"Shift-Windows-Helper": windows, "Shift-FindMy-Cloud": cloud}


def expected_files(root, name, manifest):
    expected = {}
    root = root.resolve()
    for destination, source in manifest.items():
        path = root / source
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ValueError("Helper source must be a regular file inside the repository")
        # Git checkouts can use LF or CRLF. Keep downloads identical on every
        # platform, with CRLF only for the Windows command launcher.
        contents = path.read_bytes().replace(b"\r\n", b"\n")
        if path.suffix == ".cmd":
            contents = contents.replace(b"\n", b"\r\n")
        expected[name + "/" + destination] = contents
    return expected


def verify(path, expected):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or set(names) != set(expected):
            raise ValueError("Helper archive contains extra, missing, or duplicate files")
        if archive.testzip() is not None:
            raise ValueError("Helper archive is damaged")
        for name, contents in expected.items():
            if archive.read(name) != contents:
                raise ValueError("Helper archive differs from distributable source")


def package(root=ROOT, check=False):
    for name, manifest in manifests().items():
        expected = expected_files(root, name, manifest)
        path = root / "Locus/Resources" / (name + ".zip")
        if not check:
            # Fixed metadata excludes local file timestamps and owner attributes.
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for filename, contents in sorted(expected.items()):
                    info = zipfile.ZipInfo(filename, date_time=(1980, 1, 1, 0, 0, 0))
                    info.compress_type = zipfile.ZIP_DEFLATED
                    info.create_system = 3
                    info.external_attr = 0o100644 << 16
                    archive.writestr(info, contents)
        verify(path, expected)
        print(f"Verified {name}: {len(expected)} source files; no extra archive entries.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify existing downloads without writing")
    args = parser.parse_args()
    try:
        package(check=args.check)
    except (OSError, ValueError, zipfile.BadZipFile):
        print("Helper packaging failed. Review the source and run python3 scripts/package_helpers.py.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
