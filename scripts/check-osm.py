#!/usr/bin/env python3
"""OSM タイルの公開前の検査。主要都市のタイルの地物数を前回と比べ、地名が日本語で出ているかを見る。

    python3 scripts/check-osm.py <pmtiles> [前回の統計 JSON] > 今回の統計 JSON

- 統計（都市ごと・レイヤごとの地物数）を標準出力に 1 行の JSON で出す。build-osm.sh が R2 のメタデータ
  feature-stats に入れ、次回の比較に使う（直前の版の退避・ロールバックでも一緒に動く）
- 前回より CHECK_MAX_CHANGE %（既定 20）を超えて増減したレイヤがあれば、理由を標準エラーに出して終了コード 1
  （前回の地物数が CHECK_MIN_COUNT 未満のレイヤは揺れが大きいので見ない）
- 都市名（place レイヤーの name:ja）が期待どおりでなければ終了コード 1（名前を書き換える荒らしの検知）
- CHECK_CITIES（カンマ区切りのキー）で見る都市を絞れる。四国だけで作る試験では matsuyama にする
- 北方領土・竹島・尖閣諸島の範囲（style/territories.json）に名前の付いた地物があれば終了コード 1
  （build-osm.sh が消しているはずの名前が残っていないか。地名はスタイルで国土地理院の注記を重ねる）

タイルは pmtiles コマンドで取り出し、MVT は標準ライブラリだけで読む（Docker イメージとランナーの両方で動かすため）。
"""
import gzip
import json
import math
import os
import subprocess
import sys

# 比べるレイヤ（OpenMapTiles）
LAYERS = ["transportation", "building", "water", "landuse", "poi", "place"]
# (キー, 経度, 緯度, place の name:ja)。地物数は z14、地名は z10 のタイルで見る
CITIES = [
    ("sapporo", 141.3508, 43.0686, "札幌市"),
    ("sendai", 140.8720, 38.2601, "仙台市"),
    ("tokyo", 139.7671, 35.6812, "東京都"),
    ("nagoya", 136.8815, 35.1709, "名古屋市"),
    ("osaka", 135.4959, 34.7024, "大阪市"),
    ("hiroshima", 132.4553, 34.3963, "広島市"),
    ("matsuyama", 132.7656, 33.8392, "松山市"),
    ("fukuoka", 130.4207, 33.5897, "福岡市"),
    ("naha", 127.6792, 26.2124, "那覇市"),
]
STATS_VERSION = 1
TERRITORIES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "style", "territories.json")
# 範囲の検査で見るズーム。1 つの多角形でタイルがこの数を超えるズームは見ない（北方領土の z14 など）
TERRITORY_ZOOMS = [10, 12, 14]
TERRITORY_MAX_TILES = 400


def tile_xy(lon, lat, z):
    n = 2**z
    x = int((lon + 180) / 360 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return x, y


def get_tile(path, z, x, y):
    """タイルが無ければ空（地物 0 として扱い、都市名の検査で止まる）"""
    r = subprocess.run(["pmtiles", "tile", path, str(z), str(x), str(y)], capture_output=True)
    data = r.stdout if r.returncode == 0 else b""
    return gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data


# ---- protobuf（MVT に必要な分だけ）----
def varint(buf, i):
    v = shift = 0
    while True:
        b = buf[i]
        i += 1
        v |= (b & 0x7F) << shift
        if b < 0x80:
            return v, i
        shift += 7


def fields(buf):
    """(フィールド番号, 値) を順に返す。長さ付きの値は bytes、それ以外は int"""
    i = 0
    while i < len(buf):
        key, i = varint(buf, i)
        num, wt = key >> 3, key & 7
        if wt == 0:
            v, i = varint(buf, i)
        elif wt == 2:
            n, i = varint(buf, i)
            v, i = buf[i : i + n], i + n
        elif wt == 1:
            v, i = buf[i : i + 8], i + 8
        elif wt == 5:
            v, i = buf[i : i + 4], i + 4
        else:
            raise ValueError(f"未対応の wire type {wt}")
        yield num, v


def packed(buf):
    i, out = 0, []
    while i < len(buf):
        v, i = varint(buf, i)
        out.append(v)
    return out


def read_layers(tile):
    """{レイヤ名: (地物の bytes のリスト, keys, values)}"""
    layers = {}
    for num, raw in fields(tile):
        if num != 3:
            continue
        name, feats, keys, values = "", [], [], []
        for n, v in fields(raw):
            if n == 1:
                name = v.decode()
            elif n == 2:
                feats.append(v)
            elif n == 3:
                keys.append(v.decode())
            elif n == 4:
                # Value: 文字列（1）以外は数値として扱う
                val = None
                for vn, vv in fields(v):
                    val = vv.decode() if vn == 1 else vv
                values.append(val)
        layers[name] = (feats, keys, values)
    return layers


def feature_vertices(feat):
    """地物の頂点（タイル内座標、extent 4096）"""
    for n, v in fields(feat):
        if n != 4:
            continue
        geom, i, x, y, out = packed(v), 0, 0, 0, []
        while i < len(geom):
            cmd, count = geom[i] & 7, geom[i] >> 3
            i += 1
            if cmd == 7:
                continue
            for _ in range(count):
                x += (geom[i] >> 1) ^ -(geom[i] & 1)
                y += (geom[i + 1] >> 1) ^ -(geom[i + 1] & 1)
                i += 2
                out.append((x, y))
        return out
    return []


def tile_lonlat(z, x, y, px, py, extent=4096):
    n = 2**z
    lon = (x + px / extent) / n * 360 - 180
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y + py / extent) / n))))
    return lon, lat


def in_ring(lon, lat, ring):
    inside = False
    for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
        if (y1 > lat) != (y2 > lat) and lon < (x2 - x1) * (lat - y1) / (y2 - y1) + x1:
            inside = not inside
    return inside


def in_polygon(lon, lat, poly):
    return in_ring(lon, lat, poly[0]) and not any(in_ring(lon, lat, hole) for hole in poly[1:])


def check_territories(path):
    """範囲の中に頂点を持ち、名前の付いた地物を (ズーム, レイヤ, 名前) で返す"""
    with open(TERRITORIES, encoding="utf-8") as f:
        polygons = json.load(f)["geometry"]["coordinates"]
    found = set()
    for poly in polygons:
        lons = [p[0] for p in poly[0]]
        lats = [p[1] for p in poly[0]]
        for z in TERRITORY_ZOOMS:
            x0, y0 = tile_xy(min(lons), max(lats), z)
            x1, y1 = tile_xy(max(lons), min(lats), z)
            if (x1 - x0 + 1) * (y1 - y0 + 1) > TERRITORY_MAX_TILES:
                continue
            for x in range(x0, x1 + 1):
                for y in range(y0, y1 + 1):
                    for layer, (feats, keys, values) in read_layers(get_tile(path, z, x, y)).items():
                        for feat in feats:
                            tags = feature_tags(feat, keys, values)
                            name = next((v for k, v in tags.items() if k.startswith("name")), None)
                            if name is None:
                                continue
                            if any(in_polygon(*tile_lonlat(z, x, y, px, py), poly) for px, py in feature_vertices(feat)):
                                found.add((z, layer, str(name)))
    return sorted(found)


def feature_tags(feat, keys, values):
    for n, v in fields(feat):
        if n == 2:
            t = packed(v)
            return {keys[t[i]]: values[t[i + 1]] for i in range(0, len(t), 2)}
    return {}


def main():
    path = sys.argv[1]
    prev = json.loads(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
    max_change = float(os.environ.get("CHECK_MAX_CHANGE", "20"))
    min_count = int(os.environ.get("CHECK_MIN_COUNT", "50"))
    only = os.environ.get("CHECK_CITIES")
    cities = [c for c in CITIES if not only or c[0] in only.split(",")]
    problems = []
    stats = {"v": STATS_VERSION, "layers": LAYERS}

    for key, lon, lat, want_name in cities:
        layers = read_layers(get_tile(path, 14, *tile_xy(lon, lat, 14)))
        stats[key] = [len(layers.get(name, ([],))[0]) for name in LAYERS]

        feats, keys, values = read_layers(get_tile(path, 10, *tile_xy(lon, lat, 10))).get("place", ([], [], []))
        names = [t.get("name:ja") or t.get("name") for t in (feature_tags(f, keys, values) for f in feats)]
        if want_name not in names:
            problems.append(f"{key}: z10 の place に「{want_name}」が無い（{', '.join(map(str, names[:10]))}）")

    named = check_territories(path)
    if named:
        sample = ", ".join(f"z{z} {layer}「{name}」" for z, layer, name in named[:10])
        problems.append(f"北方領土・竹島・尖閣諸島の範囲に名前の付いた地物が {len(named)} 件ある（{sample}）")

    if prev and prev.get("v") == STATS_VERSION and prev.get("layers") == LAYERS:
        for key, *_ in cities:
            if key not in prev:
                continue
            for name, before, now in zip(LAYERS, prev[key], stats[key]):
                if before < min_count:
                    continue
                change = (now - before) / before * 100
                if abs(change) > max_change:
                    problems.append(f"{key}/{name}: {before} → {now}（{change:+.0f}%）")
    else:
        print("前回の統計が無い（または形式が違う）ので、地物数の比較は省く", file=sys.stderr)

    for key, *_ in cities:
        print(f"{key}: " + " ".join(f"{n}={c}" for n, c in zip(LAYERS, stats[key])), file=sys.stderr)
    print(json.dumps(stats, separators=(",", ":")))
    for p in problems:
        print(f"検査 NG: {p}", file=sys.stderr)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
