"""Refresh checksums after reviewing changes; requires Git, Python stdlib only."""
from pathlib import Path
import hashlib, json, subprocess

root = Path(__file__).resolve().parents[1]
layout = json.loads((root / "install-layout.json").read_text(encoding="utf-8"))
names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root).decode("utf-8").split("\0")
files = []
for name in sorted(set(names)):
    if not name or name == "install-manifest.json":
        continue
    path = root / name
    if path.is_symlink() or not path.is_file():
        raise SystemExit("Not a regular payload file: " + name)
    data = path.read_bytes()
    try:
        data.decode("utf-8")
        normalize = b"\0" not in data
    except UnicodeDecodeError:
        normalize = False
    digest = hashlib.sha256(data.replace(b"\r\n", b"\n") if normalize else data).hexdigest()
    files.append(dict(path=name, sha256=digest, normalize_lf=normalize))
manifest = dict(schema_version=1, suite_id=layout["suite_id"], files=files)
(root / "install-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
print(json.dumps(dict(suite=layout["suite_id"], files=len(files))))
