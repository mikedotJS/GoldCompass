#!/usr/bin/env python3
"""Builds Data/ForeverTrainers.lua from the per-profession recipe tables of wowforever.be (in-game observed data).

Run: python3 tools/fetch-wowforever.py          (fetches, then writes the data file)
     python3 tools/fetch-wowforever.py --cached (uses only the cached pages)
Polite on purpose: one request per profession page, a 2 second pause between requests, a clear User-Agent, and the
pages are cached under tools/cache-wowforever/ (git-ignored, never shipped in the addon). robots.txt of the site allows
these pages. Only the standard library is used.

Each table row gives the five skill numbers (learn, orange, yellow, green, gray), the crafted item (FIRST item link), the
reagents and a Source cell ("Trainer · 1s", "Vendor, Trainer · 5s <NPC> (<zone>)", "Known from the start", ...). The crafted
item is mapped to the craft spell ID with Data/Recipes.lua (output item) or LibProfessionDB's Forever core files
(craftedItemId, pass --lpdb DIR); rows that match neither are reported.
"""
import argparse, html, pathlib, re, sys, time, urllib.error, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = pathlib.Path(__file__).resolve().parent / "cache-wowforever"
BASE = "https://wowforever.be/tradeskills/forever/{}/recipes/"
USER_AGENT = "GoldCompass-data-build/1.0 (personal addon data build; one request per page)"
# page slug -> profession name of Data/Recipes.lua (and the LibProfessionDB core file name)
PROFESSIONS = {
    "alchemy": ("Alchemy", "Alchemy"), "blacksmithing": ("Blacksmithing", "Blacksmithing"), "cooking": ("Cooking", "Cooking"),
    "enchanting": ("Enchanting", "Enchanting"), "engineering": ("Engineering", "Engineering"), "first-aid": ("First Aid", "Firstaid"),
    "fishing": ("Fishing", "Fishing"), "leatherworking": ("Leatherworking", "Leatherworking"), "mining": ("Mining", "Mining"),
    "tailoring": ("Tailoring", "Tailoring"), "skinning": ("Skinning", "Skinning"), "herbalism": ("Herbalism", "Herbalism"),
}


def money(text):
    """'1g 50s 5c' -> copper."""
    total = 0
    for amount, unit in re.findall(r"(\d+)\s*([gsc])", text):
        total += int(amount) * {"g": 10000, "s": 100, "c": 1}[unit]
    return total


def rank_of(learn):
    """Profession rank a trainer needs to teach a recipe of this learn skill (Kamari, an Apprentice trainer, taught
    nothing from skill 50 up): Apprentice below 50, Journeyman below 125, Expert below 200, Artisan from 200."""
    return "Apprentice" if learn < 50 else "Journeyman" if learn < 125 else "Expert" if learn < 200 else "Artisan"


def parse_rows(page):
    """Rows of a recipe table: dicts { item, name, learn, thresholds (orange, yellow, green, gray), trainer (bool),
    cost (copper or None), vendor (text or None), kinds (set), start (bool) }."""
    out = []
    for row in re.findall(r'<tr[^>]*data-learn="[^>]*>.*?</tr>', page, re.S):
        learn = int(re.search(r'data-learn="(\d+)"', row).group(1))
        kinds = set(re.search(r'data-src="([^"]*)"', row).group(1).split())
        colors = [int(n) for n in re.findall(r'class="c-[oygx]"[^>]*>(\d+)<', row)]
        # the crafted item is the link with class wf-ts__item; an enchant links its craft spell instead
        # (spell=ID); never fall back on a reagent link
        item = re.search(r'class="wf-ts__item"[^>]*href="[^"]*/(item|spell)=(\d+)"', row)
        name = re.search(r'class="wf-ts__item".*?<span[^>]*>([^<]*)</span>', row, re.S) \
            or re.search(r'<td[^>]*>\s*<span[^>]*>([^<]*)</span>', row[row.find("</td>"):], re.S)
        cell = re.search(r'<td class="wf-ts__source"[^>]*>(.*?)</td>', row, re.S)
        cell = cell.group(1) if cell else ""
        cost = re.search(r'wf-ts__muted[^>]*>\s*·\s*([^<]*)<', cell)
        wheres = [html.unescape(w).strip() for w in re.findall(r'wf-ts__where[^>]*>([^<]*)<', cell)]
        out.append({
            "item": int(item.group(2)) if item and item.group(1) == "item" else None,
            "spell": int(item.group(2)) if item and item.group(1) == "spell" else None, "name": html.unescape(name.group(1)).strip() if name else "", "learn": learn,
            "thresholds": tuple(colors) if len(colors) == 4 else None, "kinds": kinds, "trainer": "trainer" in kinds,
            "cost": money(cost.group(1)) if cost else None, "start": "starter" in kinds,
            "vendor": wheres[0] if "vendor" in kinds and wheres else None,
        })
    return out


def page_build(page):
    m = re.search(r"build (\d+(?:\.\d+)+) · ([0-9]+ \w+ \d{4})", page)
    return (m.group(1), m.group(2)) if m else (None, None)


def fetch(slug, cached_only):
    CACHE.mkdir(exist_ok=True)
    path = CACHE / f"{slug}.html"
    if path.exists() or cached_only:
        return path.read_text(encoding="utf-8") if path.exists() else None
    time.sleep(2)  # polite pause: one request per page, two seconds apart
    req = urllib.request.Request(BASE.format(slug), headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            page = r.read().decode("utf-8")
    except urllib.error.HTTPError as e:  # a profession without a recipe page: reported, not fatal
        print(f"{slug}: HTTP {e.code} for {BASE.format(slug)}", file=sys.stderr)
        return None
    path.write_text(page, encoding="utf-8")
    return page


def spell_maps(lpdb_dir):
    """{ profession: { itemID: [spellID, ...] } } from Data/Recipes.lua and the LibProfessionDB Forever core files."""
    maps, names = {}, {}
    text = (ROOT / "Data/Recipes.lua").read_text(encoding="utf-8")
    for rid, prof, item, name in re.findall(r'\{ (\d+), "([^"]+)", \d+, (\d+), \d+, \d+, \d+, "([^"]*)"', text):
        maps.setdefault(prof, {}).setdefault(int(item), []).append(int(rid))
        names[int(rid)] = name
    lib = {}
    if lpdb_dir:
        for slug, (prof, fname) in PROFESSIONS.items():
            f = pathlib.Path(lpdb_dir) / f"{fname}.lua"
            if f.exists():
                for rid, body in re.findall(r"\[(\d+)\] = \{(.*?)\n\t\t\},", f.read_text(encoding="utf-8"), re.S):
                    m = re.search(r'\["craftedItemId"\] = (\d+)', body)
                    if m:
                        lib.setdefault(prof, {}).setdefault(int(m.group(1)), []).append(int(rid))
    return maps, lib, names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cached", action="store_true", help="never touch the network")
    ap.add_argument("--lpdb", help="LibProfessionDB Data/Forever/_core folder (second source of item -> spell)")
    args = ap.parse_args()
    maps, lib, names = spell_maps(args.lpdb)
    table, build, stats, unmatched = {}, None, [], []
    for slug, (prof, _) in PROFESSIONS.items():
        page = fetch(slug, args.cached)
        if page is None:
            print(f"{slug}: no cached page", file=sys.stderr)
            continue
        build = build or page_build(page)
        rows = parse_rows(page)
        taught = matched = 0
        for r in rows:
            spells = [r["spell"]] if r["spell"] else maps.get(prof, {}).get(r["item"]) or lib.get(prof, {}).get(r["item"]) or []
            if len(spells) > 1:  # same output item for several crafts: the one with the page's recipe name
                spells = [s for s in spells if names.get(s, "").lower() == r["name"].lower()] or spells[:1]
            if not spells:
                unmatched.append((slug, r["item"], r["name"], r["kinds"]))
                continue
            matched += 1
            wanted = r["trainer"] or r["start"] or r["vendor"]
            if not wanted:
                continue
            entry = {"learn": r["learn"]}
            if r["trainer"] and r["cost"] is not None:
                entry["cost"], entry["rank"] = r["cost"], rank_of(r["learn"])
                taught += 1
            if r["vendor"]:
                entry["vendor"] = r["vendor"]
            if r["start"]:
                entry["start"] = True
            table[spells[0]] = entry
        stats.append((slug, len(rows), matched, taught))
    q = lambda x: '"' + x.replace("\\", "\\\\").replace('"', '\\"') + '"'
    out = [
        "-- GENERATED by tools/fetch-wowforever.py. Do not edit by hand.",
        "-- Source: https://wowforever.be/tradeskills/forever/<profession>/recipes/ (wowforever.be), in-game observed WoW Forever data,",
        f"-- build {build[0] if build else '?'} ({build[1] if build else '?'}), fetched {time.strftime('%d %B %Y')}. Credit: wowforever.be.",
        "-- ns.ForeverTrainers[craftSpellID] = { learn = skill needed, cost = trainer fee in copper (the recipe IS taught by a trainer),",
        "--   rank = profession rank a trainer needs (Apprentice | Journeyman | Expert | Artisan), vendor = \"NPC (Zone)\", start = true when",
        "--   known from the start }. A recipe with no entry here is not taught by a trainer on Forever.",
        "local _, ns = ...",
        "ns.ForeverTrainers = {",
    ]
    for sid in sorted(table):
        e = table[sid]
        parts = [f"learn = {e['learn']}"]
        if "cost" in e:
            parts += [f"cost = {e['cost']}", f"rank = {q(e['rank'])}"]
        if "vendor" in e:
            parts.append(f"vendor = {q(e['vendor'])}")
        if e.get("start"):
            parts.append("start = true")
        out.append(f"  [{sid}] = {{ {', '.join(parts)} }},")
    out.append("}")
    (ROOT / "Data/ForeverTrainers.lua").write_text("\n".join(out) + "\n", encoding="utf-8")
    for slug, rows, matched, taught in stats:
        print(f"{slug}: {rows} rows, {matched} matched to a craft spell, {taught} trainer-taught")
    print(f"total: {sum(s[1] for s in stats)} rows, {sum(s[3] for s in stats)} trainer-taught, {len(unmatched)} unmatched")
    for slug, item, name, kinds in unmatched:
        print(f"unmatched: {slug} item {item} {name} ({' '.join(sorted(kinds))})")


if __name__ == "__main__":
    main()
