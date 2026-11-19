#!/usr/bin/env python3
"""Builds Data/ForeverSkinZones.lua: per zone, the skinnable beasts, their spawn counts (Forever-seen and Classic), the skinning
skill they need and what one skin gives, so SkinRank.lua can rank zones by skinning gold per hour.

Run: python3 -I tools/build-skin-zones.py          (uses the cached files; downloads the Classic skinning loot once if missing)
     python3 -I tools/build-skin-zones.py --fetch  (also downloads the missing ForeverDB item pages, one request every 1.5 s)

Sources:
  - ForeverDB.net (https://foreverdb.net), GPL-3.0 with the attribution term "Data from ForeverDB.net":
    tools/cache-foreverdb/Gather.lua: skinnable beasts of the Forever client (name, levels, npc IDs, sk = ForeverDB's Classic-rule
    skill) and their spawn points per zone, `f` = points players saw in WoW Forever, `c` = Classic (CMaNGOS) points;
    tools/cache-foreverdb/pages/item<id>.html: the first sources of each leather, hide and scale, "seen in WoW Forever" or not.
  - CMaNGOS classic-db (https://github.com/cmangos/classic-db, GPL-3.0), pinned commit CMANGOS_SHA: creature_template.SkinningLootId
    and skinning_loot_template, i.e. what one skin gives in CLASSIC (chance x average count). Extracted once to
    tools/cache-cmangos/skinloot.tsv (Classic data does not change). Never confirmed on Forever: flagged as Classic in the output.
Standard library only; the downloaded files are parsed as text, never executed.
"""
import gzip, importlib.util, pathlib, re, sys, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOLS = pathlib.Path(__file__).resolve().parent
OUT = ROOT / "Data" / "ForeverSkinZones.lua"
CMANGOS_CACHE = TOOLS / "cache-cmangos"
SKINLOOT = CMANGOS_CACHE / "skinloot.tsv"
CMANGOS_SHA = "28ef6259c782928b08a8dc9cacf6bc02e64f2b29"
CMANGOS_URL = f"https://raw.githubusercontent.com/cmangos/classic-db/{CMANGOS_SHA}/Full_DB/ClassicDB_1_12_1_z2815.sql.gz"
MAX_BEASTS = 16          # per zone, the beasts with the most spawn points first


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, TOOLS / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


skinning = load("build_skinning", "build-skinning.py")   # ITEMS, page_sources, fetch politeness (UA)
gather = load("build_gather", "build-gather.py")          # parse_gather

# Skinning items that are not in build-skinning.py's ITEMS but appear in the Classic skinning loot of a beast; their ForeverDB pages
# are read for Forever evidence (scripts/update_data.py downloads them through the same "<id>: (" pattern).
EXTRA_ITEMS = {
    5082: ("Thin Kodo Leather",),
    5785: ("Thick Murloc Scale",),
    7286: ("Black Whelp Scale",),
    7392: ("Green Whelp Scale",),
    7428: ("Shadowcat Hide",),
    8165: ("Worn Dragonscale",),
    15408: ("Heavy Scorpid Scale",),
    15412: ("Green Dragonscale",),
    15414: ("Red Dragonscale",),
    15415: ("Blue Dragonscale",),
    15416: ("Black Dragonscale",),
    15417: ("Devilsaur Leather",),
    15419: ("Warbear Leather",),
    15423: ("Chimera Leather",),
    17012: ("Core Leather",),
    20381: ("Dreamscale",),
}


# --------------------------------------------------------------------------------------------------------- Classic loot
VALUE = re.compile(r"'(?:[^'\\]|\\.)*'|NULL|[-\d.eE+]+")


def sql_rows(line):
    """Tuples of one `INSERT INTO ... VALUES (...),(...);` line, as raw field strings (quotes kept)."""
    pos = line.index(" VALUES ") + 8
    while pos < len(line) and line[pos] == "(":
        pos += 1
        row = []
        while True:
            m = VALUE.match(line, pos)
            row.append(m.group(0))
            pos = m.end()
            if line[pos] == ")":
                break
            pos += 1                                    # the comma
        yield row
        pos += 2                                        # ")," or ");"


def extract_skinloot():
    """Downloads the pinned CMaNGOS dump (13 MB, streamed) and keeps npc -> skinning loot rows in tools/cache-cmangos/skinloot.tsv."""
    CMANGOS_CACHE.mkdir(exist_ok=True)
    req = urllib.request.Request(CMANGOS_URL, headers={"User-Agent": skinning.USER_AGENT})
    columns, skin_of, loot = None, {}, {}
    with urllib.request.urlopen(req, timeout=120) as r, gzip.open(r, "rt", encoding="utf-8", errors="replace") as text:
        in_ct = False
        for line in text:
            if line.startswith("CREATE TABLE `creature_template`"):
                in_ct, columns = True, []
            elif in_ct and line.startswith("  `"):
                columns.append(line.split("`")[1])
            elif in_ct and line.startswith(")"):
                in_ct = False
            elif line.startswith("INSERT INTO `creature_template` VALUES"):
                e, s = columns.index("Entry"), columns.index("SkinningLootId")
                for row in sql_rows(line):
                    if int(row[s]):
                        skin_of[int(row[e])] = int(row[s])
            elif line.startswith("INSERT INTO `skinning_loot_template` VALUES"):
                for row in sql_rows(line):
                    entry, item, chance, group, mn, mx = (float(v) for v in row[:6])
                    if mn < 0:                          # a reference: the Classic skinning table has none, refuse to guess
                        raise SystemExit(f"skinning_loot_template {int(entry)}: reference rows are not supported")
                    loot.setdefault(int(entry), []).append((int(item), chance, int(group), int(mn), int(mx)))
    if not skin_of or not loot:
        raise SystemExit("CMaNGOS dump: creature_template or skinning_loot_template not found")
    lines = ["# npc\titem\tchance\tgroup\tmin\tmax  (CMaNGOS classic-db " + CMANGOS_SHA + ", GPL-3.0)"]
    for npc in sorted(skin_of):
        for item, chance, group, mn, mx in loot.get(skin_of[npc], []):
            lines.append(f"{npc}\t{item}\t{chance:g}\t{group}\t{mn}\t{mx}")
    SKINLOOT.write_text("\n".join(lines) + "\n", encoding="utf-8")


def classic_loot():
    """npc -> {item: expected count per skin} (chance/100 x average of min..max; groups and independent rows alike)."""
    if not SKINLOOT.exists():
        extract_skinloot()
    out = {}
    for line in SKINLOOT.read_text(encoding="utf-8").splitlines()[1:]:
        npc, item, chance, _, mn, mx = line.split("\t")
        per = out.setdefault(int(npc), {})
        per[int(item)] = per.get(int(item), 0) + float(chance) / 100 * (int(mn) + int(mx)) / 2
    return out


# ---------------------------------------------------------------------------------------------------------------- build
def fetch_pages(items):
    skinning.PAGES.mkdir(parents=True, exist_ok=True)
    for item in items:
        path = skinning.PAGES / f"item{item}.html"
        if path.exists():
            continue
        req = urllib.request.Request(f"https://foreverdb.net/item/{item}", headers={"User-Agent": skinning.USER_AGENT})
        with urllib.request.urlopen(req, timeout=60) as r:
            path.write_bytes(r.read())
        time.sleep(1.5)


def known_zones():
    text = (ROOT / "Data" / "Zones.lua").read_text(encoding="utf-8")
    return {int(z): n for z, n in re.findall(r'\[(\d+)\] = \{ "([^"]*)"', text)}


def main():
    text = (skinning.CACHE / "Gather.lua").read_text(encoding="utf-8")
    kinds = {}
    for k, name, sk, lo, hi, npcs in re.findall(
            r'\[(\d+)\] = \{ n = "((?:[^"\\]|\\.)*)", p = "skin", sk = (\d+), lv = \{ (\d+), (\d+) \}, npc = \{ ([\d, ]+) \}', text):
        kinds[int(k)] = (name, int(sk), int(lo), int(hi), [int(n) for n in npcs.split(",")])
    _, zones = gather.parse_gather(text)
    loot = classic_loot()

    page_items = sorted(set(skinning.ITEMS) | set(EXTRA_ITEMS))
    if "--fetch" in sys.argv:
        fetch_pages(page_items)
    seen = {}                                            # beast name -> items ForeverDB saw it drop in Forever
    for item in page_items:
        for name, forever in skinning.page_sources(item):
            if forever:
                seen.setdefault(name, set()).add(item)

    names = known_zones()
    out_zones, unmapped, report = {}, {}, {"beasts": set(), "fseen": set(), "items_f": 0, "items_c": 0, "items_nil": 0}
    for zid, z in sorted(zones.items()):
        beasts = []
        for k, (c, f) in z["k"].items():
            if k not in kinds:
                continue
            name, sk, lo, hi, npcs = kinds[k]
            if zid not in names:
                unmapped.setdefault(zid, set()).add(name)
                continue
            per = {}                                     # item -> Classic expected count, averaged over the kind's npc IDs
            with_loot = [loot[n] for n in npcs if n in loot]
            for table in with_loot:
                for item, count in table.items():
                    per[item] = per.get(item, 0) + count / len(with_loot)
            items = [(i, round(per[i], 3), i in seen.get(name, ())) for i in sorted(per, key=lambda i: (-per[i], i))
                     if per[i] >= 0.0005]
            items += [(i, None, True) for i in sorted(seen.get(name, ())) if i not in per]
            beasts.append((len(f), len(c), npcs[0], name, lo, hi, sk, items))
        beasts.sort(key=lambda b: (-max(b[0], b[1]), -b[0], b[2]))
        if beasts:
            out_zones[zid] = beasts[:MAX_BEASTS]

    out = [
        "-- GENERATED by tools/build-skin-zones.py. Do not edit by hand.",
        "-- Data from ForeverDB.net (https://foreverdb.net), game build 1.60.1.70959: Gather.lua and the item pages",
        "-- https://foreverdb.net/item/<id>. Classic skinning loot: CMaNGOS classic-db (https://github.com/cmangos/classic-db,",
        f"-- commit {CMANGOS_SHA[:10]}). Licence: GPL-3.0 (ForeverDB with an attribution term, section 7(b)), see NOTICE and THIRD-PARTY.",
        "-- ns.SkinZones[uiMapID] = { { npcID, English name, lvMin, lvMax, skill, spots = n, foreverSpots = n, skillForever = bool,",
        "--                             items = { { itemID, perSkin, forever = bool }, ... } }, ... }",
        "--   uiMapID: the Classic numbering of Data/Zones.lua (1411 = Durotar). Up to " + str(MAX_BEASTS) + " beasts per zone, most spawn points first.",
        "--   spots: Classic spawn points of the beast in the zone (CMaNGOS via ForeverDB), NOT confirmed on Forever.",
        "--   foreverSpots: points players saw the beast at in WoW Forever (ForeverDB Companion); a sample, not a full count.",
        "--   skill: skinning skill needed for the highest level, ForeverDB's assumption of Classic's rule (1 up to level 10,",
        "--     (level - 10) x 10 up to 20, then level x 5). skillForever = true when skill > 100: the Forever client's own Skinning",
        "--     description (shown by ForeverDB) says \"above 100, divide your skill by 5 to get the highest level you can skin\".",
        "--   perSkin: expected count of the item per skin in CLASSIC (CMaNGOS skinning_loot_template: chance x average count), never",
        "--     Forever data; nil = unknown (the item is only known from Forever, no Classic loot row).",
        "--   forever = true: ForeverDB lists this beast as a source of the item SEEN IN WOW FOREVER (it lists only the first sources",
        "--     of an item and does not split skinning loot from corpse loot); false = Classic only.",
        "local _, ns = ...",
        "ns.SkinZones = {",
    ]
    for zid, beasts in out_zones.items():
        out.append(f"  [{zid}] = {{  -- {names[zid]}")
        for fs, cs, npc, name, lo, hi, sk, items in beasts:
            report["beasts"].add(npc)
            if fs:
                report["fseen"].add(npc)
            cells = []
            for item, per, fv in items:
                report["items_f" if fv else "items_c"] += 1
                report["items_nil"] += per is None
                cells.append(f"{{ {item}, {'nil' if per is None else f'{per:g}'}, forever = {str(fv).lower()} }}")
            out.append(f'    {{ {npc}, {gather.lua_str(name)}, {lo}, {hi}, {sk}, spots = {cs}, foreverSpots = {fs}, '
                       f'skillForever = {str(sk > 100).lower()}, items = {{ {", ".join(cells)} }} }},')
        out.append("  },")
    out.append("}")
    OUT.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}: {len(out_zones)} zones, {len(report['beasts'])} beasts "
          f"({len(report['fseen'])} with Forever-seen spawns), item rows: {report['items_f']} Forever-seen, "
          f"{report['items_c']} Classic only, {report['items_nil']} without a Classic yield; {OUT.stat().st_size} bytes")
    for zid, ns_ in sorted(unmapped.items()):
        print(f"unmapped zone {zid} (not in Data/Zones.lua): {len(ns_)} beasts, e.g. {', '.join(sorted(ns_)[:3])}")


if __name__ == "__main__":
    main()
