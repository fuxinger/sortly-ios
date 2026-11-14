#!/usr/bin/env python3
"""Builds Albumist's offline world map (countries + first-level regions).

Source: Natural Earth 1:10m Admin-0 countries and Admin-1 states/provinces,
public domain (https://www.naturalearthdata.com/about/terms-of-use/).

Usage:
    python3 -I build_world_map.py <admin0.geojson> <admin1.geojson> <out.sortlymap>

Download the inputs from
    https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_admin_0_countries.geojson
    https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_admin_1_states_provinces.geojson

Binary format "SWM1" (little endian), read by SortlyCore/Places/OfflineWorldMap.swift:
    magic "SWM1", u16 version, u16 reserved, i32 scale (coordinates are degrees * scale)
    u32 stringCount, then per string: u16 byteLength + UTF-8 bytes
    u32 regionCount, then per region (40 bytes):
        u8 level (0 = country, 1 = region), u8 reserved, u16 reserved,
        i32 parent (country region index, -1 for countries),
        u32 iso (string index), u32 nameDE, u32 nameEN,
        i32 minLat, i32 minLon, i32 maxLat, i32 maxLon,
        u32 firstRing, u32 ringCount
    u32 ringCount, then per ring: u32 byteOffset (into the point stream), u32 pointCount
    u32 byteLength, then the point stream: per ring and point, zig-zag LEB128 varint
        deltas of lat and lon to the previous point of the same ring (first point: to 0, 0).
        Rings can be decoded lazily, only for regions whose bounding box matches.
Rings of one region are evaluated with the even-odd rule (holes need no flag).
"""
import json
import struct
import sys

SCALE = 100_000            # 1e-5 degrees ≈ 1.1 m
TOLERANCE = 0.003          # Douglas–Peucker tolerance in degrees (≈ 330 m)
MIN_RING_AREA = 0.0004     # drop specks smaller than ≈ 4 km² (in squared degrees)

# Natural Earth uses -99 for some disputed or special areas; map them to the code
# Apple's geocoder reports so offline and online results share place keys.
ISO_FALLBACK = {"Somaliland": "SO", "N. Cyprus": "CY", "Kosovo": "XK", "France": "FR", "Norway": "NO"}


# Countries whose Natural Earth admin-1 units are provinces/departments, while Apple's
# geocoder reports the larger region as `administrativeArea` ("Latium", not "Rom").
# Their provinces are merged by this field; names: (German, English).
DISSOLVE_FIELD = {"ITA": "region", "ESP": "region", "FRA": "region", "GBR": "geonunit"}
REGION_NAMES = {
    # Italy
    "Abruzzo": ("Abruzzen", "Abruzzo"), "Apulia": ("Apulien", "Apulia"), "Basilicata": ("Basilikata", "Basilicata"),
    "Calabria": ("Kalabrien", "Calabria"), "Campania": ("Kampanien", "Campania"), "Emilia-Romagna": ("Emilia-Romagna", "Emilia-Romagna"),
    "Friuli-Venezia Giulia": ("Friaul-Julisch Venetien", "Friuli Venezia Giulia"), "Lazio": ("Latium", "Lazio"),
    "Liguria": ("Ligurien", "Liguria"), "Lombardia": ("Lombardei", "Lombardy"), "Marche": ("Marken", "Marche"),
    "Molise": ("Molise", "Molise"), "Piemonte": ("Piemont", "Piedmont"), "Sardegna": ("Sardinien", "Sardinia"),
    "Sicily": ("Sizilien", "Sicily"), "Toscana": ("Toskana", "Tuscany"), "Trentino-Alto Adige": ("Trentino-Südtirol", "Trentino-South Tyrol"),
    "Umbria": ("Umbrien", "Umbria"), "Valle d'Aosta": ("Aostatal", "Aosta Valley"), "Veneto": ("Venetien", "Veneto"),
    # Spain
    "Andalucía": ("Andalusien", "Andalusia"), "Aragón": ("Aragonien", "Aragon"), "Asturias": ("Asturien", "Asturias"),
    "Canary Is.": ("Kanarische Inseln", "Canary Islands"), "Cantabria": ("Kantabrien", "Cantabria"),
    "Castilla y León": ("Kastilien und León", "Castile and León"), "Castilla-La Mancha": ("Kastilien-La Mancha", "Castilla-La Mancha"),
    "Cataluña": ("Katalonien", "Catalonia"), "Ceuta": ("Ceuta", "Ceuta"), "Extremadura": ("Extremadura", "Extremadura"),
    "Foral de Navarra": ("Navarra", "Navarre"), "Galicia": ("Galicien", "Galicia"), "Islas Baleares": ("Balearen", "Balearic Islands"),
    "La Rioja": ("La Rioja", "La Rioja"), "Madrid": ("Madrid", "Madrid"), "Melilla": ("Melilla", "Melilla"), "Murcia": ("Murcia", "Murcia"),
    "País Vasco": ("Baskenland", "Basque Country"), "Valenciana": ("Valencia", "Valencia"),
    # France
    "Auvergne-Rhône-Alpes": ("Auvergne-Rhône-Alpes", "Auvergne-Rhône-Alpes"), "Bourgogne-Franche-Comté": ("Burgund-Franche-Comté", "Bourgogne-Franche-Comté"),
    "Bretagne": ("Bretagne", "Brittany"), "Centre-Val de Loire": ("Centre-Val de Loire", "Centre-Val de Loire"), "Corse": ("Korsika", "Corsica"),
    "Grand Est": ("Grand Est", "Grand Est"), "Guadeloupe": ("Guadeloupe", "Guadeloupe"), "Guyane française": ("Französisch-Guayana", "French Guiana"),
    "Hauts-de-France": ("Hauts-de-France", "Hauts-de-France"), "Martinique": ("Martinique", "Martinique"), "Mayotte": ("Mayotte", "Mayotte"),
    "Normandie": ("Normandie", "Normandy"), "Nouvelle-Aquitaine": ("Nouvelle-Aquitaine", "Nouvelle-Aquitaine"), "Occitanie": ("Okzitanien", "Occitania"),
    "Pays de la Loire": ("Pays de la Loire", "Pays de la Loire"), "Provence-Alpes-Côte-d'Azur": ("Provence-Alpes-Côte d’Azur", "Provence-Alpes-Côte d’Azur"),
    "Réunion": ("Réunion", "Réunion"), "Île-de-France": ("Île-de-France", "Île-de-France"),
    # United Kingdom
    "England": ("England", "England"), "Northern Ireland": ("Nordirland", "Northern Ireland"), "Scotland": ("Schottland", "Scotland"), "Wales": ("Wales", "Wales"),
}


def simplify(points, tol):
    if len(points) < 4:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    tol2 = tol * tol
    while stack:
        a, b = stack.pop()
        ax, ay = points[a]
        bx, by = points[b]
        dx, dy = bx - ax, by - ay
        length2 = dx * dx + dy * dy
        best, index = -1.0, -1
        for i in range(a + 1, b):
            px, py = points[i]
            if length2 == 0:
                d = (px - ax) ** 2 + (py - ay) ** 2
            else:
                t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length2))
                d = (px - ax - t * dx) ** 2 + (py - ay - t * dy) ** 2
            if d > best:
                best, index = d, i
        if best > tol2 and index > 0:
            keep[index] = True
            stack.append((a, index))
            stack.append((index, b))
    return [p for p, k in zip(points, keep) if k]


def ring_area(points):
    s = 0.0
    for (x1, y1), (x2, y2) in zip(points, points[1:] + points[:1]):
        s += x1 * y2 - x2 * y1
    return abs(s) / 2


def polygons(geometry):
    if geometry is None:
        return []
    if geometry["type"] == "Polygon":
        return [geometry["coordinates"]]
    if geometry["type"] == "MultiPolygon":
        return geometry["coordinates"]
    return []


def zigzag(n):
    return (n << 1) ^ (n >> 63)


def varint(buffer, n):
    while True:
        byte = n & 0x7F
        n >>= 7
        if n:
            buffer.append(byte | 0x80)
        else:
            buffer.append(byte)
            return


class Writer:
    def __init__(self):
        self.strings, self.string_index = [], {}
        self.regions, self.rings, self.points = [], [], []

    def string(self, value):
        value = value or ""
        if value not in self.string_index:
            self.string_index[value] = len(self.strings)
            self.strings.append(value)
        return self.string_index[value]

    def add_region(self, level, parent, iso, name_de, name_en, geometry):
        return self.add_region_parts(level, parent, iso, name_de, name_en, [geometry])

    def add_region_parts(self, level, parent, iso, name_de, name_en, geometries):
        first_ring = len(self.rings)
        lats, lons = [], []
        all_polygons = [poly for g in geometries for poly in polygons(g)]
        for polygon in all_polygons:
            for ring_index, ring in enumerate(polygon):
                pts = [(lon, lat) for lon, lat in ring]
                if pts and pts[0] == pts[-1]:
                    pts = pts[:-1]
                # Keep every exterior ring of a tiny island? Only if it is the region's only land.
                if ring_area(pts) < MIN_RING_AREA and not (ring_index == 0 and len(all_polygons) == 1):
                    continue
                simplified = simplify(pts + [pts[0]], TOLERANCE)[:-1]
                # Tiny areas (Vatican, Monaco, small islands) keep their full outline.
                pts = simplified if len(simplified) >= 4 else pts
                if len(pts) < 3:
                    continue
                self.rings.append((len(self.points), len(pts)))
                for lon, lat in pts:
                    self.points.append((round(lat * SCALE), round(lon * SCALE)))
                    lats.append(lat)
                    lons.append(lon)
        ring_count = len(self.rings) - first_ring
        if ring_count == 0:
            return None
        bbox = (round(min(lats) * SCALE), round(min(lons) * SCALE), round(max(lats) * SCALE), round(max(lons) * SCALE))
        self.regions.append((level, parent, self.string(iso), self.string(name_de), self.string(name_en), bbox, first_ring, ring_count))
        return len(self.regions) - 1

    def write(self, path):
        out = bytearray(b"SWM1")
        out += struct.pack("<HHi", 1, 0, SCALE)
        out += struct.pack("<I", len(self.strings))
        for s in self.strings:
            b = s.encode("utf-8")
            out += struct.pack("<H", len(b)) + b
        out += struct.pack("<I", len(self.regions))
        for level, parent, iso, de, en, bbox, first_ring, ring_count in self.regions:
            out += struct.pack("<BBHiIII4iII", level, 0, 0, parent, iso, de, en, *bbox, first_ring, ring_count)
        encoded = bytearray()
        offsets = []
        for first, count in self.rings:
            offsets.append(len(encoded))
            prev_lat = prev_lon = 0
            for lat, lon in self.points[first:first + count]:
                varint(encoded, zigzag(lat - prev_lat))
                varint(encoded, zigzag(lon - prev_lon))
                prev_lat, prev_lon = lat, lon
        out += struct.pack("<I", len(self.rings))
        for (first, count), offset in zip(self.rings, offsets):
            out += struct.pack("<II", offset, count)
        # Points: per ring, zig-zag LEB128 varints of deltas to the previous point
        # (first point of a ring is a delta to (0, 0)). Neighbouring points are close, so
        # most deltas fit into one or two bytes.
        out += struct.pack("<I", len(encoded)) + encoded
        with open(path, "wb") as f:
            f.write(out)
        return len(out)


def main(admin0_path, admin1_path, out_path):
    admin0 = json.load(open(admin0_path, encoding="utf-8"))
    admin1 = json.load(open(admin1_path, encoding="utf-8"))
    w = Writer()
    country_by_a3 = {}
    for feature in sorted(admin0["features"], key=lambda f: f["properties"]["ADM0_A3"]):
        p = feature["properties"]
        iso = p.get("ISO_A2_EH") or p.get("ISO_A2")
        if not iso or iso == "-99":
            iso = ISO_FALLBACK.get(p.get("NAME") or "", "")
        index = w.add_region(0, -1, iso, p.get("NAME_DE") or p.get("NAME"), p.get("NAME_EN") or p.get("NAME"), feature["geometry"])
        if index is not None:
            country_by_a3[p["ADM0_A3"]] = index
    skipped = 0
    dissolved = {}
    for feature in sorted(admin1["features"], key=lambda f: (f["properties"].get("adm0_a3") or "", f["properties"].get("adm1_code") or "")):
        p = feature["properties"]
        parent = country_by_a3.get(p.get("adm0_a3"))
        if parent is None:
            skipped += 1
            continue
        field = DISSOLVE_FIELD.get(p.get("adm0_a3"))
        if field and p.get(field):
            dissolved.setdefault((p["adm0_a3"], p[field]), (parent, []))[1].append(feature["geometry"])
            continue
        name = p.get("name") or ""
        iso = (p.get("iso_3166_2") or "").replace("~", "")
        if w.add_region(1, parent, iso, p.get("name_de") or name, p.get("name_en") or name, feature["geometry"]) is None:
            skipped += 1
    for (a3, region), (parent, geometries) in sorted(dissolved.items()):
        de, en = REGION_NAMES.get(region, (region, region))
        if w.add_region_parts(1, parent, "", de, en, geometries) is None:
            skipped += 1
    size = w.write(out_path)
    print(f"{len(country_by_a3)} countries, {len(w.regions) - len(country_by_a3)} regions, {len(w.rings)} rings, "
          f"{len(w.points)} points, {size / 1e6:.1f} MB (skipped {skipped})")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
