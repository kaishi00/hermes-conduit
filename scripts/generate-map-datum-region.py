#!/usr/bin/env python3
"""Writes Shared/Location/MapDatumRegion.swift: where Apple Maps draws in
GCJ-02 (mainland China) for MapDatum.isShifted (#1122).

Source: Natural Earth 1:10m countries as packaged by the world-atlas npm
package (public domain). Download and unpack it, then run:

  curl -sSLO https://registry.npmjs.org/world-atlas/-/world-atlas-2.0.2.tgz
  tar xzf world-atlas-2.0.2.tgz
  python3 scripts/generate-map-datum-region.py package/countries-10m.json

The mainland outline is China's land border (Vietnam round to North Korea,
simplified to about 2 km) closed by a hand-drawn line out at sea, so coast
and islands are inside without tracing the coastline. Taiwan, Penghu and
Pratas are outside that line. Hong Kong and Macau are cut out with their own
outlines (simplified to about 200 m) and their waters: Hong Kong's land
border closed by a hand-drawn line round its harbour and islands, and a
hand-drawn ring round Macau's harbours and the water between its islands.
Without them a point in Victoria Harbour, or a Hong Kong point's inverse
shift landing there, read as mainland (Nightly 2026-10-22). Kinmen and
Matsu, a few km off the mainland, are cut out with boxes in MapDatum.swift.
"""

import json
import math
import sys
from pathlib import Path

BORDER_TOLERANCE = 0.02  # degrees, about 2 km
SAR_TOLERANCE = 0.002    # degrees, about 200 m

# (longitude, latitude), from the Yalu mouth south past Korea, west of Taiwan
# and Penghu, round Hainan and up the Gulf of Tonkin to the Beilun mouth.
SEA = [
    (124.10, 39.85), (123.70, 39.40), (124.00, 37.00), (124.00, 33.00),
    (122.50, 28.00), (120.80, 26.60), (120.40, 25.30), (119.90, 24.40),
    (119.20, 24.00), (118.50, 23.20), (117.50, 22.60), (116.00, 22.20),
    (114.60, 21.90), (113.00, 21.60), (111.00, 20.80), (111.20, 19.50),
    (110.50, 17.80), (108.40, 18.00), (108.15, 21.20),
]

# Hong Kong's waters, (longitude, latitude), from Sha Tau Kok through Mirs
# Bay, round the islands to the south and Lantau to the west, then up Deep
# Bay to the Shenzhen River at Lo Wu, where its land border starts. No
# mainland vertex of the source lies inside.
HONG_KONG_SEA = [
    (114.30, 22.555), (114.42, 22.44), (114.50, 22.36), (114.50, 22.14),
    (113.90, 22.14), (113.83, 22.20), (113.83, 22.37), (113.90, 22.43),
    (113.95, 22.47), (114.00, 22.49), (114.04, 22.50), (114.07, 22.515),
]

# Macau's outer harbour and the water between the peninsula, Taipa and
# Coloane, kept east of Hengqin and south of the Gongbei border.
MACAU_WATERS = [
    (113.545, 22.205), (113.56, 22.205), (113.60, 22.20), (113.62, 22.14),
    (113.60, 22.10), (113.555, 22.10), (113.545, 22.13), (113.54, 22.17),
    (113.54, 22.19),
]


def simplify(points, tolerance):
    """Douglas-Peucker."""
    if len(points) < 3:
        return points
    (ax, ay), (bx, by) = points[0], points[-1]
    worst, index = 0.0, 0
    for i in range(1, len(points) - 1):
        px, py = points[i]
        dx, dy = bx - ax, by - ay
        if dx == 0 and dy == 0:
            distance = math.hypot(px - ax, py - ay)
        else:
            distance = abs(dy * px - dx * py + bx * ay - by * ax) / math.hypot(dx, dy)
        if distance > worst:
            worst, index = distance, i
    if worst > tolerance:
        return simplify(points[:index + 1], tolerance)[:-1] + simplify(points[index:], tolerance)
    return [points[0], points[-1]]


def main(path):
    data = json.loads(Path(path).read_text())
    sx, sy = data["transform"]["scale"]
    tx, ty = data["transform"]["translate"]
    arcs = []
    for arc in data["arcs"]:
        x = y = 0
        points = []
        for dx, dy in arc:
            x += dx
            y += dy
            points.append((x * sx + tx, y * sy + ty))
        arcs.append(points)

    def arc_points(index):
        return arcs[index] if index >= 0 else arcs[~index][::-1]

    def ring(indices):
        points = []
        for index in indices:
            part = arc_points(index)
            points.extend(part if not points else part[1:])
        return points

    geometries = data["objects"]["countries"]["geometries"]
    owners = {}
    for geometry in geometries:
        polygons = geometry["arcs"] if geometry["type"] == "MultiPolygon" else [geometry["arcs"]]
        for polygon in polygons:
            for rings in polygon:
                for index in rings:
                    owners.setdefault(index if index >= 0 else ~index, set()).add(geometry["properties"]["name"])

    def country(name):
        geometry = next(g for g in geometries if g["properties"]["name"] == name)
        return geometry["arcs"] if geometry["type"] == "MultiPolygon" else [geometry["arcs"]]

    # The mainland's outer ring; its arcs shared with a neighbour are the land border.
    mainland = max((polygon[0] for polygon in country("China")),
                   key=lambda r: sum(len(arcs[i if i >= 0 else ~i]) for i in r))
    shared = [bool(owners[i if i >= 0 else ~i] - {"China"}) for i in mainland]
    start = next(i for i, index in enumerate(mainland)
                 if "Vietnam" in owners[index if index >= 0 else ~index] and not shared[i - 1])
    border = []
    for offset in range(len(mainland)):
        i = (start + offset) % len(mainland)
        if not shared[i]:
            break
        border.append(mainland[i])
    outline = simplify(ring(border), BORDER_TOLERANCE) + SEA

    sars = [simplify(ring(polygon[0]), SAR_TOLERANCE)
            for name in ("Hong Kong", "Macao") for polygon in country(name)]
    # Hong Kong's land border, Lo Wu to Sha Tau Kok, closed through its waters.
    hong_kong_border = next(
        arc_points(index)
        for polygon in country("Hong Kong") for index in polygon[0]
        if "China" in owners[index if index >= 0 else ~index])
    if hong_kong_border[0][0] > hong_kong_border[-1][0]:
        hong_kong_border = hong_kong_border[::-1]
    sars.append(simplify(hong_kong_border, SAR_TOLERANCE) + HONG_KONG_SEA)
    sars.append(MACAU_WATERS)

    def encode(points, digits):
        pairs = [f"{lon:.{digits}f},{lat:.{digits}f}" for lon, lat in points]
        lines = [" ".join(pairs[i:i + 8]) for i in range(0, len(pairs), 8)]
        return "\n".join("        " + line for line in lines)

    sar_literals = ",\n".join(f'        """\n{encode(r, 4)}\n        """' for r in sars)
    swift = f'''//
//  MapDatumRegion.swift
//  Conduit
//
//  Generated by scripts/generate-map-datum-region.py from Natural Earth
//  1:10m countries; don't edit by hand. Where Apple Maps draws in GCJ-02:
//  mainland China's land border closed by a line out at sea, and Hong Kong
//  and Macau with their waters, which it doesn't shift. "longitude,latitude"
//  pairs.
//

enum MapDatumRegion {{
    static let mainland = """
{encode(outline, 3)}
        """

    static let excluded = [
{sar_literals},
    ]
}}
'''
    target = Path(__file__).resolve().parent.parent / "Shared/Location/MapDatumRegion.swift"
    target.write_text(swift)
    print(f"{target}: mainland {len(outline)} points, Hong Kong and Macau {[len(r) for r in sars]}")


if __name__ == "__main__":
    main(sys.argv[1])
