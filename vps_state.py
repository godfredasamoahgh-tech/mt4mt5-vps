#!/usr/bin/env python3
"""Deploy/restore MT4+MT5 wine profiles for the self-healing VPS.

Design: NEVER restore a full binary snapshot (corruption risk). Instead:
  1. FRESH INSTALL of MT4/MT5 every boot (deterministic, bulletproof)
  2. Overlay user state from the state branch (config/profiles/EAs/globalvars)
  3. Health-check → journal log proof that terminals are up
User state dirs (per terminal):
  <prefix>/drive_c/Program Files/MetaTrader 5/profiles/   (charts, templates)
  <prefix>/drive_c/Program Files/MetaTrader 5/MQL5/       (EAs, indicators)
  <prefix>/drive_c/Program Files/MetaTrader 5/config/     (logins, common.ini)
  + config/*.dat account keys, gvariables
"""
import os, sys, json, time, urllib.request, urllib.error, base64, hashlib

TOK = os.environ["GH_TOKEN"]
REPO = os.environ["GITHUB_REPOSITORY"]
BRANCH = "state"
API = f"https://api.github.com/repos/{REPO}"
H = {"Authorization": f"Bearer {TOK}", "Accept": "application/vnd.github+json"}

def gh(method, path, payload=None, raw=False):
    req = urllib.request.Request(f"{API}/{path}", method=method,
        data=json.dumps(payload).encode() if payload else None, headers=H)
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
        return (data if raw else json.loads(data or b"{}"))

# ---- state push helpers (capless per boss order; loud skip warnings) ----
SKIP_FILES = {".env", "gateway.log", "nohup.out"}
SKIP_DIRS = {"__pycache__", ".cache", "node_modules", "tmp", "crashes", "logs", "Logs"}
PUSHABLE_EXT = {".dat", ".ini", ".chr", ".tpl", ".hst", ".mq4", ".ex4", ".mq5", ".ex5",
                ".set", ".json", ".yaml", ".yml", ".md", ".txt", ".hcc", ".hcd"}
STATE_ROOT = os.environ.get("VPS_STATE", os.path.expanduser("~/vps-state"))

def iter_state_files():
    for root, dirs, files in os.walk(STATE_ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if f in SKIP_FILES or not any(f.endswith(e) for e in PUSHABLE_EXT):
                continue
            p = os.path.join(root, f)
            try:
                sz = os.path.getsize(p)
                if sz > 90 * 1024 * 1024:
                    print(f"[state] BIG-FILE {f} ({sz}) over blob API limit — push will fail per-file", flush=True)
                with open(p, "rb") as fh:
                    yield os.path.relpath(p, STATE_ROOT).replace(os.sep, "/"), fh.read()
            except OSError:
                continue

def push_cycle():
    head = gh("GET", f"git/ref/heads/{BRANCH}")["object"]["sha"]
    commit = gh("GET", f"git/commits/{head}")
    base_tree = commit["tree"]["sha"]
    manifest = {}
    try:
        d = gh("GET", f"contents/vps-manifest.json?ref={BRANCH}")
        manifest = json.loads(base64.b64decode(d["content"]).decode())
    except Exception:
        pass
    changes = []
    for rel, data in iter_state_files():
        digest = hashlib.sha256(data).hexdigest()
        if manifest.get(rel) == digest:
            continue
        b = gh("POST", "git/blobs", {"content": base64.b64encode(data).decode(), "encoding": "base64"})
        changes.append((rel, b["sha"], digest))
    if not changes:
        return 0
    bt = gh("GET", f"git/trees/{base_tree}?recursive=1")
    items = [{"path": it["path"], "mode": "100644", "type": "blob", "sha": it["sha"]}
             for it in bt.get("tree", []) if it["type"] == "blob" and it["path"].startswith("vps-state/")]
    path_set = {i["path"] for i in items}
    for rel, bsha, digest in changes:
        p = f"vps-state/{rel}"
        hit = False
        for i in items:
            if i["path"] == p:
                i["sha"] = bsha; hit = True
        if not hit:
            items.append({"path": p, "mode": "100644", "type": "blob", "sha": bsha})
        manifest[rel] = digest
    mdata = json.dumps(manifest).encode()
    mb = gh("POST", "git/blobs", {"content": base64.b64encode(mdata).decode(), "encoding": "base64"})
    mp = "vps-manifest.json"
    hit = False
    for i in items:
        if i["path"] == mp:
            i["sha"] = mb["sha"]; hit = True
    if not hit:
        items.append({"path": mp, "mode": "100644", "type": "blob", "sha": mb["sha"]})
    tree = gh("POST", "git/trees", {"tree": items, "base_tree": base_tree})
    c = gh("POST", "git/commits", {"message": f"vps-state: {len(changes)} files",
                                   "tree": tree["sha"], "parents": [head]})
    gh("PATCH", f"git/refs/heads/{BRANCH}", {"sha": c["sha"], "force": False})
    print(f"[state] pushed {len(changes)} files", flush=True)
    return len(changes)

def restore_state():
    """Download vps-state/* from state branch into STATE_ROOT."""
    try:
        tree = gh("GET", f"git/trees/{BRANCH}?recursive=1")
    except Exception as e:
        print("[state] no state branch yet — first boot", flush=True)
        return 0
    n = 0
    for it in tree.get("tree", []):
        if it["type"] != "blob" or not it["path"].startswith("vps-state/"):
            continue
        rel = it["path"][len("vps-state/"):]
        try:
            d = gh("GET", f"contents/vps-state/{rel}?ref={BRANCH}")
            raw = base64.b64decode(d["content"])
        except Exception as e:
            print(f"[state] skip {rel}: {e}", flush=True)
            continue
        dest = os.path.join(STATE_ROOT, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as fh:
            fh.write(raw)
        n += 1
    print(f"[state] restored {n} files", flush=True)
    return n

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "push"
    os.makedirs(STATE_ROOT, exist_ok=True)
    if cmd == "push":
        while True:
            try:
                push_cycle()
            except Exception as e:
                print(f"[state] cycle error: {e}", flush=True)
            time.sleep(int(os.environ.get("STATE_PUSH_INTERVAL", "120")))
    elif cmd == "restore":
        restore_state()
