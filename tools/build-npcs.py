#!/usr/bin/env python3
"""Builds Data/Npcs.lua from pfQuest (by shagu, MIT, https://github.com/shagu/pfQuest): the spawn coordinates and faction of only the NPCs
Gold Compass can point to.

Run: python3 tools/build-npcs.py <pfq folder>
The folder holds units.lua, units-fr.lua (French names), enUS-units.lua (English names), enUS-zones.lua and frFR-zones.lua, the
db/ files of pfQuest (db/enUS/units.lua saved as enUS-units.lua, ...). Standard library only.

NPCs kept: every trainer of Data/Locations.lua (ProfessionsTracker trainer list), every vendor and quest-giver id of the sources in
Data/ForeverRecipes.lua, every NPC named by wowforever.be (Data/ForeverTrainers.lua, "Name (Zone), ...") and by the Classic data
(ns.NPCs, ns.RecipeWhere), matched by English name and, when the text gives a zone, by the zone the NPC spawns in.
"""
import pathlib, re, sys, collections

ROOT = pathlib.Path(__file__).resolve().parent.parent
PFQ = pathlib.Path(sys.argv[1])
MAX_SPAWNS = 3
# Apprentice-rank trainers are missing from the ProfessionsTracker list (its ranks start at Journeyman): the ones the owner's trainer
# windows recorded in game (rank 0 = teaches Apprentice recipes only).
RECORDED_TRAINERS = [("Leatherworking", "Kamari", 0)]


def read(p):
    return p.read_text(encoding="utf-8")


def parse_units(path):
    """{ id: { "fac": str, "coords": [(x, y, zoneID)] } } from pfDB["units"]["data"]."""
    units, cur, in_coords = {}, None, False
    for line in read(path).splitlines():
        m = re.match(r"^  \[(\d+)\] = \{", line)
        if m:
            cur, in_coords = int(m.group(1)), False
            units[cur] = {"fac": None, "coords": []}
            continue
        if cur is None:
            continue
        if '["coords"] = {' in line:
            in_coords = not line.strip().endswith("{},")
            continue
        if in_coords:
            m = re.match(r"^\s+\[\d+\] = \{ ([\d.]+), ([\d.]+), (\d+),", line)
            if m:
                units[cur]["coords"].append((float(m.group(1)), float(m.group(2)), int(m.group(3))))
            elif re.match(r"^    \},?$", line):
                in_coords = False
            continue
        m = re.match(r'^    \["fac"\] = "(\w+)"', line)
        if m:
            units[cur]["fac"] = m.group(1)
    return units


def parse_names(path):
    return {int(i): n.replace('\\"', '"').replace("\\'", "'") for i, n in re.findall(r'^  \[(\d+)\] = "(.*)",$', read(path), re.M)}


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    units = parse_units(PFQ / "units.lua")
    en, fr = parse_names(PFQ / "enUS-units.lua"), parse_names(PFQ / "units-fr.lua")
    zen = parse_names(PFQ / "enUS-zones.lua")
    # the maps Gold Compass knows: English zone name -> uiMapID (Data/Zones.lua), then pfQuest zoneID -> uiMapID by name
    zones_lua = read(ROOT / "Data/Zones.lua")
    ui = {n: int(i) for n, i in re.findall(r'\["([^"]+)"\] = \{ (\d+), "[KE]" \}', zones_lua[zones_lua.index("ns.MapIDs"):])}
    area_to_map = {zid: ui[name] for zid, name in zen.items() if name in ui}
    zone_id_by_name = {name: zid for zid, name in zen.items()}

    by_name = collections.defaultdict(list)
    for i, n in en.items():
        if i in units:
            by_name[n].append(i)

    wanted_ids, wanted_names = set(), []   # names: (name, zone or None, source)
    loc = read(ROOT / "Data/Locations.lua")
    trainers = loc[loc.index("\nns.Trainers = {"):loc.index("\nns.NPCs = {")]
    trainer_list = []      # (profession, name, zone, top rank) of the ProfessionsTracker list, then the recorded ones
    for prof, block in re.findall(r'\["(\w[\w ]*)"\] = \{\n(.*?)\n  \},', trainers, re.S):
        for name, zone, rank in re.findall(r'\{ "([^"]+)", "([^"]+)", [\d.]+, [\d.]+, (?:"[AH]"|nil), (\d) \}', block):
            if int(rank) > 0:                      # rank 0 = specialisation trainers: never pointed to
                trainer_list.append((prof, name, zone, int(rank)))
    for prof, name, rank in RECORDED_TRAINERS:
        trainer_list.append((prof, name, None, rank))
    for prof, name, zone, rank in trainer_list:
        wanted_names.append((name, zone, "trainer"))
    for name in re.findall(r'^  \["([^"]+)"\] = \{ "', loc[loc.index("\nns.NPCs = {"):loc.index("\nns.RecipeWhere = {")], re.M):
        wanted_names.append((name, None, "classic npc"))
    for row in re.findall(r'^  \[\d+\] = \{ "[^"]*", (.*) \},$', loc[loc.index("\nns.RecipeWhere = {"):], re.M):
        for name in re.findall(r'"([^"]+)"', row):
            wanted_names.append((name, None, "classic where"))
    fr_src = read(ROOT / "Data/ForeverRecipes.lua")
    src_block = fr_src[fr_src.index("}, src = {"):fr_src.index("}, name = {")]
    for ids in re.findall(r'\{ "[tvqcd]*", \{ ([\d, ]*) \}, \{ ([\d, ]*) \} \}', src_block):
        for part in ids:
            wanted_ids.update(int(x) for x in part.split(",") if x.strip())
    ft = read(ROOT / "Data/ForeverTrainers.lua")
    for text in re.findall(r'(?:vendor|va|vh) = "([^"]+)"', ft):
        for name, zone in re.findall(r"\s*([^,()]+)\s*\(([^)]*)\)", text):
            wanted_names.append((name.strip(), zone, "wowforever.be"))

    resolved_ids, unresolved = {}, collections.OrderedDict()   # (name, zone) -> [ids]

    def resolve(name, zone):
        cands = [i for i in by_name.get(name, []) if units[i]["coords"]]
        if zone and zone in zone_id_by_name:
            zid = zone_id_by_name[zone]
            inzone = [i for i in cands if any(c[2] == zid for c in units[i]["coords"])]
            if inzone:
                best = max(inzone, key=lambda i: sum(1 for c in units[i]["coords"] if c[2] == zid))
                return [best]
        return cands[:MAX_SPAWNS] if not zone else (cands[:1] if cands else [])

    for name, zone, kind in wanted_names:
        key = (name, zone)
        if key in resolved_ids or key in unresolved:
            continue
        ids = resolve(name, zone)
        if ids:
            resolved_ids[key] = ids
            wanted_ids.update(ids)
        else:
            unresolved[key] = kind

    missing_ids = sorted(i for i in wanted_ids if i not in units or i not in en)
    wanted_ids = {i for i in wanted_ids if i in units and i in en}

    out, unmapped_zones = [], collections.Counter()
    for i in sorted(wanted_ids):
        spawns, seen = [], set()
        for x, y, zid in units[i]["coords"]:
            if zid in area_to_map and zid not in seen:
                seen.add(zid)
                spawns.append((area_to_map[zid], x, y))
            elif zid not in area_to_map:
                unmapped_zones[zen.get(zid, str(zid))] += 1
        spawns = spawns[:MAX_SPAWNS]
        fr_name = fr.get(i)
        out.append(f"  [{i}] = {{ {lua_str(en[i])}, {lua_str(units[i]['fac'] or 'AH')}, {{ " +
                   ", ".join(f"{{ {m}, {x:g}, {y:g} }}" for m, x, y in spawns) + " }" +
                   (f", {lua_str(fr_name)}" if fr_name and fr_name != en[i] else "") + " },")
    npc_trainers = collections.defaultdict(list)
    for prof, name, zone, rank in trainer_list:
        ids = resolved_ids.get((name, zone), [])
        if ids and ids[0] in wanted_ids:
            npc_trainers[prof].append((ids[0], rank))
    names = collections.defaultdict(list)
    for i in sorted(wanted_ids):
        names[en[i]].append(i)
    header = [
        "-- GENERATED by tools/build-npcs.py. Do not edit by hand.",
        "-- Source: pfQuest by shagu (https://github.com/shagu/pfQuest, MIT licence, see NOTICE and THIRD-PARTY): Classic NPC spawns and",
        "-- factions. Only the NPCs Gold Compass can point to: profession trainers, recipe vendors and quest givers (Data/ForeverRecipes.lua",
        "-- sources, wowforever.be vendor texts, Classic data). Positions are original Classic ones: NPCs new to Forever are absent here and",
        "-- are learned in game (merchant and trainer windows).",
        "-- ns.Npcs[npcID] = { English name, faction (\"A\" | \"H\" | \"AH\"), { { uiMapID, x, y }, ... up to 3 spawns }, French name | nil }",
        "-- ns.NpcTrainers[English profession] = { { npcID, top rank (0 Apprentice only, 1 Journeyman, 2 Expert, 3 Artisan) }, ... }",
        "-- ns.NpcByName[English name] = { npcID, ... }",
        "local _, ns = ...",
        "ns.Npcs = {",
    ]
    tail = ["}", "ns.NpcTrainers = {"]
    for prof in sorted(npc_trainers):
        tail.append(f"  [{lua_str(prof)}] = {{ " + ", ".join(f"{{ {i}, {r} }}" for i, r in npc_trainers[prof]) + " },")
    tail += ["}", "ns.NpcByName = {"]
    for n in sorted(names):
        tail.append(f"  [{lua_str(n)}] = {{ {', '.join(str(i) for i in names[n])} }},")
    tail.append("}")
    (ROOT / "Data/Npcs.lua").write_text("\n".join(header + out + tail) + "\n", encoding="utf-8")
    print(f"NPCs written: {len(out)}; name references resolved: {len(resolved_ids)}, unresolved: {len(unresolved)}; ids missing in pfQuest: {len(missing_ids)}")
    for (name, zone), kind in unresolved.items():
        print(f"unresolved ({kind}): {name}" + (f" ({zone})" if zone else ""))
    print("ids referenced by the library sources but not in pfQuest:", len(missing_ids))
    print("spawn zones with no uiMapID (dropped):", dict(unmapped_zones.most_common(25)))


main()
