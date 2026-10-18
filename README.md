# japan-basemap-tile-pipeline

日本域の背景地図タイル（OSM のベクトルタイル・国土地理院 最適化ベクトルタイル・Mapterhorn の標高タイル）を
GitHub Actions で定期的に更新し、Cloudflare R2 から PMTiles と ZXY で配信する。

- 表示の確認: <https://shiwaku.github.io/japan-basemap-tile-pipeline/>
- 仕組み: [docs/design.md](docs/design.md)
- 運用・セットアップ・試験: [docs/operations.md](docs/operations.md)

| データ | 中身 | 更新 |
|---|---|---|
| OSM | OpenMapTiles スキーマ、z0–14。Geofabrik の日本＋北方領土・竹島から Planetiler で生成 | 毎週月曜 03:00 JST |
| 国土地理院 最適化ベクトルタイル | z4–16。配信元の `optimal_bvmap-v1.pmtiles` の写し | 毎月 2 日・16 日 03:00 JST に確認（配信元の更新は四半期ごと） |
| [Mapterhorn](https://github.com/mapterhorn/mapterhorn) 標高タイル | Terrarium・512px・WebP、z0–16。日本域の写し | 毎週木曜 03:00 JST に確認 |

## 配信 URL

同じキーに上書きするので URL は変わらない。

| データ | PMTiles（`pmtiles://`） | ZXY |
|---|---|---|
| OSM | `https://shi-works.com/pmtiles/osm/openmaptiles-japan.pmtiles` | `https://tiles.shi-works.com/osm/openmaptiles-japan/{z}/{x}/{y}.pbf` |
| 国土地理院 | `https://shi-works.com/pmtiles/gsi/optimal_bvmap/optimal_bvmap-v1.pmtiles` | `https://tiles.shi-works.com/gsi/optimal_bvmap/optimal_bvmap-v1/{z}/{x}/{y}.pbf` |
| Mapterhorn | `https://shi-works.com/pmtiles/mapterhorn/planet-japan.pmtiles`（z0–12）＋ `…/mapterhorn/6-{x}-{y}.pmtiles`（z13+） | `https://mapterhorn.shi-works.com/{z}/{x}/{y}.webp` |

OSM・国土地理院の TileJSON は `/{z}/{x}/{y}.pbf` を `.json` に替えた URL。
Mapterhorn の TileJSON は `https://mapterhorn.shi-works.com/tilejson.json`。

### OSM・国土地理院

```js
// MapLibre GL JS
{ type: 'vector', url: 'pmtiles://https://shi-works.com/pmtiles/osm/openmaptiles-japan.pmtiles' }
// または
{ type: 'vector', url: 'https://tiles.shi-works.com/osm/openmaptiles-japan.json' }
```

`pmtiles://` を使うときは、表示側で [pmtiles](https://github.com/protomaps/PMTiles) のプロトコルを登録する。

OpenMapTiles スキーマなので、OSM Bright・Positron・Dark Matter などの OpenMapTiles 系スタイルの
`sources.openmaptiles` をこの URL に差し替えれば使える（glyphs・sprite は別途用意する）。
北方領土・竹島の地名まで日本の地名で出すには、このリポジトリの [スタイル](#スタイル) を使う。

### Mapterhorn

本家の `tiles.mapterhorn.com` とホスト名だけが違う。URL の形（`/{z}/{x}/{y}.webp`・`/tilejson.json`）と
TileJSON の項目を本家に合わせてある。日本の外は 404。

```js
{ type: 'raster-dem', tiles: ['https://mapterhorn.shi-works.com/{z}/{x}/{y}.webp'], encoding: 'terrarium', tileSize: 512, maxzoom: 16 }
// または
{ type: 'raster-dem', url: 'https://mapterhorn.shi-works.com/tilejson.json' }
```

本家のビューアに TileJSON を渡しても確認できる:
<https://mapterhorn.com/viewer/#url=https://mapterhorn.shi-works.com/tilejson.json>

PMTiles で直接読むときは、z12 以下を `planet-japan`、z13 以上をそのタイルを含む z6 タイルの `6-x-y` から読む
（本家の [PMTiles の例](https://github.com/mapterhorn/mapterhorn/tree/main/website/examples/pmtiles)と同じ。このリポジトリのビューアの `style/src/main.ts` も参考になる）。

## 領土の表示（北方領土・竹島）

OSM タイルには北方領土・竹島の道路・建物などの地物が入っている。ただし、その地域の名前（ロシア語・韓国語）は消してあり、隣国の航路も除いてある。
このリポジトリのスタイルを使うと、次の 2 点が加わる。

- 北方領土・竹島に国土地理院の注記（日本の地名）を重ねる
- 国境線を国土地理院の「国の所属界」で描く（z4–7）

ほかの OpenMapTiles 系スタイルで表示すると、北方領土・竹島の地名は出ない。詳しくは [docs/design.md](docs/design.md#領土の表示北方領土竹島)。

## スタイル

OpenFreeMap の [Bright](https://openfreemap.org/)（OSM Bright 系）をもとに、このリポジトリのタイル向けに直したもの。
タイルの参照先だけが違う 2 本を GitHub Pages で配る（main にマージされると更新される）。

| スタイル | タイルの参照先 | URL |
|---|---|---|
| PMTiles 版 | R2 の PMTiles（`pmtiles://`）。表示側で pmtiles のプロトコルを登録する | `https://shiwaku.github.io/japan-basemap-tile-pipeline/openmaptiles-japan.json` |
| ZXY 版 | `tiles.shi-works.com` の TileJSON。そのまま使える | `https://shiwaku.github.io/japan-basemap-tile-pipeline/openmaptiles-japan-zxy.json` |

```js
// ZXY 版
new maplibregl.Map({ container: 'map', style: 'https://shiwaku.github.io/japan-basemap-tile-pipeline/openmaptiles-japan-zxy.json' });

// PMTiles 版
import { Protocol } from 'pmtiles';
maplibregl.addProtocol('pmtiles', new Protocol().tile);
new maplibregl.Map({ container: 'map', style: 'https://shiwaku.github.io/japan-basemap-tile-pipeline/openmaptiles-japan.json' });
```

- 地名・道路名は日本語名（`name:ja`）→ `name` の順
- 北方領土・竹島の表示は上記のとおり
- フォント・アイコンは OpenFreeMap のものを参照する

```bash
cd style
pnpm install
pnpm build        # openmaptiles-japan.json・openmaptiles-japan-zxy.json を作り直す（手で編集しない）
pnpm dev          # ビューア http://localhost:5173/ 。?local を付けると ../work/osm/openmaptiles-japan.pmtiles を表示
```

## ビューア

<https://shiwaku.github.io/japan-basemap-tile-pipeline/>

R2 のタイルを重ねて見るページ。タイルはどれも R2 の PMTiles をブラウザから直接読む。

- 背景地図を OSM（このリポジトリのスタイル）と国土地理院（配信元の標準地図スタイル）で切り替える
- Mapterhorn の陰影と 3D 地形を重ねる
- 状態は URL に残る: `?base=osm|gsi`、`&hillshade=0`（陰影なし）、`&terrain=1`（3D）、`#map=ズーム/緯度/経度/方位/傾き`

## 出典・ライセンス

- OSM 由来のタイル: © OpenStreetMap contributors（[ODbL](https://www.openstreetmap.org/copyright)）。
  スキーマは © OpenMapTiles（[CC-BY 4.0](https://github.com/openmaptiles/openmaptiles/blob/master/LICENSE.md)）。
  地図には「© OpenMapTiles © OpenStreetMap contributors」を表示すること。
- スタイル（`style/`）: OpenFreeMap の Bright（[openfreemap-styles](https://github.com/hyperknot/openfreemap-styles)、MIT）をもとにしている。
  元は OpenMapTiles の OSM Bright（コードは BSD-3-Clause、デザインは CC-BY 4.0）。フォントは Noto Sans（OFL 1.1）、アイコンは Maki（CC0）。
- 国土地理院 最適化ベクトルタイル: [国土地理院コンテンツ利用規約](https://www.gsi.go.jp/kikakuchousei/kikakuchousei40182.html)に従う。
  「国土地理院最適化ベクトルタイル」と出典を表示すること。試験公開のため、仕様・URL は変わることがある
  （[gsi-cyberjapan/optimal_bvmap](https://github.com/gsi-cyberjapan/optimal_bvmap)）。
- Mapterhorn: 出典は [mapterhorn.com/attribution](https://mapterhorn.com/attribution) に従って表示すること。
  日本域は国土地理院 基盤地図情報（数値標高モデル）由来で、「測量法に基づく国土地理院長承認（使用）R 8JHs 131」の表示を含む。
  コードは BSD-3-Clause。
- このリポジトリのコード: MIT
