#!/usr/bin/env python3
"""Builds Data/ForeverGather.lua: where each herb, ore, stone, gem and fish is gathered, for the item tooltip.

Run: python3 -I tools/build-gather.py [--foreverdb DIR] [--wowforever-fishing FILE]

Sources (both read from local caches, nothing is fetched here):
- ForeverDB.net addon data (GPL-3.0, credit "Data from ForeverDB.net"): Gather.lua (gathering kinds, object IDs, skill,
  spawn points: c = Classic CMaNGOS classic-db, f = seen in WoW Forever by the ForeverDB Companion; zone fishing skill)
  and Items.lua (d<source>~<chance x10>~<classic>~...: the top source of an item, classic 0 = observed in Forever).
- optional: wowforever.be's Fishing page (https://wowforever.be/tradeskills/forever/fishing/), table "The skill each
  zone needs", which overrides ForeverDB's Classic zone fishing skill when the zone name matches Data/Zones.lua.
Points: 4 base-36 characters each, x then y, in tenths of a percent.
"""
import argparse, html, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_FDB = pathlib.Path.home() / "Dev/wow-forever-gold-addon/tools/cache-foreverdb"
MAX_ZONES = 8
PROFESSION = {"herb": "herb", "mine": "ore", "fish": "fish"}
# Forever-only gathered items named by wowforever.be's Herbalism and Mining pages (build 1.60.1.70862) with no known source
# in ForeverDB yet: Demonsage, Death Lotus, Marefoil, Heavy Thorium Ore, Stranglevine, Frilled Lichen, Rosecap, Pitchblende,
# Scarce Herb Seeds. They get empty nodes and zones so the tooltip can say "source unknown on Forever".
NEW_UNKNOWN = [248821, 248822, 248823, 248815, 249274, 249399, 249424, 249426, 268418]


def points(s):
    return [(int(s[i:i + 2], 36), int(s[i + 2:i + 4], 36)) for i in range(0, len(s) - len(s) % 4, 4)]


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def parse_gather(text):
    kinds = {}
    for m in re.finditer(r'\[(\d+)\] = \{ n = "((?:[^"\\]|\\.)*)", p = "(\w+)", sk = (\d+)(.*?)\},?\n', text):
        rest = m.group(5)
        item = re.search(r"item = (\d+)", rest)
        objs = re.search(r"o = \{([^}]*)\}", rest)
        kinds[int(m.group(1))] = {"n": m.group(2).replace("\\'", "'"), "p": m.group(3), "sk": int(m.group(4)),
                                  "item": int(item.group(1)) if item else 0,
                                  "o": [int(x) for x in re.findall(r"\d+", objs.group(1))] if objs else []}
    zones = {}
    zpart = text[text.index("\n  zones = {"):]
    for zm in re.finditer(r"\n    \[(\d+)\] = \{ (?:fish = (\d+), )?k = \{(.*?)\n    \} \}", zpart, re.S):
        zk = {}
        for km in re.finditer(r'\[(\d+)\] = \{ c = "([0-9a-z]*)", f = "([0-9a-z]*)"', zm.group(3)):
            zk[int(km.group(1))] = (points(km.group(2)), points(km.group(3)))
        zones[int(zm.group(1))] = {"fish": int(zm.group(2)) if zm.group(2) else None, "k": zk}
    return kinds, zones


OWN_FOREVER = 5         # a map where players saw the beast at least this often keeps its Classic points (the beast does live there)
LARGER = 4              # ... otherwise they are dropped when another map holds LARGER times more Forever-seen points than this one
BORDER_MAPS = 4         # only a beast met on at most this many maps can be a border stray (Rabbit, Deer, Sheep, Cow live everywhere)


def border_stray(zones, kind, zid):
    """True when the Classic points of a skinnable kind on a map are a border stray. ForeverDB attributes a CMaNGOS spawn to a map by
    rectangle, so a beast of the Barrens that spawns next to Durotar shows up as Classic points on Durotar, off the land (x 19-35 percent
    while Durotar's own beasts stand at 35 and more). They cannot be moved to the right map (no conversion here), so they are dropped
    when players saw the kind fewer than OWN_FOREVER times on the map while another map holds LARGER times more Forever-seen points.
    A kind met on more than BORDER_MAPS maps, or with no Forever point anywhere else, keeps its Classic points."""
    here = zones.get(zid, {"k": {}})["k"].get(kind)
    maps = [z["k"][kind] for z in zones.values() if kind in z["k"] and z["k"][kind][0] + z["k"][kind][1]]
    if not here or not here[0] or len(maps) > BORDER_MAPS:
        return False
    other = max((len(o[1]) for o in maps if o is not here), default=0)
    return len(here[1]) < OWN_FOREVER and other >= LARGER * max(len(here[1]), 1)


def parse_items(text):
    """item -> (top source name, observed in Forever) from the d field of Items.lua."""
    out = {}
    for m in re.finditer(r'\[(\d+)\]="([^"]*)"', text):
        for part in m.group(2).split("|"):
            if part.startswith("d"):
                f = part[1:].split("~")
                if len(f) >= 3:
                    out[int(m.group(1))] = (f[0], f[2] == "0")
    return out


def best_point(pts):
    """The point with the most others within 5% of the map (the densest spot), as percent."""
    if not pts:
        return None
    score = lambda p: sum(1 for q in pts if abs(p[0] - q[0]) <= 50 and abs(p[1] - q[1]) <= 50)
    x, y = max(pts, key=lambda p: (score(p), -p[0], -p[1]))
    return round(x / 10, 1), round(y / 10, 1)


def zone_names():
    text = (ROOT / "Data/Zones.lua").read_text()
    names = {}
    for m in re.finditer(r'\[(\d+)\] = \{ "([^"]+)"', text):
        names[m.group(2).lower()] = int(m.group(1))
    names["zephras isle"] = 2521
    return names


def wowforever_fishing(path):
    """{mapID: (can fish from, always a catch from)} from wowforever.be's zone fishing table; unmatched names returned too."""
    t = re.sub(r"<script.*?</script>|<style.*?</style>", "", path.read_text(), flags=re.S)
    t = html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", t))).replace("’", "'")
    t = t[t.index("Can fish from Always a catch from Zones"):]
    t = t[:t.index("Gear that raises")]
    names, out, missed = zone_names(), {}, []
    for lo, hi, zl in re.findall(r"(\d+) (\d+) ([^0-9]+)", t[len("Can fish from Always a catch from Zones "):]):
        for name in [z.strip() for z in zl.split(",")]:
            mid = names.get(name.lower())
            if mid:
                out[mid] = (int(lo), int(hi))
            elif name:
                missed.append(name)
    return out, missed


def build(fdb, wf_path):
    kinds, zones = parse_gather((fdb / "Gather.lua").read_text())
    items = parse_items((fdb / "Items.lua").read_text())
    gather = {k: v for k, v in kinds.items() if v["p"] in PROFESSION}
    by_name = {v["n"]: k for k, v in gather.items()}

    # per kind: Forever points per zone, Classic points per zone
    seen = {k: {} for k in gather}
    for mid, z in zones.items():
        for k, (c, f) in z["k"].items():
            if k in seen:
                seen[k][mid] = (c, f)

    # item -> list of (kind, forever node evidence)
    src = {}
    for k, v in gather.items():
        if v["item"]:
            src.setdefault(v["item"], []).append((k, any(f for _, f in seen[k].values())))
    secondary = 0
    for item, (name, forever) in items.items():   # stones, gems, seeds, scarce materials whose top source is a node
        k = by_name.get(name)
        if k is not None and item not in src:
            src[item] = [(k, forever)]
            secondary += 1

    for item in NEW_UNKNOWN:
        src.setdefault(item, [])
    lines, stats = [], {"forever": 0, "classic": 0, "none": 0}
    for item in sorted(src):
        nodes, zsum = [], {}
        for k, forever in src[item]:
            v = gather[k]
            nodes.append("{ %s, %d, forever = %s }" % (lua_str(v["n"]), v["sk"], "true" if forever else "false"))
            for mid, (c, f) in seen[k].items():
                acc = zsum.setdefault(mid, [[], []])
                acc[0] += f; acc[1] += c
        ranked = sorted(zsum.items(), key=lambda kv: (-len(kv[1][0]), -len(kv[1][1]), kv[0]))
        total_f = sum(len(f) for f, _ in zsum.values())
        stats["forever" if total_f else "classic" if zsum else "none"] += 1
        zl = []
        for mid, (f, c) in ranked[:MAX_ZONES]:
            b = best_point(f or c)
            zl.append("{ %d, %d, %d, best = { %s, %s } }" % (mid, len(f), len(c), b[0], b[1]))
        lines.append("  [%d] = { nodes = { %s }, zones = { %s } }," % (item, ", ".join(nodes), ", ".join(zl)))

    wf, missed = (wowforever_fishing(wf_path) if wf_path else ({}, []))
    fish_kinds = [k for k, v in gather.items() if v["p"] == "fish"]
    flines = []
    for mid in sorted(set(m for m, z in zones.items() if z["fish"] is not None or any(k in z["k"] for k in fish_kinds)) | set(wf)):
        z = zones.get(mid, {"fish": None, "k": {}})
        its = sorted({gather[k]["item"] for k in fish_kinds if k in z["k"] and gather[k]["item"]})
        fpts = sum(len(z["k"][k][1]) for k in fish_kinds if k in z["k"])
        if mid in wf:
            skill, low, origin = wf[mid][1], wf[mid][0], "wowforever"
        elif z["fish"] is not None:
            skill, low, origin = z["fish"], None, "classic"
        else:
            skill, low, origin = None, None, None
        parts = []
        if skill is not None:
            parts.append("skill = %d" % skill)
        if low is not None:
            parts.append("from = %d" % low)
        if origin:
            parts.append("src = %s" % lua_str(origin))
        parts.append("items = { %s }" % ", ".join(map(str, its)))
        parts.append("foreverPoints = %d" % fpts)
        flines.append("  [%d] = { %s }," % (mid, ", ".join(parts)))

    out = [
        "-- GENERATED by tools/build-gather.py (python3 -I tools/build-gather.py). Do not edit by hand.",
        "-- Data from ForeverDB.net (https://foreverdb.net), GPL-3.0 with an attribution term: its addon files Gather.lua and Items.lua",
        "-- of build 1.60.1.70959. Spawn points are either seen in WoW Forever (ForeverDB Companion) or Classic (CMaNGOS classic-db,",
        "-- GPL-3.0, may differ in Forever). Zone fishing skill: wowforever.be's Forever table where the zone name matches, else Classic.",
        "-- ns.GatherSources[itemID] = { nodes = { { node name, skill, forever = node seen in Forever (for a stone, gem or other extra:",
        "--   the drop was seen in Forever) } }, zones = { { uiMapID, Forever points, Classic points, best = { x, y } } } }",
        "--   zones sorted by Forever points, at most %d; skill = ForeverDB's (Classic's) requirement, matching wowforever.be's." % MAX_ZONES,
        "-- ns.FishZones[uiMapID] = { skill = always-a-catch skill, from = lowest skill (wowforever.be only), src = \"wowforever\" |",
        "--   \"classic\", items = pool items with points there, foreverPoints = fishing points seen in Forever (pools and open water) }",
        "local _, ns = ...",
        "",
        "ns.GatherSources = {",
    ] + lines + ["}", "", "ns.FishZones = {"] + flines + ["}", ""]
    (ROOT / "Data/ForeverGather.lua").write_text("\n".join(out))
    print("items %d (secondary %d): Forever-confirmed %d, Classic-only %d, none %d; fish zones %d; wowforever names unmatched: %s"
          % (len(src), secondary, stats["forever"], stats["classic"], stats["none"], len(flines), ", ".join(missed) or "-"))
    return kinds, zones, gather, seen


def audit(gather, seen):
    """Compares Data/GatherNodes.lua with ForeverDB's kinds (item and skill) and prints the differences."""
    text = (ROOT / "Data/GatherNodes.lua").read_text()
    by_item = {}
    for k, v in gather.items():
        by_item.setdefault(v["item"], []).append(v)
    for m in re.finditer(r"\[(\d+)\] = \{ type = (\w), item = (\w+), skill = (\w+).*?-- (.*)", text):
        nid, item, skill, name = m.group(1), m.group(3), m.group(4), m.group(5).strip()
        if item == "nil":
            print("GatherNodes %s %s: no item" % (nid, name)); continue
        cands = by_item.get(int(item), [])
        if not cands:
            print("GatherNodes %s %s: item %s is no gathering kind in ForeverDB" % (nid, name, item)); continue
        if skill != "nil" and m.group(2) != "F" and int(skill) not in {c["sk"] for c in cands}:
            print("GatherNodes %s %s: skill %s, ForeverDB %s" % (nid, name, skill, [c["sk"] for c in cands]))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--foreverdb", type=pathlib.Path, default=DEFAULT_FDB)
    ap.add_argument("--wowforever-fishing", type=pathlib.Path)
    ap.add_argument("--audit", action="store_true", help="print Data/GatherNodes.lua differences")
    a = ap.parse_args()
    _, _, g, s = build(a.foreverdb, a.wowforever_fishing)
    if a.audit:
        audit(g, s)
    sys.exit(0)
