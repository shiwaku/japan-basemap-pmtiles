"""北方領土・竹島・尖閣諸島で国土地理院の注記を出す範囲（style/territories.json）を作る。
scripts/build-osm.sh は、この範囲にある OSM の地物の名前を消す。

国土地理院の注記は島から離れた位置に置かれることがある（竹島の「竹島」は島の約 500m 南）ので、
島の海岸線から 10km まで広げる。北方領土は北海道に近い（貝殻島と納沙布岬は約 3.7km）ので、
北海道の海岸線との中間線で切り、北海道側の注記（とそれと重なる OSM の地名）が入らないようにする。

入力は OSM の海岸線（natural=coastline）の GeoJSON Seq。scripts/build-osm.sh が作る
data/sources/extra-*.clip.osm.pbf と japan.osm.pbf（ローカルでは work/osm/data/sources/）から、
次のように書き出す（compose のコンテナ内。書き出し先は work/territories/ にする）:

  osmium tags-filter extra-0.clip.osm.pbf w/natural=coastline -o coast-0.osm.pbf
  osmium export coast-0.osm.pbf -f geojsonseq -o coast-0.geojsonseq          # 北方領土（1 は竹島）
  osmium extract -b 123.3,25.6,124.7,26.0 japan.osm.pbf -o sk.osm.pbf
  osmium tags-filter sk.osm.pbf w/natural=coastline -o coast-2.osm.pbf
  osmium export coast-2.osm.pbf -f geojsonseq -o coast-2.geojsonseq          # 尖閣諸島（japan に入っている）
  osmium extract -b 144.8,43.0,145.9,44.5 japan.osm.pbf -o hk.osm.pbf
  osmium tags-filter hk.osm.pbf w/natural=coastline -o hkc.osm.pbf
  osmium export hkc.osm.pbf -f geojsonseq -o hokkaido-coast.geojsonseq      # 根室・知床付近の北海道

  python make_territories.py <coast-0> <coast-1> <coast-2> <hokkaido-coast> ../territories.json

japan.osm.pbf の代わりに asia/japan/kyushu-latest.osm.pbf（沖縄を含む）からでも尖閣諸島は取れる。

shapely 2 が要る。
"""

import json
import math
import sys

import numpy as np
from shapely import MultiPoint, transform, voronoi_polygons
from shapely.geometry import LineString, MultiPolygon, Polygon, box, mapping, shape
from shapely.ops import unary_union

BUFFER_KM = 10.0
NORTHERN_BBOX = (145.2, 43.2, 149.0, 45.65)  # scripts/build-osm.sh の EXTRA_SOURCES と同じ
TAKESHIMA_BBOX = (131.8, 37.2, 131.95, 37.3)
SENKAKU_BBOX = (123.3, 25.6, 124.7, 26.0)
LAT0 = 44.0
KX = 111.32 * math.cos(math.radians(LAT0))  # 経度 1 度の km（北緯 44 度）
KY = 110.57


def to_km(coords):
    return coords * np.array([KX, KY])


def to_deg(coords):
    return coords / np.array([KX, KY])


# 尖閣諸島は北緯 26 度付近で、北緯 44 度の換算だと東西に 25% 広がる。その緯度で換算してから
# 北緯 44 度の km 座標に移し、ほかの範囲と同じ to_deg で戻す
KX_SENKAKU = 111.32 * math.cos(math.radians(25.8))


def senkaku_to_km(coords):
    return coords * np.array([KX_SENKAKU, KY])


def senkaku_km_to_common(coords):
    return coords / np.array([KX_SENKAKU, KY]) * np.array([KX, KY])


def coast_lines(path, bbox, to_km=to_km):
    """海岸線を bbox で切った線の集まり（km 座標）"""
    clip = box(*bbox)
    lines = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip().lstrip("\x1e")
            if not line:
                continue
            geom = shape(json.loads(line)["geometry"]).intersection(clip)
            if not geom.is_empty:
                lines.append(transform(geom, to_km))
    return unary_union(lines)


def vertices(geom, step_km=0.3):
    """線を step_km ごとに区切った点（ボロノイ分割用）"""
    pts = []
    for g in getattr(geom, "geoms", [geom]):
        if isinstance(g, LineString):
            n = max(1, int(g.length / step_km))
            pts += [g.interpolate(i / n, normalized=True) for i in range(n + 1)]
        elif isinstance(g, Polygon):
            pts += vertices(g.exterior, step_km)
    return pts


def main(coast_nt, coast_tk, coast_sk, coast_hk, out):
    nt = coast_lines(coast_nt, NORTHERN_BBOX)
    hk = coast_lines(coast_hk, (140, 40, 150, 46))
    tk = coast_lines(coast_tk, TAKESHIMA_BBOX)

    # 北方領土: 海岸線から 10km の範囲のうち、北海道より北方領土の海岸線に近い側（中間線で切る）
    nt_pts = vertices(nt)
    hk_pts = vertices(hk)
    cells = voronoi_polygons(MultiPoint(nt_pts + hk_pts), extend_to=nt.buffer(50))
    nt_set = MultiPoint(nt_pts)
    nt_side = unary_union([c for c in cells.geoms if c.intersects(nt_set) and not c.intersects(MultiPoint(hk_pts))])
    northern = nt.buffer(BUFFER_KM).intersection(nt_side).buffer(0)
    # 細かい凹凸を落としてファイルを小さくする（200m）
    northern = northern.simplify(0.2)

    takeshima = tk.buffer(BUFFER_KM).simplify(0.2)

    sk = coast_lines(coast_sk, SENKAKU_BBOX, senkaku_to_km)
    senkaku = transform(sk.buffer(BUFFER_KM).simplify(0.2), senkaku_km_to_common)

    # 確認: 北海道の海岸線が入っていないこと
    inside = [p for p in hk_pts if northern.contains(p)]
    if inside:
        sys.exit(f"北海道の海岸線が {len(inside)} 点入っている")
    margin = min(northern.exterior.distance(p) if isinstance(northern, Polygon) else northern.boundary.distance(p) for p in hk_pts)
    print(f"北海道の海岸線から境界まで最短 {margin:.2f} km")

    polys = []
    for g in (northern, takeshima, senkaku):
        polys += list(getattr(g, "geoms", [g]))
    result = transform(MultiPolygon(polys), to_deg)
    coords = mapping(result)["coordinates"]
    rounded = [[[[round(x, 4), round(y, 4)] for x, y in ring] for ring in poly] for poly in coords]
    feature = {
        "type": "Feature",
        "properties": {
            "description": "北方領土（色丹島・歯舞群島・国後島・択捉島）・竹島・尖閣諸島で、国土地理院の注記を出す範囲。"
            "scripts/build-osm.sh はこの範囲の OSM の名前を消す。"
            f"OSM の海岸線から {BUFFER_KM:g}km まで。北方領土は北海道の海岸線との中間線で切ってある。"
            "style/tools/make_territories.py で作る",
        },
        "geometry": {"type": "MultiPolygon", "coordinates": rounded},
    }
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(feature, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"{out}: {len(rounded)} 多角形、{sum(len(r) for p in rounded for r in p)} 頂点")


if __name__ == "__main__":
    main(*sys.argv[1:6])
