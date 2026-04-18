"""Probe rmapi push semantics against the real cloud.

Resolves §16 questions 1 (put --content-only update vs duplicate) and 2
(version field monotonicity under sync15). Intended to be run by hand,
once. Cleans up after itself.

Usage:
    python scripts/cloud_probe.py [--keep] [--remote-folder /rm-sync-test]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
import uuid
from io import BytesIO
from pathlib import Path

# Make 'rm_sync' importable when run from the repo root.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from rmscene import simple_text_document, write_blocks  # type: ignore

from rm_sync.conversion.archive import RmDoc, RmDocPage, new_page_id, pack

RMAPI = str(Path.home() / "bin/rmapi")


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run([RMAPI, *args], capture_output=True, text=True, check=check)


def shell(cmds: str) -> str:
    """Run rmapi-shell commands via stdin (find/stat/ls go this way)."""
    p = subprocess.run(
        [RMAPI], input=cmds, capture_output=True, text=True, timeout=30
    )
    return p.stdout


def stat(path: str) -> dict | None:
    out = shell(f"stat {path}\n")
    # Output starts with banner line; JSON object follows.
    brace = out.find("{")
    end = out.rfind("}")
    if brace < 0 or end < 0:
        return None
    try:
        return json.loads(out[brace : end + 1])
    except json.JSONDecodeError:
        return None


def list_folder(path: str) -> list[tuple[str, str]]:
    """Return [(kind, name), ...] for entries directly under path."""
    out = shell(f"ls {path}\n")
    items: list[tuple[str, str]] = []
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("[d]") or line.startswith("[f]"):
            kind = "d" if line.startswith("[d]") else "f"
            name = line[3:].lstrip("\t ").strip()
            items.append((kind, name))
    return items


def make_text_rmdoc(doc_id: str, name: str, version: int, page_text: str) -> Path:
    """Build a .rmdoc with one typed-text page containing ``page_text``."""
    buf = BytesIO()
    write_blocks(buf, simple_text_document(page_text))
    page_bytes = buf.getvalue()

    out_dir = Path(tempfile.mkdtemp(prefix="rmsync-probe-"))
    archive_path = out_dir / f"{name}.rmdoc"
    pack(
        RmDoc(
            doc_id=doc_id,
            visible_name=name,
            pages=[RmDocPage(page_id=new_page_id(), rm_bytes=page_bytes)],
            version=version,
            last_modified=int(time.time() * 1000),
        ),
        archive_path,
    )
    return archive_path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--remote-folder", default="/rm-sync-test")
    ap.add_argument("--keep", action="store_true", help="don't clean up at end")
    args = ap.parse_args()

    folder = args.remote_folder
    print(f"=== probe folder: {folder} ===")

    doc_id_a = str(uuid.uuid4())
    doc_a_name = f"probe-a-{doc_id_a[:8]}"

    # ── Q1, part 1: plain `put` of a file with a name not yet on the cloud ──
    print(f"\n[1] put {doc_a_name} (initial upload)")
    archive_path = make_text_rmdoc(doc_id_a, doc_a_name, version=1, page_text="content v1\n")
    p = run("put", str(archive_path), folder, check=False)
    print(f"   stdout: {p.stdout.strip()!r}")
    print(f"   stderr: {p.stderr.strip()!r}")
    print(f"   rc:     {p.returncode}")

    listing = list_folder(folder)
    print(f"   listing: {listing}")
    a_meta = stat(f"{folder}/{doc_a_name}")
    print(f"   stat:    {a_meta}")

    # ── Q1, part 2: re-`put` SAME file under SAME name → duplicate? ──
    print(f"\n[2] put {doc_a_name} again (same name, no --content-only)")
    archive_path2 = make_text_rmdoc(doc_id_a, doc_a_name, version=2, page_text="content v2\n")
    p = run("put", str(archive_path2), folder, check=False)
    print(f"   stdout: {p.stdout.strip()!r}")
    print(f"   stderr: {p.stderr.strip()!r}")
    print(f"   rc:     {p.returncode}")
    listing2 = list_folder(folder)
    print(f"   listing: {listing2}")
    duplicates = [n for k, n in listing2 if k == "f" and n.startswith(doc_a_name)]
    print(f"   files matching '{doc_a_name}*': {duplicates}")
    if len(duplicates) == 1:
        m = stat(f"{folder}/{duplicates[0]}")
        print(f"   stat after re-put: {m}")
        if a_meta and m:
            print(
                f"   ID changed?  {a_meta.get('ID') != m.get('ID')}  "
                f"(was {a_meta.get('ID')}, now {m.get('ID')})"
            )
            print(
                f"   Version: {a_meta.get('Version')} → {m.get('Version')}"
            )

    # ── Q1, part 3: `put --content-only` to update an existing doc ──
    # We need an existing doc to target. Use the canonical name from listing.
    existing = duplicates[0] if duplicates else doc_a_name
    print(f"\n[3] put --content-only {folder}/{existing}")
    archive_path3 = make_text_rmdoc(doc_id_a, existing, version=3, page_text="content v3\n")
    p = run("put", "--content-only", str(archive_path3), f"{folder}/{existing}", check=False)
    print(f"   stdout: {p.stdout.strip()!r}")
    print(f"   stderr: {p.stderr.strip()!r}")
    print(f"   rc:     {p.returncode}")
    listing3 = list_folder(folder)
    print(f"   listing: {listing3}")
    m3 = stat(f"{folder}/{existing}")
    print(f"   stat after --content-only: {m3}")

    # ── Q1, part 4: `put --content-only` pointed at PARENT folder ──
    print(f"\n[4] put --content-only {folder}  (target = parent folder)")
    archive_path4 = make_text_rmdoc(doc_id_a, existing, version=4, page_text="content v4\n")
    p = run("put", "--content-only", str(archive_path4), folder, check=False)
    print(f"   stdout: {p.stdout.strip()!r}")
    print(f"   stderr: {p.stderr.strip()!r}")
    print(f"   rc:     {p.returncode}")
    listing4 = list_folder(folder)
    print(f"   listing: {listing4}")

    # ── Q2: version monotonicity ──
    print("\n[5] version trajectory across the run:")
    final = stat(f"{folder}/{existing}")
    print(f"   initial Version: {a_meta.get('Version') if a_meta else '?'}")
    print(f"   final Version:   {final.get('Version') if final else '?'}")

    # ── Cleanup ──
    if not args.keep:
        print(f"\n[cleanup] rm {folder}")
        # Use --no-prompt? Check if rmapi supports it.
        for kind, name in list_folder(folder):
            target = f"{folder}/{name}"
            print(f"   rm {target}")
            run("rm", target, check=False)
        run("rm", folder, check=False)
        print("   done.")
    else:
        print(f"\n[--keep] leaving {folder} for inspection")

    return 0


if __name__ == "__main__":
    sys.exit(main())
