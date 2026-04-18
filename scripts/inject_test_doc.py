"""Upload a test .rmdoc into /Writing for end-to-end daemon testing."""

from __future__ import annotations

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


def main() -> int:
    name = sys.argv[1] if len(sys.argv) > 1 else "daemon-test-note"
    text = sys.argv[2] if len(sys.argv) > 2 else "hello from the cloud\nline two\nline three\n"
    folder = sys.argv[3] if len(sys.argv) > 3 else "/Writing"

    buf = BytesIO()
    write_blocks(buf, simple_text_document(text))

    out_dir = Path(tempfile.mkdtemp(prefix="rmsync-inject-"))
    out = out_dir / f"{name}.rmdoc"
    pack(
        RmDoc(
            doc_id=str(uuid.uuid4()),
            visible_name=name,
            pages=[RmDocPage(page_id=new_page_id(), rm_bytes=buf.getvalue())],
            version=1,
            last_modified=int(time.time() * 1000),
        ),
        out,
    )
    p = subprocess.run([RMAPI, "put", "--force", str(out), folder], capture_output=True, text=True)
    print(f"rc={p.returncode}  stderr={p.stderr.strip()!r}  stdout={p.stdout.strip()!r}")
    return p.returncode


if __name__ == "__main__":
    sys.exit(main())
