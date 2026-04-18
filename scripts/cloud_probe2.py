"""Round 2: probe `put --force` semantics and version trajectory.

Findings from round 1:
  - --content-only is PDF-only; can't use it for .rmdoc updates
  - plain `put` errors on duplicate name
  - cloud assigns its own Version (the value we packed is ignored)

Round 2 tests:
  - Does `put --force` update in place (preserving doc UUID) or recreate
    with a new UUID?
  - How does Version evolve across multiple --force updates?
  - What does `stat` show on the parent folder across these updates?
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import time
import uuid
from io import BytesIO
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from rmscene import simple_text_document, write_blocks  # type: ignore

from rm_sync.conversion.archive import RmDoc, RmDocPage, new_page_id, pack

RMAPI = str(Path.home() / "bin/rmapi")
FOLDER = "/rm-sync-test"


def run(*args: str, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run([RMAPI, *args], capture_output=True, text=True, check=check)


def shell(cmds: str) -> str:
    p = subprocess.run([RMAPI], input=cmds, capture_output=True, text=True, timeout=30)
    return p.stdout


def stat(path: str) -> dict | None:
    out = shell(f"stat {path}\n")
    brace, end = out.find("{"), out.rfind("}")
    if brace < 0 or end < 0:
        return None
    try:
        return json.loads(out[brace : end + 1])
    except json.JSONDecodeError:
        return None


def list_folder(path: str) -> list[tuple[str, str]]:
    out = shell(f"ls {path}\n")
    items = []
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("[d]") or line.startswith("[f]"):
            kind = "d" if line.startswith("[d]") else "f"
            name = line[3:].lstrip("\t ").strip()
            items.append((kind, name))
    return items


def make_rmdoc(doc_id: str, name: str, page_text: str) -> Path:
    buf = BytesIO()
    write_blocks(buf, simple_text_document(page_text))
    page_bytes = buf.getvalue()
    out_dir = Path(tempfile.mkdtemp(prefix="rmsync-probe2-"))
    out = out_dir / f"{name}.rmdoc"
    pack(
        RmDoc(
            doc_id=doc_id,
            visible_name=name,
            pages=[RmDocPage(page_id=new_page_id(), rm_bytes=page_bytes)],
            version=1,
            last_modified=int(time.time() * 1000),
        ),
        out,
    )
    return out


def main() -> int:
    run("mkdir", FOLDER)  # idempotent enough — no-op if exists
    probe_id = str(uuid.uuid4())
    name = f"probe-force-{probe_id[:8]}"

    print(f"=== probing put --force semantics in {FOLDER} ===\n")

    # 1. Initial upload
    p = run("put", str(make_rmdoc(probe_id, name, "v1\n")), FOLDER)
    print(f"[1] put initial — rc={p.returncode}")
    print(f"    stderr: {p.stderr.strip()!r}")
    initial = stat(f"{FOLDER}/{name}")
    print(f"    stat: ID={initial.get('ID') if initial else '?'} "
          f"Version={initial.get('Version') if initial else '?'} "
          f"Modified={initial.get('ModifiedClient') if initial else '?'}")

    versions: list[tuple[int, str, str]] = []  # (Version, ID, ModifiedClient)
    if initial:
        versions.append((initial["Version"], initial["ID"], initial["ModifiedClient"]))

    # 2-4. Three --force updates with changing content
    for n, content in enumerate(("v2\n", "v3\nmore\n", "v4 final\n"), start=2):
        time.sleep(2)  # give the cloud a beat in case timestamp granularity matters
        p = run("put", "--force", str(make_rmdoc(probe_id, name, content)), FOLDER)
        m = stat(f"{FOLDER}/{name}")
        print(f"\n[{n}] put --force ({content.strip()!r}) — rc={p.returncode}")
        print(f"    stderr: {p.stderr.strip()!r}")
        print(f"    stat: ID={m.get('ID') if m else '?'} "
              f"Version={m.get('Version') if m else '?'} "
              f"Modified={m.get('ModifiedClient') if m else '?'}")
        if m:
            versions.append((m["Version"], m["ID"], m["ModifiedClient"]))

        # Are there now multiple files with this base name?
        siblings = [n for k, n in list_folder(FOLDER) if k == "f" and n.startswith(name)]
        print(f"    files with prefix '{name}': {siblings}")

    # 5. Pull it back and compare content to last upload
    print("\n[5] verifying: pull doc back and compare its single page")
    with tempfile.TemporaryDirectory(prefix="rmsync-pull-") as td:
        p = run("get", f"{FOLDER}/{name}")
        # rmapi get writes to cwd by default; let's use cd-then-get via subprocess cwd
        # (re-run with cwd)
        p = subprocess.run(
            [RMAPI, "get", f"{FOLDER}/{name}"],
            capture_output=True, text=True, cwd=td,
        )
        print(f"    rc={p.returncode}")
        print(f"    stderr: {p.stderr.strip()!r}")
        archives = list(Path(td).glob("*.rmdoc"))
        print(f"    downloaded: {[a.name for a in archives]}")
        if archives:
            from rm_sync.conversion.archive import unpack
            from rm_sync.conversion.rm_to_md import page_to_markdown
            d = unpack(archives[0])
            print(f"    unpacked: doc_id={d.doc_id} pages={len(d.pages)} version_in_meta={d.version}")
            for i, page in enumerate(d.pages):
                md = page_to_markdown(page.rm_bytes)
                print(f"    page {i} text: {md!r}")

    # Summary
    print("\n=== version trajectory ===")
    for v, i, m in versions:
        print(f"  Version={v}  ID={i}  Modified={m}")
    monotonic = all(versions[i][0] <= versions[i + 1][0] for i in range(len(versions) - 1))
    print(f"  monotonic: {monotonic}")
    same_id = len({i for _, i, _ in versions}) == 1
    print(f"  ID stable across --force updates: {same_id}")

    # Cleanup
    print(f"\n[cleanup] rm {FOLDER}/{name}")
    run("rm", f"{FOLDER}/{name}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
