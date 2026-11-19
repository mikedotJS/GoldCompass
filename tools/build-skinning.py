#!/usr/bin/env python3
"""Builds Data/ForeverSkinning.lua: which beasts give each leather, hide and scale on WoW Forever, and where they stand.

Run: python3 -I tools/build-skinning.py          (uses the cached files)
     python3 -I tools/build-skinning.py --fetch  (downloads the item pages first, one request every 1.5 s)

Sources, all from ForeverDB.net (https://foreverdb.net), GPL-3.0 with the attribution term "Data from ForeverDB.net":
  - tools/cache-foreverdb/Gather.lua (addon data file, see tools/build-foreverdb.py --fetch): the skinnable beasts of the Forever
    client with their levels and spawn points, `f` = points players saw in WoW Forever, `c` = Classic (CMaNGOS) points.
  - tools/cache-foreverdb/Items.lua: per item the total drops players saw in Forever (`s<drops>~<players>`).
  - tools/cache-foreverdb/pages/item<id>.html: the public item pages (https://foreverdb.net/item/<id>, allowed by robots.txt):
    the first sources of an item, each "seen in WoW Forever" or "Classic data". ForeverDB publishes no per-beast count and does not
    split skinning loot from corpse loot, so a beast seen there is kept only when Gather.lua says it is skinnable.
Beasts with no Forever loot evidence are added by the Classic level rule (LEVEL_BANDS below, an assumption, flagged forever = false).
Standard library only; the downloaded files are parsed as text, never executed.
"""
import pathlib, re, sys, time, urllib.request, html as htmllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = pathlib.Path(__file__).resolve().parent / "cache-foreverdb"
PAGES = CACHE / "pages"
OUT = ROOT / "Data" / "ForeverSkinning.lua"
USER_AGENT = "GoldCompass-data-build/1.0 (personal addon data build; credit: Data from ForeverDB.net)"
MAX_BEASTS, MAX_SPOTS = 15, 3

# itemID: (name, Classic level band of the beasts that give it, name filter for scales). Classic rule, not Forever data.
ITEMS = {
    2934: ("Ruined Leather Scraps", 1, 12, None),
    2318: ("Light Leather", 5, 24, None),
    783: ("Light Hide", 10, 24, None),
    2319: ("Medium Leather", 18, 32, None),
    4232: ("Medium Hide", 20, 32, None),
    4234: ("Heavy Leather", 28, 42, None),
    4235: ("Heavy Hide", 30, 42, None),
    4304: ("Thick Leather", 38, 50, None),
    8169: ("Thick Hide", 40, 50, None),
    8170: ("Rugged Leather", 48, 63, None),
    8171: ("Rugged Hide", 50, 63, None),
    8154: ("Scorpid Scale", 40, 63, r"Scorpid"),
    8167: ("Turtle Scale", 35, 55, r"Snapper|Turtle|Surf Glider"),
}


def fetch():
    PAGES.mkdir(parents=True, exist_ok=True)
    for item in ITEMS:
        req = urllib.request.Request(f"https://foreverdb.net/item/{item}", headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=60) as r:
            (PAGES / f"item{item}.html").write_bytes(r.read())
        time.sleep(1.5)


def page_sources(item):
    """[(beast name, seen in Forever)] in the order ForeverDB lists them (its top source first)."""
    path = PAGES / f"item{item}.html"
    if not path.exists():
        return []
    text = re.sub(r"<script.*?</script>|<style.*?</style>", "", path.read_text(encoding="utf-8"), flags=re.S)
    text = re.sub(r"\s+", " ", htmllib.unescape(re.sub(r"<[^>]+>", " ", text)))
    start = text.find("Where to get it")
    if start < 0:                                       # short pages only have the summary sentence
        start = text.find("Where it comes from")
    block = text[start:text.find("Data from the WoW Forever client", start)]
    return [(n.strip(), tag == "seen in WoW Forever")
            for n, tag in re.findall(r"Drops from ([^,(;]+?)(?:, [\d.]+%(?: \(Classic drop rate\))?)? \((seen in WoW Forever|Classic data)\)", block)]


def decode(points):
    return [(int(points[i:i + 2], 36) / 10, int(points[i + 2:i + 4], 36) / 10) for i in range(0, len(points) - 3, 4)]


def main():
    if "--fetch" in sys.argv:
        fetch()
    gather = (CACHE / "Gather.lua").read_text(encoding="utf-8")
    kinds, by_name = {}, {}
    for k, name, lo, hi, npcs in re.findall(
            r'\[(\d+)\] = \{ n = "((?:[^"\\]|\\.)*)", p = "skin", sk = \d+, lv = \{ (\d+), (\d+) \}, npc = \{ ([\d, ]+) \}', gather):
        kinds[int(k)] = (name, int(lo), int(hi), int(npcs.split(",")[0]))
        by_name.setdefault(name, int(k))
    spots = {}                                          # kind -> [(uiMapID, forever points, classic points)]
    zone = None
    for line in gather[gather.index("zones = {"):].splitlines():
        m = re.match(r"\s*\[(\d+)\] = \{ fish", line) or re.match(r"\s*\[(\d+)\] = \{.*k = \{", line)
        if m:
            zone = int(m.group(1))
            continue
        m = re.match(r'\s*\[(\d+)\] = \{ c = "([^"]*)", f = "([^"]*)"', line)
        if m and zone and int(m.group(1)) in kinds:
            spots.setdefault(int(m.group(1)), []).append((zone, decode(m.group(3)), decode(m.group(2))))
    items_src = (CACHE / "Items.lua").read_text(encoding="utf-8")
    seen_total = {int(i): int(s) for i, s in re.findall(r'\[(\d+)\]="[^"]*\|s(\d+)~\d+"', items_src)}

    def fcount(k):
        return sum(len(f) for _, f, _ in spots.get(k, []))

    skinning, used, report = {}, set(), []
    for item, (iname, lo, hi, family) in ITEMS.items():
        rows, have = [], set()
        listed = page_sources(item)
        for name, forever in listed:
            k = by_name.get(name)
            if k is None or k in have:
                continue                                # not a skinnable beast in the Forever client: corpse loot only
            have.add(k)
            rows.append((k, forever))
        ev = [k for k, f in rows if f]
        off = [kinds[k][0] for k in ev if kinds[k][2] < lo or kinds[k][1] > hi]
        rule = sorted((k for k, (n, a, b, _) in kinds.items() if k not in have and a >= lo and b <= hi
                       and (family is None or re.search(family, n))), key=lambda k: (-fcount(k), -kinds[k][1]))
        rows += [(k, False) for k in rule]
        rows = rows[:MAX_BEASTS]
        used.update(k for k, _ in rows)
        skinning[item] = rows
        report.append(f"{item} {iname}: {len(ev)} Forever-seen skinnable, {sum(1 for _ in listed)} listed sources parsed, "
                      f"{len(rows) - len([k for k, f in rows if f])} Classic only; Forever-seen outside the Classic band "
                      f"{lo}-{hi}: {', '.join(off) or 'none'}")

    out = [
        "-- GENERATED by tools/build-skinning.py. Do not edit by hand.",
        "-- Data from ForeverDB.net (https://foreverdb.net), game build 1.60.1.70959: Gather.lua, Items.lua and the item pages",
        "-- https://foreverdb.net/item/<id>. Licence: GPL-3.0 with an attribution term (section 7(b)), see NOTICE and THIRD-PARTY.",
        "-- ns.Skinning[itemID] = { { npcID, English name, lvMin, lvMax, observed = nil, forever = bool }, ... }",
        "--   forever = true: ForeverDB lists the beast as a source of the item SEEN IN WOW FOREVER (players' addons). ForeverDB does",
        "--   not publish per-beast counts (observed is always nil) and does not split skinning loot from corpse loot; the beast is kept",
        "--   only if the Forever client marks it skinnable. Listed in ForeverDB's order (its top source first).",
        "--   forever = false: Classic data (ForeverDB's CMaNGOS source, or the Classic level rule of tools/build-skinning.py), NOT",
        "--   confirmed on Forever. Beasts with Forever-seen spawn points come first.",
        "-- ns.SkinSpots[npcID] = { { uiMapID, x, y, forever = bool }, ... } up to 3 points, Forever-seen points first.",
        "local _, ns = ...",
        "ns.SkinningSeen = {  -- [itemID] = drops players saw in Forever, all sources together (Items.lua `s`)",
    ]
    out += [f"  [{i}] = {seen_total[i]}," for i in ITEMS if i in seen_total]
    out += ["}", "ns.Skinning = {"]
    for item, rows in skinning.items():
        out.append(f"  [{item}] = {{  -- {ITEMS[item][0]}")
        for k, forever in rows:
            name, lo, hi, npc = kinds[k]
            out.append(f'    {{ {npc}, "{name}", {lo}, {hi}, forever = {str(forever).lower()} }},')
        out.append("  },")
    out += ["}", "ns.SkinSpots = {"]
    for k in sorted(used, key=lambda k: kinds[k][3]):
        zones = sorted(spots.get(k, []), key=lambda z: (-len(z[1]), -len(z[2])))
        if not zones:
            continue
        zid, f, c = zones[0]
        pts = [(p, True) for p in f] + [(p, False) for p in c]
        step = max(1, len(pts) // MAX_SPOTS) if not f or len(f) >= MAX_SPOTS else 1
        pick = pts[::step][:MAX_SPOTS]
        cells = ", ".join(f"{{ {zid}, {x:g}, {y:g}, forever = {str(fv).lower()} }}" for (x, y), fv in pick)
        out.append(f"  [{kinds[k][3]}] = {{ {cells} }},")
    out.append("}")
    OUT.write_text("\n".join(out) + "\n", encoding="utf-8")
    print("\n".join(report))
    print(f"wrote {OUT.relative_to(ROOT)}: {len(used)} beasts")


if __name__ == "__main__":
    main()
