#!/usr/bin/env python3
"""Builds Data/ForeverReagentSources.lua: where to get each crafting reagent of Gold Compass in WoW Forever (vendors with place,
price, limited stock and a per-sale "seen in Forever" flag; top drop sources; the quest), for the reagent tooltip.

Sources, both from ForeverDB.net (https://foreverdb.net, data GPL-3.0 with the attribution term "Data from ForeverDB.net"):
  - the addon data files the site publishes (https://foreverdb.net/downloads/addon-manifest.json): NPCs.lua (vendor places with a
    "seen in Forever" flag; ns.sold = up to 8 vendors per item with price, stack and limited supply; ns.soldCount = the real count),
    Items.lua (per-item summary: vendor count, top drop source, quest, drops players saw);
  - the public item pages https://foreverdb.net/item/<id> (allowed by robots.txt; /api/ is not, and needs a key), whose
    server-rendered "Sold by" and "Where to get it" lists say, per vendor and per drop source, "seen in WoW Forever" or
    "Classic data" (CMaNGOS classic-db, not confirmed in Forever). They show the first 10 vendors / 11 sources only.
Skipped on purpose (other data sets): leather, hides, scales, herbs, ore, stone and fish (but the fish vendors sell, see VENDOR_FISH).

Run: python3 -I tools/build-reagent-sources.py           (uses the cache under tools/cache-foreverdb/, git-ignored)
     python3 -I tools/build-reagent-sources.py --fetch   (first downloads the item pages missing from the cache, 1 request / 1.2 s)
Standard library only; downloaded files are parsed as text, never executed.
"""
import html, pathlib, re, sys, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = pathlib.Path(__file__).resolve().parent / "cache-foreverdb"
PAGES = CACHE / "pages"
SITE = "https://foreverdb.net/"
USER_AGENT = "GoldCompass-data-build/1.0 (personal addon data build; credit: Data from ForeverDB.net)"
PF_CACHE = pathlib.Path(__file__).resolve().parent / "cache-pfquest"
PF_URL = "https://raw.githubusercontent.com/shagu/pfQuest/master/db/items.lua"
OUT = ROOT / "Data" / "ForeverReagentSources.lua"
MAX_VENDORS = 60             # per item: every known vendor with a place, up to this many (the spec pins it)


def reagent_ids():
    """Every reagent item id of the recipes Gold Compass reads ("item:count,..." strings of both recipe files)."""
    ids = set()
    for name in ("Recipes.lua", "ForeverRecipes.lua"):
        src = (ROOT / "Data" / name).read_text(encoding="utf-8")
        for grp in re.findall(r'"((?:\d+:\d+,?)+)"', src):
            ids.update(int(a) for a, _ in re.findall(r"(\d+):(\d+)", grp))
    return sorted(ids)


def fetch_pages(ids):
    PAGES.mkdir(parents=True, exist_ok=True)
    for n, item in enumerate(ids):
        path = PAGES / f"item{item}.html"
        if path.exists() and path.stat().st_size > 10000:
            continue
        time.sleep(1.2)                                 # polite: at most one page a second
        try:
            req = urllib.request.Request(f"{SITE}item/{item}", headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=30) as r:
                path.write_bytes(r.read())
        except Exception as e:                          # a missing page is a finding, not a failure
            print(f"item {item}: {e}", file=sys.stderr)
        if n % 50 == 0:
            print(f"{n}/{len(ids)}", file=sys.stderr)


def table(src, name):
    """The one-line Lua table literal assigned to ns.<name>."""
    start = src.index(f"ns.{name} = ") + len(f"ns.{name} = ")
    return src[start:src.index("\n", start)]


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def num(v):
    return ("%.1f" % v).rstrip("0").rstrip(".") if isinstance(v, float) else str(v)


def text(fragment):
    return " ".join(html.unescape(re.sub(r"<[^>]+>", "", fragment)).split())


def copper(price):
    """"1g 2s 50c" -> 10250 copper (0 when the page shows no price)."""
    units = {"g": 10000, "s": 100, "c": 1}
    return sum(int(n) * units[u] for n, u in re.findall(r"(\d+)([gsc])\b", price))


# Skipped categories (other data sets): leather, hides and scales; herbs; ore and stone; fish
# Except the fish that vendors sell (Longjaw Mud Snapper, Bristle Whisker Catfish, Spotted Yellowtail, Rockscale Cod, Spinefin Halibut): the shopping list needs those vendors.
# Held back: Slitherskin Mackerel 6303 (vendors exist). With it the Cooking plan announces 'learn it at 41' from a bag of meat, then drops that
# step once the player is at 41 (journey detector D2); add it back once the planner keeps a planned learn.
VENDOR_FISH = {6289, 6308, 4603, 6362, 8959}
FISH = re.compile(r"^Raw |Fish|Eel$|Snapper|Blackmouth|Mightfish|Sagefish|Yellowtail|Grouper|Salmon|Mackerel|Squid|Lobster|Smallfish|Whitescale|Oily ")
STONE = re.compile(r" Ore$|^(Rough|Coarse|Heavy|Solid|Dense) Stone$")


def skipped(name, category):
    if category == "herb" or STONE.search(name):
        return True
    if "armor piece" in category:                           # a crafted Fine Leather Tunic is a reagent, not leather
        return False
    if category == "leather (trade good)":                  # Salt is filed there too, and stays
        return bool(re.search(r"Leather|Hide|[Ss]cale|Scraps", name))
    return bool(re.search(r"Hide$|Wolfhide|[Ss]cales?$", name)) or bool(FISH.search(name))


def parse_page(path):
    """The server-rendered facts of an item page: name, category, vendors, drops, quests and the counts it does not list."""
    main = re.search(r"<main.*?</main>", path.read_text(encoding="utf-8"), re.S)
    if not main:
        return None
    main = main.group(0).split('class="ssr-faq"')[0]
    name = text(re.search(r"<h1>(.*?)</h1>", main, re.S).group(1))
    summary = text(re.search(r'class="ssr-summary">(.*?)</p>', main, re.S).group(1))
    cat = re.search(r" is an? (?:Poor|Common|Uncommon|Rare|Epic|Legendary|Artifact) (.*?)(?: \(requires level \d+\))? in the WoW", summary)
    page = {"name": name, "category": cat.group(1) if cat else "", "vendors": [], "drops": [], "quests": [], "seen": 0, "more": 0}
    where = main.find(">Where to get it<")
    sold = main.find(">Sold by<")
    for li in re.findall(r"<li>(.*?)</li>", main[where:sold if sold > where else len(main)] if where >= 0 else "", re.S):
        t = text(li)
        forever = t.endswith("(seen in WoW Forever)")
        if m := re.match(r"Sold by (\d+) vendors? \(seen in WoW Forever\)", t):
            page["seen"] = int(m.group(1))
        elif m := re.match(r"Drops from (.*?)(?: \(boss\) in [^,(]*)?(?:, (\d+(?:\.\d+)?)% \((?:(\d+) eligible looted corpses[^)]*|Classic drop rate)\))?(?: \((?:seen in WoW Forever|Classic data)\))?$", t):
            who = m.group(1)
            if not who.startswith("a creature in Forever"):
                page["drops"].append((who, int(m.group(3) or 0), forever, float(m.group(2)) if "." in (m.group(2) or "") else int(m.group(2)) if m.group(2) else None))
        elif m := re.match(r"Quest reward from (.*?) \(level (\d+)\)(.*)$", t):
            side = "A" if ", Alliance" in m.group(3) else "H" if ", Horde" in m.group(3) else "AH"
            page["quests"].append((m.group(1), int(m.group(2)), side, forever))
    if sold >= 0:
        for li in re.findall(r"<li>(.*?)</li>", main[sold:], re.S):
            t = text(li)
            m = re.match(r"(.*?)(?: <[^>]*>)?, (.*?)(?: \((Alliance|Horde)\))?: ([\dgsc ]+?) \((seen in WoW Forever|Classic data)\)$", t)
            if m:
                page["vendors"].append((m.group(1), {"Alliance": "A", "Horde": "H"}.get(m.group(3)), copper(m.group(4)),
                                        m.group(5) == "seen in WoW Forever"))
    more = re.search(r"And (\d+) more vendors", main)
    page["more"] = int(more.group(1)) if more else 0
    return page


def main():
    ids = reagent_ids()
    if "--fetch" in sys.argv:
        fetch_pages(ids)
        PF_CACHE.mkdir(exist_ok=True)
        req = urllib.request.Request(PF_URL, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=120) as r:
            (PF_CACHE / "items.lua").write_bytes(r.read())
    npcs_src = (CACHE / "NPCs.lua").read_text(encoding="utf-8")
    items_src = (CACHE / "Items.lua").read_text(encoding="utf-8")
    meta = dict(re.findall(r'(\w+)="([^"]*)"', (CACHE / "Meta.lua").read_text(encoding="utf-8")))

    # [npc] = {name, title, map, x, y, side (A/H), seen in Forever}: the place is Classic's unless seen
    npcs, by_name = {}, {}
    for i, name, _, m, x, y, side, seen in re.findall(
            r'\[(\d+)\]=\{"((?:[^"\\]|\\.)*)","((?:[^"\\]|\\.)*)",(\d+|nil),(-?[\d.]+|nil),(-?[\d.]+|nil),"?(\w*)"?,(\d)\}', table(npcs_src, "npcs")):
        name = name.replace('\\"', '"')
        npcs[int(i)] = (name, int(m) if m != "nil" else 0, float(x) if x != "nil" else 0.0, float(y) if y != "nil" else 0.0,
                        side if side in ("A", "H") else "AH", seen == "1")
        by_name.setdefault(name, []).append(int(i))
    # [item] = {npc, price, stack, limited supply, ...} (at most 8 vendors); soldCount[item] = the real count when cut
    sold = {int(i): [int(v) for v in vals.split(",")] for i, vals in re.findall(r"\[(\d+)\]=\{([\d,]+)\}", table(npcs_src, "sold"))}
    count = {int(i): int(n) for i, n in re.findall(r"\[(\d+)\]=(\d+)", table(npcs_src, "soldCount"))}
    # Items.lua: v<vendors>~<first vendor>~<zone>~<seen>; d<source>~<chance x10>~<classic>~<sources>~<chance x100>; q<quest>~<classic>; s<drops seen>~<players>
    # pfQuest (MIT, Classic CMaNGOS/VMaNGOS data): items[id]["V"] = { [vendor npc] = stock (0 = unlimited) }
    pf_v = pfquest_vendors(set(ids))
    facts = {int(i): dict((f[0], f[1:].split("~")) for f in v.split("|") if f)
             for i, v in re.findall(r'\[(\d+)\]="((?:[^"\\]|\\.)*)"', table(items_src, "items"))}

    out, stats = {}, {"forever": 0, "classic": 0, "none": 0, "crafted": 0, "skipped": 0, "nopage": 0, "vendorForever": 0,
                      "vendorClassic": 0, "dropForever": 0}
    gaps, differs, forever_npc = [], [], set()
    for item in ids:
        path = PAGES / f"item{item}.html"
        page = parse_page(path) if path.exists() else None
        if page is None:
            stats["nopage"] += 1
            continue
        if item not in VENDOR_FISH and skipped(page["name"], page["category"]):
            stats["skipped"] += 1
            continue
        raw = sold.get(item, [])
        limited = {raw[k]: raw[k + 3] != 0 for k in range(0, len(raw), 4)}
        price_of = {raw[k]: raw[k + 1] for k in range(0, len(raw), 4)}
        vendors, used = [], set()
        for vname, vside, price, forever in page["vendors"]:      # the page's vendors carry the per-sale Forever flag
            cands = by_name.get(vname, [])
            npc = next((c for c in cands if c in price_of), None) or next((c for c in cands if npcs[c][5]), None) or (cands[0] if cands else 0)
            if npc in used:
                continue
            used.add(npc)
            n = npcs.get(npc, (vname, 0, 0.0, 0.0, vside or "AH", False))
            vendors.append([npc, vname, n[1], n[2], n[3], vside or n[4], price or price_of.get(npc, 0), forever,
                            limited.get(npc, False) or pf_v.get(item, {}).get(npc, 0) > 0, n[5]])
        price = min(price_of.values()) if price_of else max([v[6] for v in vendors] + [0])
        classic = sorted(pf_v.get(item, {}).items())
        if not classic and any(v[3] for v in page["vendors"]):
            differs.append(f"{item} {page['name']} (sold in Forever, by no Classic vendor)")
        if classic and not (raw or page["vendors"]):            # Classic sells it, ForeverDB knows no vendor: not listed
            differs.append(f"{item} {page['name']} (Classic: {len(classic)} vendors, ForeverDB: none)")
            classic = []
        for npc, stock in [(raw[k], raw[k + 3]) for k in range(0, len(raw), 4)] + classic:
            if npc in used or npc not in npcs:                  # then the other vendors: Classic data unless the page said seen
                continue
            used.add(npc)
            n = npcs[npc]
            vendors.append([npc, n[0], n[1], n[2], n[3], n[4], price_of.get(npc, price), False, stock > 0, n[5]])
        vendors = order([v for v in vendors if v[2] and v[3] and v[4]])    # every known vendor with a place, deduped by npc id above
        fact = facts.get(item, {})
        drops = sorted(page["drops"], key=lambda d: (not d[2], -d[1]))[:5]
        if not drops and "d" in fact and not fact["d"][0].startswith("a creature"):
            d = fact["d"]
            drops = [(d[0], 0, d[2] == "0", int(d[4]) / 100 if d[4] != "0" else None)]
        quests = sorted(page["quests"], key=lambda q: not q[3])
        if not quests and "q" in fact:
            quests = [(fact["q"][0], 0, "AH", fact["q"][1] == "0")]
        if not (vendors or drops or quests):
            crafted = ">Crafted with " in path.read_text(encoding="utf-8")
            stats["crafted" if crafted else "none"] += 1
            gaps.append(f"{item} {page['name']}{' (crafted)' if crafted else ''}")
            continue
        confirmed = any(v[7] for v in vendors) or any(d[2] for d in drops) or any(q[3] for q in quests)
        stats["forever" if confirmed else "classic"] += 1
        if vendors:
            stats["vendorForever" if any(v[7] for v in vendors) else "vendorClassic"] += 1
        stats["dropForever"] += any(d[2] for d in drops)
        forever_npc.update(v[0] for v in vendors if v[7] and v[0] > 200000)
        out[item] = (page["name"], vendors, drops, quests[:1], page["seen"], count.get(item, len(sold.get(item, [])) // 4), fact.get("s"))
    out = {i: (o[0], cap(o[1]), *o[2:]) for i, o in out.items()}
    OUT.write_text(render(out, meta), encoding="utf-8")
    print(f"reagents {len(ids)}: Forever-confirmed {stats['forever']}, Classic-only {stats['classic']}, none {stats['none']}, "
          f"(crafted only {stats['crafted']}), skipped (leather/herb/ore/fish) {stats['skipped']}, no page {stats['nopage']}")
    print(f"with vendors: Forever-seen {stats['vendorForever']}, Classic data only {stats['vendorClassic']}; "
          f"with a Forever-seen drop: {stats['dropForever']}; Forever-only vendor NPCs (id > 200000) seen selling: {len(forever_npc)}")
    print("no vendor, drop or quest:", "; ".join(gaps))
    print("Forever vs Classic vendors:", "; ".join(differs) or "none")
    print("Classic data only:", "; ".join(f"{i} {o[0]}" for i, o in sorted(out.items())
                                         if not (any(v[7] for v in o[1]) or any(d[2] for d in o[2]) or any(q[3] for q in o[3]))))


def pfquest_vendors(wanted):
    """{ item = { npc = stock } } from pfQuest's db/items.lua (cached by --fetch), for the items in `wanted`."""
    path = PF_CACHE / "items.lua"
    if not path.exists():
        return {}
    src = path.read_text(encoding="latin-1")
    src = src[src.index('pfDB["items"]["data"]'):]
    out = {}
    for item, body in re.findall(r'\n  \[(\d+)\] = \{\n(.*?)\n  \},', src, re.S):
        if int(item) in wanted and '["V"]' in body:
            v = body[body.index('["V"]'):]
            v = v[:v.index("},")]
            out[int(item)] = {int(n): int(c) for n, c in re.findall(r"\[(\d+)\] = (\d+)", v)}
    return out


def order(vendors):
    """Forever-seen vendors first, then by side and zone (the order the file keeps)."""
    return sorted(vendors, key=lambda v: (not v[7], v[5], v[2], v[0]))


def cap(vendors):
    """At most MAX_VENDORS, chosen by priority: the first vendor of every (zone, side) so each zone and both factions stay covered,
    then the other Forever-seen ones, then the rest (zones with a Forever-seen vendor first)."""
    ranked = sorted(vendors, key=lambda v: (not v[7], not v[9], v[0]))
    firsts, seen = [], set()
    for v in ranked:
        if (v[2], v[5]) not in seen:
            seen.add((v[2], v[5]))
            firsts.append(v)
    chosen = firsts[:MAX_VENDORS]
    for v in ranked:
        if len(chosen) >= MAX_VENDORS:
            break
        if all(v is not c for c in chosen):
            chosen.append(v)
    return order(chosen)


def render(out, meta):
    lines = [
        "-- GENERATED by tools/build-reagent-sources.py. Do not edit by hand.",
        f"-- Data from ForeverDB.net (https://foreverdb.net, GPL-3.0, attribution: \"Data from ForeverDB.net\"), game build "
        f"{meta.get('build', '?')}, data version {meta.get('version', '?')}: the addon data files and the item pages.",
        "-- Where to get each crafting reagent (leather, hides, scales, herbs, ore, stone and fish excepted, but the fish vendors sell: other data sets).",
        "-- vendors = { {npcID (0 = unknown), name, uiMapID (0 = unknown), x, y, side \"A\"|\"H\"|\"AH\", price (copper),",
        "--   forever = true when players saw this vendor sell it in WoW Forever (else Classic data), limited = true for a limited stock} }",
        "--   Forever-seen first; every known vendor with a place (capped at 60 per item: one per zone and side first, Forever-seen first). Positions are Classic's unless the NPC was seen in Forever.",
        "-- seen / total = vendors seen selling it in Forever / vendors known (Forever + Classic data).",
        "-- drops = { {creature name, looted corpses measured in Forever (0 = not measured), forever, drop chance % or nil} }",
        "-- quest = { name, level (0 = unknown), side, forever }; dropsSeen = { drops players saw, players }.",
        "local _, ns = ...",
        "local R = {}",
        "ns.ReagentSources = R",
    ]
    for item in sorted(out):
        name, vendors, drops, quests, seen, total, dseen = out[item]
        parts = []
        if vendors:
            vs = ",".join("{%d,%s,%d,%s,%s,%s,%d,forever=%s%s}" % (v[0], lua_str(v[1]), v[2], num(v[3]), num(v[4]), lua_str(v[5]), v[6],
                                                            "true" if v[7] else "false", ",limited=true" if v[8] else "") for v in vendors)
            parts.append("vendors={%s},seen=%d,total=%d" % (vs, seen, max(total, len(vendors))))
        if drops:
            parts.append("drops={%s}" % ",".join("{%s,%d,%s%s}" % (lua_str(d[0]), d[1], "true" if d[2] else "false",
                                                                  "," + num(float(d[3])) if d[3] is not None else "") for d in drops))
        if dseen:
            parts.append("dropsSeen={%s,%s}" % (int(dseen[0]), int(dseen[1])))
        if quests:
            q = quests[0]
            parts.append("quest={%s,%d,%s,%s}" % (lua_str(q[0]), q[1], lua_str(q[2]), "true" if q[3] else "false"))
        lines.append("R[%d]={%s} -- %s" % (item, ",".join(parts), name.replace("\n", " ")))
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    if "--fetch-only" in sys.argv:
        fetch_pages(reagent_ids())
    else:
        main()
