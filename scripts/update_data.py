#!/usr/bin/env python3
"""Daily data update for Gold Compass (driver of scripts/update-data.sh; stdlib only).

Checks the upstream data sources once a day, rebuilds only the generated Data/ files that depend on a source that changed, runs the
gates (luacheck, busted, audit score, personal-data scan, load test) in a temporary copy of the repo, and only when every gate passes
copies the result into the repo, commits, deploys to the gaming PC (scripts/deploy.sh) and pushes to origin. A failure leaves the repo
exactly as it was (the build never touches it) and sends a notification.

Sources (last seen state in ~/.cache/goldcompass/state.json):
  foreverdb       foreverdb.net/downloads/addon-manifest.json (data version)   -> foreverdb, skinning, gather, reagents, fixes
  wowforever      wowforever.be recipe pages + fishing page (hash of each)      -> trainers, gather
  lpdb            LibProfessionDB release on CurseForge (via api.cfwidget.com)  -> lpdb, trainers
  forever_ledger  latest commit of github.com/ivellos/forever-ledger            -> data
  pfquest         latest commit of github.com/shagu/pfQuest                     -> npcs, foreverdb, reagents
  ProfessionsTracker 1.2.0 (Thork): CurseForge only, no machine-readable release -> pinned copy in ~/.cache/goldcompass/inputs/
Politeness: generic User-Agent, 1.2 to 2 s between requests to the same site; robots.txt of both sites allows these paths.
"""
import argparse, datetime, difflib, fcntl, filecmp, hashlib, json, logging, logging.handlers, os, pathlib, re, shutil, subprocess
import sys, tempfile, time, urllib.error, urllib.request, zipfile

REPO = pathlib.Path(__file__).resolve().parent.parent
HOME = pathlib.Path.home()
CACHE_HOME = HOME / ".cache" / "goldcompass"
INPUTS = CACHE_HOME / "inputs"
STATE_FILE = CACHE_HOME / "state.json"
LOCK_FILE = CACHE_HOME / "lock"
PATTERN_FILE = CACHE_HOME / "personal-patterns.txt"      # regex of personal data; kept out of the repo on purpose
LOG_DIR = HOME / "Library" / "Logs" / "GoldCompass"
LOG_FILE = LOG_DIR / "data-update.log"
UA = "GoldCompass-data-build/1.0 (personal addon data build; credit: Data from ForeverDB.net)"
TOOLS_CACHE = ["cache-foreverdb", "cache-wowforever", "cache-pfquest"]
PT_VERSION = "1.2.0"
CHECK_EVERY_H = 20          # source check about once a day, although launchd also wakes the job hourly (pending-deploy retry)
PAGE_MAX_AGE_D = 7          # item pages are re-downloaded at most weekly, and only when ForeverDB data changed
LPDB_CF_PROJECT = 1558781
FOREVERDB_FILES = ["NPCs", "Recipes", "Meta", "QuestForever", "Gather", "Items", "Zones", "Favor"]
WF_BASE = "https://wowforever.be/tradeskills/forever/{}/recipes/"
WF_SLUGS = ["alchemy", "blacksmithing", "cooking", "enchanting", "engineering", "first-aid", "fishing", "leatherworking", "mining",
            "tailoring", "skinning", "herbalism"]
WF_FISHING_PAGE = "https://wowforever.be/tradeskills/forever/fishing/"
PFQ_FILES = {"units.lua": "db/units.lua", "units-fr.lua": "db/frFR/units.lua", "enUS-units.lua": "db/enUS/units.lua",
             "enUS-items.lua": "db/enUS/items.lua", "meta.lua": "db/meta.lua", "enUS-zones.lua": "db/enUS/zones.lua",
             "frFR-zones.lua": "db/frFR/zones.lua"}
FL_FILES = ["ForeverCrafts.lua", "ClassicRecipes.lua", "ClassicItems.lua", "QuestItems.lua"]
SOURCE_NAMES = {"foreverdb": "ForeverDB", "wowforever": "wowforever.be", "lpdb": "LibProfessionDB", "forever_ledger": "Forever Ledger",
                "pfquest": "pfQuest"}

# generator -> (sources it reads, generators whose output it reads). Listed in dependency order.
GENERATORS = {
    "data": ({"forever_ledger"}, set()),
    "lpdb": ({"lpdb"}, {"data"}),
    "trainers": ({"wowforever", "lpdb"}, {"data"}),
    "npcs": ({"pfquest"}, {"data", "lpdb", "trainers"}),
    "foreverdb": ({"foreverdb", "pfquest"}, {"data", "lpdb", "npcs"}),
    "fixes": ({"foreverdb"}, {"data", "lpdb", "trainers", "npcs", "foreverdb"}),
    "skinning": ({"foreverdb"}, set()),
    "gather": ({"foreverdb", "wowforever"}, set()),
    "reagents": ({"foreverdb", "pfquest"}, {"data", "lpdb"}),
}
# files a successful run may change in the repo: generated data and the version constants the run bumps
OUTPUT_GLOBS = ["Data/*.lua", "tools/build-data.py", "tools/build-lpdb.lua", "NOTICE"]

log = logging.getLogger("goldcompass")


class GateFailed(Exception):
    pass


# ----------------------------------------------------------------------------------------------------------------- plumbing
def setup_logging(verbose):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    fh = logging.handlers.RotatingFileHandler(LOG_FILE, maxBytes=1_000_000, backupCount=1, encoding="utf-8")   # capped at ~1 MB (+1 old)
    fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S"))
    log.addHandler(fh)
    if verbose:
        sh = logging.StreamHandler(sys.stdout)
        sh.setFormatter(logging.Formatter("%(message)s"))
        log.addHandler(sh)
    log.setLevel(logging.INFO)


def notify(msg):
    log.info("NOTIFY: %s", msg)
    if os.environ.get("GC_NO_NOTIFY"):
        return
    tn = shutil.which("terminal-notifier", path=env_with_path()["PATH"])
    cmd = [tn, "-title", "Gold Compass", "-message", msg, "-group", "goldcompass-data-update"] if tn else \
        ["osascript", "-e", 'display notification "%s" with title "Gold Compass"' % msg.replace("\\", "\\\\").replace('"', '\\"')]
    try:
        subprocess.run(cmd, timeout=20, capture_output=True)
    except Exception as e:                       # a missing notification must never break the run
        log.warning("notification failed: %s", e)


def load_state():
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_state(state):
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(STATE_FILE)


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def env_with_path():
    env = dict(os.environ)
    extra = [str(HOME / ".luarocks54" / "bin"), "/opt/homebrew/bin", "/usr/local/bin"]
    env["PATH"] = ":".join(extra + [p for p in env.get("PATH", "/usr/bin:/bin").split(":") if p not in extra])
    return env


def run(cmd, cwd=None, timeout=180, check=True, stdout_file=None):
    """Runs a command; one running for more than `timeout` seconds is killed. Output tail goes to the log."""
    log.info("$ %s", " ".join(str(c) for c in cmd))
    try:
        p = subprocess.run([str(c) for c in cmd], cwd=cwd, timeout=timeout, capture_output=True, text=True, env=env_with_path())
    except subprocess.TimeoutExpired:
        raise GateFailed(f"timeout after {timeout}s: {' '.join(str(c) for c in cmd[:3])}")
    out = (p.stdout or "") + (p.stderr or "")
    tail = "\n".join(out.strip().splitlines()[-12:])
    if tail:
        log.info("%s", tail)
    if check and p.returncode != 0:
        raise GateFailed(f"{' '.join(pathlib.Path(str(c)).name for c in cmd[:3])} exited {p.returncode}")
    if stdout_file is not None and p.returncode == 0:
        pathlib.Path(stdout_file).write_text(p.stdout, encoding="utf-8")
    return p


def http_get(url, headers=None, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def atomic_write(path, data):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".part")
    tmp.write_bytes(data)
    tmp.replace(path)


# ------------------------------------------------------------------------------------------------- change detection
def detect():
    """{source: info} of the upstream state now. A source that cannot be reached is left out (its last seen state is kept)."""
    found = {}
    try:
        manifest = json.loads(http_get("https://foreverdb.net/downloads/addon-manifest.json"))
        found["foreverdb"] = {"version": manifest["data"]["version"], "manifest": manifest}
    except Exception as e:
        log.warning("ForeverDB manifest unreachable: %s", e)
    try:
        files = json.loads(http_get(f"https://api.cfwidget.com/{LPDB_CF_PROJECT}"))["files"]
        latest = max((f for f in files if f.get("type", "release") == "release"), key=lambda f: f["uploaded_at"])
        found["lpdb"] = {"version": latest["display"], "id": latest["id"], "name": latest["name"],
                         "tag": re.search(r"v[\d.]+$", latest["display"]).group(0)}
    except Exception as e:
        log.warning("LibProfessionDB release unreachable: %s", e)
    for key, repo, ref in (("forever_ledger", "ivellos/forever-ledger", "HEAD"), ("pfquest", "shagu/pfQuest", "master")):
        try:
            sha = http_get(f"https://api.github.com/repos/{repo}/commits/{ref}", {"Accept": "application/vnd.github.sha"}).decode().strip()
            if re.fullmatch(r"[0-9a-f]{40}", sha):
                found[key] = {"version": sha}
        except Exception as e:
            log.warning("%s latest commit unreachable: %s", repo, e)
    pages, ok = {}, True
    for n, slug in enumerate(WF_SLUGS + ["fishing-page"]):
        if n:
            time.sleep(2)                       # polite: one request per page, two seconds apart
        try:
            pages[slug] = http_get(WF_FISHING_PAGE if slug == "fishing-page" else WF_BASE.format(slug))
        except urllib.error.HTTPError as e:     # a profession without a recipe page: normal, recorded as such
            pages[slug] = None
            log.info("wowforever.be %s: HTTP %s", slug, e.code)
        except Exception as e:
            log.warning("wowforever.be %s unreachable: %s", slug, e)
            ok = False
    if ok:
        digest = {k: hashlib.sha256(v).hexdigest() if v else None for k, v in sorted(pages.items())}
        found["wowforever"] = {"version": hashlib.sha256(json.dumps(digest).encode()).hexdigest()[:12], "pages": pages}
    return found


def slim(info):
    return {k: v for k, v in info.items() if k not in ("manifest", "pages")}


def short(src, info):
    v = info["version"]
    return info.get("tag", v) if src == "lpdb" else v[:10] if src == "foreverdb" else v[:7]


# --------------------------------------------------------------------------------------------------- input fetching
def ensure_foreverdb(info):
    cache = REPO / "tools" / "cache-foreverdb"
    manifest = info["manifest"]
    atomic_write(cache / "addon-manifest.json", json.dumps(manifest).encode())
    by_path = {f["path"]: f for f in manifest["data"]["files"]}
    for name in FOREVERDB_FILES:
        entry, path = by_path[f"Data/{name}.lua"], cache / f"{name}.lua"
        if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"]:
            continue
        time.sleep(1)                           # polite: one small file per second
        body = http_get("https://foreverdb.net/" + entry["url"])
        if hashlib.sha256(body).hexdigest() != entry["sha256"]:
            raise GateFailed(f"{name}.lua: SHA-256 differs from the manifest")
        atomic_write(path, body)
        log.info("downloaded %s.lua (%d bytes)", name, len(body))


def wanted_item_ids():
    ids = set()
    for name in ("Recipes.lua", "ForeverRecipes.lua"):
        for grp in re.findall(r'"((?:\d+:\d+,?)+)"', (REPO / "Data" / name).read_text(encoding="utf-8")):
            ids.update(int(a) for a, _ in re.findall(r"(\d+):(\d+)", grp))
    ids.update(int(i) for i in re.findall(r"^\s+(\d+): \(", (REPO / "tools" / "build-skinning.py").read_text(encoding="utf-8"), re.M))
    return sorted(ids)


def ensure_item_pages(refresh):
    """ForeverDB item pages read by build-skinning and build-reagent-sources: the missing ones, and (after a data change) a weekly refresh."""
    pages = REPO / "tools" / "cache-foreverdb" / "pages"
    pages.mkdir(parents=True, exist_ok=True)
    if os.environ.get("GC_SKIP_PAGES"):          # test hook: use the cached pages as they are
        return
    todo = []
    for item in wanted_item_ids():
        p = pages / f"item{item}.html"
        if not p.exists() or p.stat().st_size < 10000 or (refresh and time.time() - p.stat().st_mtime > PAGE_MAX_AGE_D * 86400):
            todo.append((item, p))
    log.info("item pages to download: %d", len(todo))
    deadline = time.time() + 25 * 60            # an empty cache needs ~12 minutes; never more than 25
    for n, (item, p) in enumerate(todo):
        if time.time() > deadline:
            log.warning("item pages: time budget reached, %d left for the next run", len(todo) - n)
            break
        time.sleep(1.2)                         # polite: at most one page a second (robots.txt allows /item/)
        try:
            atomic_write(p, http_get(f"https://foreverdb.net/item/{item}", timeout=30))
        except Exception as e:                  # a missing page is a finding, not a failure
            log.info("item %s: %s", item, e)


def ensure_wowforever(info):
    for slug, body in info["pages"].items():
        if body:
            atomic_write(REPO / "tools" / "cache-wowforever" / f"{slug}.html", body)


def ensure_lpdb(info):
    dest = INPUTS / f"ProfessionDB-{info['id']}"
    lib = dest / "ProfessionDB"
    if (lib / "LibProfessionDB-1.0.lua").exists():
        return lib
    i = info["id"]
    zpath = INPUTS / f"ProfessionDB-{i}.zip"
    atomic_write(zpath, http_get(f"https://mediafilez.forgecdn.net/files/{i // 1000}/{i % 1000}/{info['name']}", timeout=120))
    shutil.rmtree(dest, ignore_errors=True)
    with zipfile.ZipFile(zpath) as z:
        z.extractall(dest)                      # zipfile drops absolute and ".." members
    zpath.unlink()
    if not (lib / "LibProfessionDB-1.0.lua").exists():
        raise GateFailed("LibProfessionDB archive has an unexpected layout")
    return lib


def ensure_forever_ledger(sha):
    dest = INPUTS / f"forever-ledger-{sha[:12]}"
    for f in FL_FILES:
        if not (dest / f).exists():
            atomic_write(dest / f, http_get(f"https://raw.githubusercontent.com/ivellos/forever-ledger/{sha}/{f}", timeout=120))
    return dest


def ensure_pfquest(sha):
    dest = INPUTS / f"pfquest-{sha[:12]}"
    for local, remote in PFQ_FILES.items():
        if not (dest / local).exists():
            atomic_write(dest / local, http_get(f"https://raw.githubusercontent.com/shagu/pfQuest/{sha}/{remote}", timeout=180))
    items = REPO / "tools" / "cache-pfquest" / "items.lua"       # read by build-reagent-sources
    stamp = items.with_suffix(".sha")
    if not items.exists() or not stamp.exists() or stamp.read_text() != sha:
        atomic_write(items, http_get(f"https://raw.githubusercontent.com/shagu/pfQuest/{sha}/db/items.lua", timeout=180))
        stamp.write_text(sha)
    return dest


def pt_dir():
    d = INPUTS / f"ProfessionTracker-{PT_VERSION}"
    if not (d / "Data.lua").exists() or not (d / "Data2.lua").exists():
        raise GateFailed(f"ProfessionsTracker {PT_VERSION} (Data.lua, Data2.lua) is missing from {d}: it has no machine-readable "
                         "release, copy the unzipped addon folder there by hand")
    return d


# ------------------------------------------------------------------------------------------------------- the build
def make_workspace():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="goldcompass-build-"))
    for c in TOOLS_CACHE:
        (REPO / "tools" / c).mkdir(exist_ok=True)
    subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=__pycache__"] + [f"--exclude=tools/{c}" for c in TOOLS_CACHE]
                   + [f"{REPO}/", f"{tmp}/"], check=True)
    for c in TOOLS_CACHE:
        (tmp / "tools" / c).symlink_to(REPO / "tools" / c)
    return tmp


def sub_line(path, pattern, repl):
    text = path.read_text(encoding="utf-8")
    new, n = re.subn(pattern, repl, text, count=1, flags=re.M)
    if n != 1:
        raise GateFailed(f"{path.name}: version line not found")
    path.write_text(new, encoding="utf-8")


def plan(changed, force):
    todo = set(GENERATORS) if force else {g for g, (srcs, _) in GENERATORS.items() if srcs & changed}
    grew = True
    while grew:                                  # the dependants of every generator that runs
        grew = False
        for g, (_, ups) in GENERATORS.items():
            if g not in todo and ups & todo:
                todo.add(g)
                grew = True
    return [g for g in GENERATORS if g in todo]


def generate(tmp, todo, v, inputs):
    py = ["python3", "-I"]
    if "data" in todo:
        sub_line(tmp / "tools/build-data.py", r'^SHA = "[0-9a-f]{40}"', f'SHA = "{v["forever_ledger"]["version"]}"')
        run(py + ["tools/build-data.py", "--pt", pt_dir(), "--fl", inputs["forever_ledger"]], cwd=tmp)
    if "lpdb" in todo:
        tag = v["lpdb"]["tag"]
        sub_line(tmp / "tools/build-lpdb.lua", r'^local VERSION, BUILD = "v[\d.]+"', f'local VERSION, BUILD = "{tag}"')
        run(["lua", "tools/build-lpdb.lua", inputs["lpdb"]], cwd=tmp, stdout_file=tmp / "Data/ForeverRecipes.lua")
        notice = tmp / "NOTICE"
        notice.write_text(re.sub(r"(Data/ForeverRecipes\.lua vendors the WoW Forever data of LibProfessionDB )v[\d.]+", rf"\g<1>{tag}",
                                 notice.read_text(encoding="utf-8")), encoding="utf-8")
    if "trainers" in todo:
        run(py + ["tools/fetch-wowforever.py", "--cached", "--lpdb", inputs["lpdb"] / "Data" / "Forever" / "_core"], cwd=tmp)
    if "npcs" in todo:
        run(py + ["tools/build-npcs.py", inputs["pfquest"]], cwd=tmp)
    if "foreverdb" in todo:
        run(py + ["tools/build-foreverdb.py", "--pfq", inputs["pfquest"]], cwd=tmp)
        meta = dict(re.findall(r'(\w+)="([^"]*)"', (REPO / "tools/cache-foreverdb/Meta.lua").read_text(encoding="utf-8")))
        if meta.get("build") and meta.get("version"):
            notice = tmp / "NOTICE"
            notice.write_text(re.sub(r"game build [\d.]+, data version [\d-]+", f"game build {meta['build']}, data version {meta['version']}",
                                     notice.read_text(encoding="utf-8"), count=1), encoding="utf-8")
    if "fixes" in todo:
        run(["lua", "tools/build-forever-fixes.lua", "tools/cache-foreverdb"], cwd=tmp)
    if "skinning" in todo:
        run(py + ["tools/build-skinning.py"], cwd=tmp)
    if "gather" in todo:
        fishing = tmp / "tools/cache-wowforever/fishing-page.html"
        run(py + ["tools/build-gather.py"] + (["--wowforever-fishing", fishing] if fishing.exists() else []), cwd=tmp)
    if "reagents" in todo:
        run(py + ["tools/build-reagent-sources.py"], cwd=tmp)


def audit_score(tmp):
    p = run(["lua", "tools/audit-forever.lua", "tools/cache-foreverdb"], cwd=tmp)
    rows = re.findall(r"^\S.*?\s+(\d+)\s+(\d+)\s+\d+\.\d%$", p.stdout, re.M)
    n, ok = sum(int(a) for a, _ in rows), sum(int(b) for _, b in rows)
    if not n:
        raise GateFailed("audit printed no score")
    return round(100.0 * ok / n, 2)


def force_fail(name):
    if os.environ.get("GC_TEST_FAIL_GATE") == name:        # test hook: proves the failure path leaves the repo untouched
        raise GateFailed(f"gate '{name}' failed on purpose (GC_TEST_FAIL_GATE)")


def personal_pattern():
    pat = PATTERN_FILE.read_text(encoding="utf-8").strip() if PATTERN_FILE.exists() else ""
    if not pat:
        raise GateFailed(f"personal-data pattern file {PATTERN_FILE} is missing or empty")
    return re.compile(pat, re.I)


def changed_files(tmp):
    out = []
    for g in OUTPUT_GLOBS:
        for f in sorted(tmp.glob(g)):
            rel = f.relative_to(tmp)
            if not (REPO / rel).exists() or not filecmp.cmp(f, REPO / rel, shallow=False):
                out.append(rel)
    return out


def gates(tmp, baseline):
    changed = changed_files(tmp)
    force_fail("luacheck")                                                    # 1. luacheck, 0 warnings
    p = run(["luacheck", "--no-color", "."], cwd=tmp, check=False)
    if not re.search(r"Total: 0 warnings / 0 errors", p.stdout):
        raise GateFailed("luacheck reports warnings or errors")
    force_fail("busted")                                                      # 2. busted, everything passes
    p = run(["busted", "--output=plainTerminal"], cwd=tmp, check=False, timeout=170)
    if p.returncode != 0 or not re.search(r"\b0 failures / 0 errors", p.stdout):
        raise GateFailed("busted has failures")
    force_fail("audit")                                                       # 3. audit runs and the score is not worse
    score = audit_score(tmp)
    log.info("audit score %.2f%% (before the build: %.2f%%)", score, baseline)
    if score < baseline - 0.05:
        raise GateFailed(f"audit score fell from {baseline}% to {score}%")
    force_fail("personal")                                                    # 4. personal data in what this run adds
    pat = personal_pattern()
    for rel in changed:
        old = (REPO / rel).read_text(encoding="utf-8").splitlines() if (REPO / rel).exists() else []
        for line in difflib.unified_diff(old, (tmp / rel).read_text(encoding="utf-8").splitlines(), lineterm="", n=0):
            if line.startswith("+") and not line.startswith("+++") and pat.search(line):
                raise GateFailed(f"personal data in the diff of {rel}")
    force_fail("load")                                                        # 5. generated files non-empty, not collapsed, loadable
    (tmp / ".load-check.lua").write_text('local f = assert(loadfile(arg[1])); f("GoldCompass", {})\n', encoding="utf-8")
    for rel in changed:
        if rel.parts[0] != "Data":
            continue
        new_size = (tmp / rel).stat().st_size
        old_size = (REPO / rel).stat().st_size if (REPO / rel).exists() else 0
        if new_size == 0 or (old_size and new_size < 0.7 * old_size):
            raise GateFailed(f"{rel} is empty or shrank from {old_size} to {new_size} bytes")
        run(["lua", tmp / ".load-check.lua", tmp / rel], cwd=tmp)
    return score, changed


# -------------------------------------------------------------------------------------------------- publish stages
def git(*args, check=True, timeout=120):
    return run(["git", *args], cwd=REPO, check=check, timeout=timeout)


def repo_problem():
    if git("branch", "--show-current").stdout.strip() != "main":
        return "pas sur la branche main"
    if git("status", "--porcelain").stdout.strip():
        return "arbre de travail pas propre"
    return None


def deploy_and_push(state):
    """Retries what is pending; each failure leaves its flag set so the next (hourly) run tries again."""
    if state.get("pending_deploy"):
        p = run(["bash", "scripts/deploy.sh"], cwd=REPO, check=False, timeout=180)
        state["pending_deploy"] = p.returncode != 0
        if p.returncode == 0:
            state["last_deploy"] = now_iso()
    if state.get("pending_push"):
        p = run(["git", "push", "origin", "main"], cwd=REPO, check=False, timeout=120)
        state["pending_push"] = p.returncode != 0
        if p.returncode == 0:
            state["last_push"] = now_iso()


def pending_text(state):
    out = ""
    if state.get("pending_deploy"):
        out += " Copie sur le PC en attente (PC éteint)."
    if state.get("pending_push"):
        out += " Envoi GitHub en attente."
    return out


def publish(state, files, label, sources_fr):
    paths = [str(f) for f in files]
    git("add", "--", *paths)
    git("commit", "-m", f"Data: Forever update {label}\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n", "--", *paths)
    state["last_commit"] = git("rev-parse", "--short", "HEAD").stdout.strip()
    state["pending_deploy"] = state["pending_push"] = True
    deploy_and_push(state)
    pend = pending_text(state)
    notify(f"Gold Compass : données Forever mises à jour ({sources_fr})." + (pend if pend else " Fais /reload en jeu."))


# ---------------------------------------------------------------------------------------------------------- main flows
def update(args, state):
    detected = detect()
    seen = state.get("sources", {})
    changed = set(SOURCE_NAMES) if args.force else {s for s, i in detected.items() if seen.get(s, {}).get("version") != i["version"]}
    v = {s: slim(detected.get(s) or seen[s]) for s in SOURCE_NAMES if s in detected or s in seen}
    log.info("sources now: %s", {s: short(s, i) for s, i in v.items()})
    log.info("changed: %s", sorted(changed) or "nothing")
    if not changed:
        log.info("nothing changed since the last check; quiet exit")
        return
    todo = plan(changed, args.force)
    needed = {s for g in todo for s in GENERATORS[g][0]}
    missing = needed - set(v)
    if missing:
        raise GateFailed(f"source unreachable and never seen: {sorted(missing)}")
    log.info("generators to run, in order: %s", todo)

    inputs = {}
    if "foreverdb" in needed:
        if "foreverdb" in detected:
            ensure_foreverdb(detected["foreverdb"])
        ensure_item_pages(refresh="foreverdb" in changed)
    if "wowforever" in needed and "wowforever" in detected:
        ensure_wowforever(detected["wowforever"])
    if "lpdb" in needed:
        inputs["lpdb"] = ensure_lpdb(v["lpdb"])
    if "forever_ledger" in needed:
        inputs["forever_ledger"] = ensure_forever_ledger(v["forever_ledger"]["version"])
    if "pfquest" in needed:
        inputs["pfquest"] = ensure_pfquest(v["pfquest"]["version"])

    tmp = make_workspace()
    try:
        baseline = audit_score(tmp)
        generate(tmp, todo, v, inputs)
        score, files = gates(tmp, baseline)
        label = ", ".join(f"{SOURCE_NAMES[s]} {short(s, v[s])}" for s in sorted(changed) if s in v)
        sources_fr = ", ".join(SOURCE_NAMES[s] for s in sorted(changed))
        if args.dry_run:
            log.info("DRY RUN ok: all gates passed, audit %.2f%%, files that would change: %s", score, [str(f) for f in files] or "none")
            print(f"DRY RUN: all gates passed (audit {score}%); would change: {[str(f) for f in files] or 'nothing'}")
            return
        if files:
            if git("status", "--porcelain", "--", *[str(f) for f in files]).stdout.strip():
                raise GateFailed("a file to update was modified in the repo during the run")
            try:
                for rel in files:
                    shutil.copy2(tmp / rel, REPO / rel)
                publish(state, files, label, sources_fr)
            except Exception:
                git("checkout", "--", *[str(f) for f in files], check=False)     # restore only what this run changed
                raise
        else:
            log.info("identical data: nothing to commit")
        state["sources"] = {**seen, **v}
        state["audit"] = {"score": score, "at": now_iso()}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def status(state):
    s = state.get("sources", {})
    lr = state.get("last_run", {})
    print("Gold Compass data update")
    print(f"  last check          : {state.get('last_check', 'never')}")
    print(f"  last run            : {lr.get('result', '-')} {lr.get('at', '')} {lr.get('detail', '')}")
    print(f"  last data commit    : {state.get('last_commit', '-')}   audit score: {state.get('audit', {}).get('score', '-')}%")
    print("  source versions     :")
    for k, name in SOURCE_NAMES.items():
        print(f"    {name:<18} {short(k, s[k]) if k in s else '-'}")
    print(f"    {'ProfessionsTracker':<18} {PT_VERSION} (pinned: no machine-readable release)")
    print(f"  deploy to PC pending: {'YES' if state.get('pending_deploy') else 'no'}   (last: {state.get('last_deploy', '-')})")
    print(f"  GitHub push pending : {'YES' if state.get('pending_push') else 'no'}   (last: {state.get('last_push', '-')})")
    print(f"  log                 : {LOG_FILE}")


def main():
    ap = argparse.ArgumentParser(description="Daily Gold Compass data update.")
    ap.add_argument("--force", action="store_true", help="rebuild everything, whatever changed")
    ap.add_argument("--dry-run", action="store_true", help="detect and build in a temporary copy; no commit, deploy, push or state change")
    ap.add_argument("--status", action="store_true", help="show the last run, the source versions and the pending deploy")
    ap.add_argument("--check-now", action="store_true", help="check the sources even if they were checked less than a day ago")
    ap.add_argument("-v", "--verbose", action="store_true", help="also print the log to the terminal")
    args = ap.parse_args()
    CACHE_HOME.mkdir(parents=True, exist_ok=True)
    INPUTS.mkdir(parents=True, exist_ok=True)
    state = load_state()
    if args.status:
        status(state)
        return 0
    setup_logging(args.verbose or sys.stdout.isatty())
    lock = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log.info("another run holds the lock; exiting")
        return 0
    os.chdir(REPO)
    manual = args.force or args.dry_run or args.check_now
    log.info("=== run start (%s)", " ".join(sys.argv[1:]) or "scheduled")
    try:
        if not args.dry_run and (state.get("pending_deploy") or state.get("pending_push")):
            had_deploy = state.get("pending_deploy")
            deploy_and_push(state)                    # the hourly trigger lands here: retry what is pending
            if had_deploy and not state.get("pending_deploy"):
                notify("Gold Compass : copie sur le PC faite. Fais /reload en jeu.")
        last = state.get("last_check")
        recent = last and (datetime.datetime.now().astimezone() - datetime.datetime.fromisoformat(last)).total_seconds() < CHECK_EVERY_H * 3600
        if recent and not manual:
            log.info("sources checked less than %d h ago: nothing more to do", CHECK_EVERY_H)
            return 0
        problem = None if args.dry_run else repo_problem()
        if problem:
            if manual:
                raise GateFailed(problem)
            log.warning("abort: %s; retried hourly until it is clean", problem)
            if state.get("dirty_notified") != time.strftime("%Y-%m-%d"):         # one notification a day, not one an hour
                state["dirty_notified"] = time.strftime("%Y-%m-%d")
                notify(f"Gold Compass : mise à jour des données reportée ({problem}). Journal : {LOG_FILE}")
            return 0
        update(args, state)
        if not args.dry_run:
            state["last_check"] = now_iso()
            state["last_run"] = {"result": "ok", "at": now_iso(), "detail": ""}
        return 0
    except Exception as e:
        log.error("FAILED: %s", e, exc_info=not isinstance(e, GateFailed))
        if not args.dry_run:
            state["last_run"] = {"result": "failed", "at": now_iso(), "detail": str(e)[:200]}
            state["last_check"] = now_iso()           # a failing build is not retried every hour; the next daily run tries again
        notify(f"Gold Compass : mise à jour des données échouée, rien n'a changé. Journal : {LOG_FILE}")
        if args.dry_run:
            print(f"DRY RUN FAILED: {e}")
        return 1
    finally:
        if not args.dry_run:
            save_state(state)
        log.info("=== run end")


if __name__ == "__main__":
    sys.exit(main())
