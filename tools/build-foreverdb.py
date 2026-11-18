#!/usr/bin/env python3
"""Builds Data/ForeverNpcs.lua from the data files of the ForeverDB addon (https://foreverdb.net): where the vendors and profession
trainers of WoW Forever stand (with a "seen in Forever" flag per NPC, recorded in game by the players' ForeverDB addons), which
vendors sell each recipe and for how much, and the quests that reward a recipe (id, side, where players were offered them).

Run: python3 -I tools/build-foreverdb.py          (uses the cached files)
     python3 -I tools/build-foreverdb.py --fetch  (downloads the current files first: manifest, then NPCs, Recipes, Meta, QuestForever)
     ... --pfq <pfQuest db folder>                (optional: units.lua of pfQuest, MIT, gives the faction of the quest givers
                                                   ForeverDB has no side for)
The files are the ones the site publishes for addons and tools (https://foreverdb.net/downloads/addon-manifest.json, named in its
robots.txt), cached under tools/cache-foreverdb/ (git-ignored). Licence of the data: GPL-3.0 with an attribution term (section 7(b)):
credit "Data from ForeverDB.net". Standard library only; the downloaded files are parsed as text, never executed.
"""
import hashlib, json, pathlib, re, sys, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = pathlib.Path(__file__).resolve().parent / "cache-foreverdb"
SITE = "https://foreverdb.net/"
USER_AGENT = "GoldCompass-data-build/1.0 (personal addon data build; credit: Data from ForeverDB.net)"
FILES = ["NPCs", "Recipes", "Meta", "QuestForever"]


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def fetch():
    CACHE.mkdir(exist_ok=True)
    manifest = get(SITE + "downloads/addon-manifest.json")
    (CACHE / "addon-manifest.json").write_bytes(manifest)
    by_path = {f["path"]: f for f in json.loads(manifest)["data"]["files"]}
    for name in FILES:
        time.sleep(1)                                   # polite: one small file per second
        entry = by_path[f"Data/{name}.lua"]
        body = get(SITE + entry["url"])
        if hashlib.sha256(body).hexdigest() != entry["sha256"]:
            sys.exit(f"{name}.lua: SHA-256 differs from the manifest, nothing written")
        (CACHE / f"{name}.lua").write_bytes(body)


def table(src, name):
    """The one-line Lua table literal assigned to ns.<name>."""
    start = src.index(f"ns.{name} = ") + len(f"ns.{name} = ")
    return src[start:src.index("\n", start)]


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    if "--fetch" in sys.argv:
        fetch()
    npcs_src = (CACHE / "NPCs.lua").read_text(encoding="utf-8")
    rec_src = (CACHE / "Recipes.lua").read_text(encoding="utf-8")
    meta = dict(re.findall(r'(\w+)="([^"]*)"', (CACHE / "Meta.lua").read_text(encoding="utf-8")))

    # [npc] = {name, title, map, x, y, side (A/H), seen in Forever}
    npcs = {}
    for i, name, title, m, x, y, side, seen in re.findall(
            r'\[(\d+)\]=\{"((?:[^"\\]|\\.)*)","((?:[^"\\]|\\.)*)",(\d+|nil),(-?[\d.]+|nil),(-?[\d.]+|nil),"?(\w*)"?,(\d)\}', table(npcs_src, "npcs")):
        if m != "nil" and x != "nil" and y != "nil":
            npcs[int(i)] = (name.replace('\\"', '"'), title, int(m), float(x), float(y), side if side in ("A", "H") else "AH", seen == "1")
    # [item] = {npc, price, stack, limited supply, npc, price, ...}; soldCount[item]: the real vendor count when the list is cut
    sold_raw = {int(i): [int(v) for v in vals.split(",")] for i, vals in re.findall(r"\[(\d+)\]=\{([\d,]+)\}", table(npcs_src, "sold"))}
    sold = {i: v[0::4] for i, v in sold_raw.items()}
    price = {i: min(v[1::4]) for i, v in sold_raw.items()}
    cut = {int(i) for i, _ in re.findall(r"\[(\d+)\]=(\d+)", table(npcs_src, "soldCount"))}
    trainers = {}
    for prof, ids in re.findall(r'(?:\["([\w ]+)"\]|(\w+))=\{([\d,]+)\}', table(npcs_src, "profTrainers")) and \
            [(a or b, c) for a, b, c in re.findall(r'(?:\["([\w ]+)"\]|(\w+))=\{([\d,]+)\}', table(npcs_src, "profTrainers"))]:
        trainers[prof] = [int(v) for v in ids.split(",")]
    # recipes: {spell, name, skill, yellow, green, grey, item, count, "reagents", "learned from" (i<recipe item> | a | t), ...}
    vendors, costs, partial = {}, {}, 0
    for spell, item in re.findall(r'\{(\d+),"(?:[^"\\]|\\.)*",\d+,\d+,\d+,\d+,\d+,[\d.]+,"[^"]*","i(\d+)"', table(rec_src, "recipes")):
        item = int(item)
        if item in sold:
            if item in cut:
                partial += 1                                # a cut list is not the whole truth: not used to rule vendors out
                continue
            vendors[int(spell)] = [v for v in sold[item] if v in npcs]
            if price[item] > 0:
                costs[int(spell)] = price[item]
    # the teaching items of Gold Compass's own recipe data that ForeverDB's recipe list does not carry (the rank books: Expert Cookbook...)
    own_rows = re.findall(r'\{ (\d+), \d+, \d+, \d+, \d+, \d+, \d+, "[^"]*", (\d+), "[^"]*" \}', (ROOT / "Data/ForeverRecipes.lua").read_text(encoding="utf-8"))
    for spell, item in own_rows:
        spell, item = int(spell), int(item)
        if item and spell not in vendors and item in sold and item not in cut:
            vendors[spell] = [v for v in sold[item] if v in npcs]
            if price[item] > 0:
                costs[spell] = price[item]
    # recipeInfo: [spell] = {..., q = "quest title(s)", fav = Merchant's Favor cost, ...}
    info = table(rec_src, "recipeInfo")
    favor = {int(sp): int(f) for sp, f in re.findall(r"\[(\d+)\]=\{[^{}]*?\bfav=(\d+)", info)}
    quest_titles = {int(sp): q for sp, q in re.findall(r'\[(\d+)\]=\{[^{}]*?\bq="((?:[^"\\]|\\.)*)"', info)}
    # QuestForever: [quest] = "title|level|min level|objective|starts|ends|players|new|previous|lowest level|side (a/h)"; positions are
    # packed in base 36: uiMap * 1e6 + x * 10 * 1000 + y * 10 (qfSeen: where players were offered the quest; qfNpcSpots: where they saw the NPC)
    qf = (CACHE / "QuestForever.lua").read_text(encoding="utf-8")

    def section(name):
        start = qf.index(f"ns.{name} = {{")
        return qf[start:qf.index("\n}", start)]

    by_title = {}
    for qid, row in re.findall(r'\[(\d+)\]="((?:[^"\\]|\\.)*)"', section("qfQuests")):
        f = row.replace('\\"', '"').split("|")
        if len(f) >= 11 and f[0]:
            by_title.setdefault(f[0], []).append((int(qid), f[4], f[10]))
    seen_start = dict(re.findall(r'\[(\d+)\]=\{s="(\w+)', section("qfSeen")))
    npc_spots = dict(re.findall(r'\[(\d+)\]="(\w+)', section("qfNpcSpots")))
    npc_names = dict(re.findall(r'\[(\d+)\]="((?:[^"\\]|\\.)*)"', section("qfNpcNames")))

    def spot(code):
        v = int(code, 36)
        return v // 1000000, (v % 1000000) // 1000 / 10, v % 1000 / 10

    pfq_fac = {}                                            # pfQuest: [npc] = "A" | "H" (friendly to one faction only)
    if "--pfq" in sys.argv:
        cur = None
        for line in (pathlib.Path(sys.argv[sys.argv.index("--pfq") + 1]) / "units.lua").read_text(encoding="utf-8").splitlines():
            m = re.match(r"^  \[(\d+)\] = \{", line)
            if m:
                cur = int(m.group(1))
            m = re.match(r'^    \["fac"\] = "([AH])"', line)
            if m and cur:
                pfq_fac[cur] = m.group(1)
    quests, unresolved = {}, []
    for spell, titles in sorted(quest_titles.items()):
        titles = titles.replace('\\"', '"')
        found = by_title.get(titles) or [q for part in titles.split(", ") for q in by_title.get(part, [])]
        if not found:
            unresolved.append(titles)
        for qid, starts, side in found:
            giver = int(starts[1:]) if starts.startswith("n") else 0
            code = seen_start.get(str(qid)) or npc_spots.get(str(giver))
            m, x, y = spot(code) if code else (0, 0, 0)
            side = side.upper() if side in ("a", "h") else (npcs[giver][5] if giver in npcs and npcs[giver][5] != "AH" else pfq_fac.get(giver, ""))
            quests.setdefault(spell, []).append((qid, side, giver, npc_names.get(str(giver), "").replace('\\"', '"'), m, x, y))

    ours = {int(i) for i in re.findall(r"^  \[(\d+)\] = \{", (ROOT / "Data/Npcs.lua").read_text(encoding="utf-8"), re.M)}
    keep = {v for ids in vendors.values() for v in ids} | {v for ids in trainers.values() for v in ids if v in npcs} | (ours & set(npcs))
    out = [
        "-- GENERATED by tools/build-foreverdb.py. Do not edit by hand.",
        f"-- Data from ForeverDB.net (https://foreverdb.net), game build {meta.get('build', '?')}, data version {meta.get('version', '?')}.",
        "-- Licence of this file's data: GPL-3.0 with an attribution term (section 7(b)), see NOTICE and THIRD-PARTY.",
        "-- Where the vendors and profession trainers of WoW Forever stand, and which vendors sell each recipe. `seen` is ForeverDB's own flag:",
        "-- true = the NPC was recorded in the Forever game by its players' addons (position and offers are Forever's), false = the place is",
        "-- still Classic data (not confirmed on Forever).",
        "local _, ns = ...",
        f"ns.FdbMeta = {{ build = {lua_str(meta.get('build', '?'))}, version = {lua_str(meta.get('version', '?'))} }}",
        "-- ns.FdbNpcs[npcID] = { English name, uiMapID, x, y, side (\"A\" | \"H\" | \"AH\"), seen in Forever }",
        "ns.FdbNpcs = {",
    ]
    for i in sorted(keep):
        name, _, m, x, y, side, seen = npcs[i]
        out.append(f"  [{i}] = {{ {lua_str(name)}, {m}, {x:g}, {y:g}, {lua_str(side)}, {'true' if seen else 'false'} }},")
    out += ["}", "-- ns.FdbVendors[craft spell] = { npcID, ... }: every vendor that sells the recipe's teaching item (whole lists only)",
            "ns.FdbVendors = {"]
    for spell in sorted(vendors):
        out.append(f"  [{spell}] = {{ {', '.join(str(v) for v in vendors[spell])} }},")
    out += ["}", "-- ns.FdbPrice[craft spell] = copper: the lowest vendor price of the teaching item; ns.FdbFavor[craft spell] = its Merchant's Favor cost",
            "ns.FdbPrice = { " + ", ".join(f"[{sp}] = {costs[sp]}" for sp in sorted(costs)) + " }",
            "ns.FdbFavor = { " + ", ".join(f"[{sp}] = {favor[sp]}" for sp in sorted(favor)) + " }",
            "-- ns.FdbQuests[craft spell] = { { questID, side (\"A\" | \"H\" | \"\" unknown), giver npcID (0: not an NPC), giver name, uiMapID (0: place unknown),",
            "--   x, y }, ... }: the quests that reward the recipe, and where Forever players were offered them",
            "ns.FdbQuests = {"]
    for spell in sorted(quests):
        out.append(f"  [{spell}] = {{ " + ", ".join(
            f"{{ {q}, {lua_str(side)}, {g}, {lua_str(name)}, {m}, {x:g}, {y:g} }}" for q, side, g, name, m, x, y in quests[spell]) + " },")
    out += ["}", "-- ns.FdbTrainers[English profession] = { [npcID] = true | 0 }: the trainers of the profession; 0 = a \"Journeyman ...\" by its Forever",
            "--   title: such a trainer taught nothing from skill 50 up when seen in game (Kamari), so it is proposed for Apprentice recipes only",
            "ns.FdbTrainers = {"]
    for prof in sorted(trainers):
        out.append(f"  [{lua_str(prof)}] = {{ " + ", ".join(
            f"[{v}] = {'0' if v in npcs and npcs[v][1].startswith('Journeyman') else 'true'}" for v in trainers[prof]) + " },")
    out.append("}")
    text = "\n".join(out) + "\n"
    text.encode("latin-1")                                  # the game font draws Latin-1 only: fail loudly on anything else
    (ROOT / "Data/ForeverNpcs.lua").write_text(text, encoding="utf-8")
    print(f"recipes with a vendor price: {len(costs)}, with a Merchant's Favor cost: {len(favor)}, rewarded by a quest: {len(quests)} "
          f"(quest titles not found: {len(unresolved)}: {'; '.join(unresolved[:8])})")
    seen = sum(1 for i in keep if npcs[i][6])
    print(f"ForeverDB build {meta.get('build')} ({meta.get('version')}): {len(npcs)} NPCs read, {len(keep)} kept ({seen} seen in Forever, "
          f"{len(keep) - seen} Classic places); recipes with a vendor list: {len(vendors)} (cut lists skipped: {partial}); "
          f"professions with trainers: {len(trainers)}")
    known = ours & set(npcs)
    print(f"NPCs of Data/Npcs.lua (pfQuest): {len(ours)}; known to ForeverDB: {len(known)}, seen in Forever: {sum(1 for i in known if npcs[i][6])}")


main()
