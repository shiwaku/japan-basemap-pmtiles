# japan-basemap-tile-pipeline

日本域の背景地図タイル（OSM のベクトルタイル・国土地理院 最適化ベクトルタイル・Mapterhorn の標高タイル）を
GitHub Actions で週1回更新し、Cloudflare R2 から PMTiles と ZXY で配信する。

| データ | 元 | 生成 | 更新 |
|---|---|---|---|
| OSM（OpenMapTiles スキーマ、z0–14） | Geofabrik `asia/japan-latest.osm.pbf` ＋ 北方領土・竹島（隣国の抽出から切り出し） | osmium で結合 → Planetiler 0.10.2 | 毎週月曜 03:00 JST に生成 |
| 国土地理院 最適化ベクトルタイル（z4–16） | `optimal_bvmap-v1.pmtiles` | そのままミラー | 毎週水曜 03:00 JST に確認し、配信元の ETag が変わったときだけ取り直す |
| [Mapterhorn](https://github.com/mapterhorn/mapterhorn) 標高タイル（Terrarium・512px・WebP、z0–16） | `download.mapterhorn.com` | z0–12 は `planet.pmtiles` から日本を切り出し、z13+ は日本域の `6-x-y.pmtiles` をそのままミラー | 毎週木曜 03:00 JST に確認し、md5 が変わったファイルだけ取り直す |

## 配信 URL

R2 バケット `shi-works` のキー設計（第1階層＝アクセス方法）に従い `pmtiles/` 配下に置く。
同じキーに上書きするので URL は変わらない。

| データ | PMTiles（`pmtiles://`） | ZXY（Worker `dem2tiles-tiles`） |
|---|---|---|
| OSM | `https://shi-works.com/pmtiles/osm/openmaptiles-japan.pmtiles` | `https://tiles.shi-works.com/osm/openmaptiles-japan/{z}/{x}/{y}.pbf` |
| 国土地理院 | `https://shi-works.com/pmtiles/gsi/optimal_bvmap/optimal_bvmap-v1.pmtiles` | `https://tiles.shi-works.com/gsi/optimal_bvmap/optimal_bvmap-v1/{z}/{x}/{y}.pbf` |

| Mapterhorn | `https://shi-works.com/pmtiles/mapterhorn/planet-japan.pmtiles`（z0–12）＋ `…/mapterhorn/6-{x}-{y}.pmtiles`（z13+） | `https://tiles.shi-works.com/mapterhorn/{z}/{x}/{y}.webp` |

TileJSON は ZXY の `/{z}/{x}/{y}.pbf` を `.json` に替えた URL。

```js
// MapLibre GL JS
{ type: 'vector', url: 'pmtiles://https://shi-works.com/pmtiles/osm/openmaptiles-japan.pmtiles' }
// または
{ type: 'vector', url: 'https://tiles.shi-works.com/osm/openmaptiles-japan.json' }
```

Mapterhorn は `tiles.mapterhorn.com` と同じ使い方になる（ズームによるアーカイブの振り分けは Worker が行う。
[dem2tiles の worker](https://github.com/shiwaku/dem2tiles/tree/main/worker)）。日本の外は 404。

```js
{ type: 'raster-dem', tiles: ['https://tiles.shi-works.com/mapterhorn/{z}/{x}/{y}.webp'], encoding: 'terrarium', tileSize: 512, maxzoom: 16 }
```

OpenMapTiles スキーマなので、OSM Bright・Positron・Dark Matter などの OpenMapTiles 系スタイルの
`sources.openmaptiles` をこの URL に差し替えれば使える（glyphs・sprite は別途用意する）。
北方領土・竹島の地名まで日本の地名で出すには、このリポジトリの [スタイル](#スタイルstyle) を使う。

## 領土の表示（北方領土・竹島）

OSM は実効支配に基づいて国を分ける（On the Ground 原則）。Geofabrik の `japan` には北方領土（ロシア側）と
竹島（韓国側）が入っていないため、`russia/far-eastern-fed-district` と `asia/south-korea` から
その範囲だけを切り出して結合している（`scripts/build-osm.sh` の `EXTRA_SOURCES`）。
これで道路・建物・地名などの地物はタイルに入る。

切り出しは範囲にかかる way を範囲の外まで丸ごと残すので、そのままだと竹島〜鬱陵島、北方領土〜サハリン（コルサコフ）、
色丹島〜国後島といった隣国が運航する航路も入る。補った地域からは航路（`route=ferry`）を除いている（`build-osm.sh` の `drop_ferries`）。

**地名は国土地理院の注記を使う。** OSM の名前は、北方領土はロシア語、竹島は韓国語や韓国の行政名（「독도리」／`name:ja`「独島里」）で、
`name:ja` も日本の地名とは限らない（例: 国後島の中心集落が「古釜布」ではなく「ユジノ・クリリスク」）。そこで

1. **タイル生成時**に、補った地域の名前（`name`・`name:*`・`alt_name` など。地名・道路名・店名）を消す（`build-osm.sh` の `strip_names`）。
   どの OpenMapTiles 系スタイルで表示しても、ロシア語・韓国語の地名は出ない
2. **スタイル**（`style/openmaptiles-japan.json`）で、北方領土・竹島の範囲（`style/territories.json`）にだけ
   国土地理院 最適化ベクトルタイルの注記（`Anno` レイヤー）を重ねる。範囲は島の海岸線から 10km、北方領土は北海道の海岸線との中間線で切ってある

**国境線は国土地理院の「国の所属界」を使う。** タイルには根室海峡などの日露の線が `admin_level=2`・`maritime=1`・
`adm0_l=RUS`／`adm0_r=JPN`・`disputed=0`（係争扱いになっていない）で入っている。ただし Bright は海上の線（`maritime=1`）を描かないので、
日本周辺でスタイルに出る OSM の線は、z0–4（Natural Earth 由来）の北方領土の係争線（`disputed=1`、根室海峡〜国後水道）だけになる。そこで

1. その係争線を消す（`boundary_disputed` に、北方領土周辺の範囲に収まる線を除く条件を足す）
2. 国土地理院 最適化ベクトルタイルの「国の所属界」（`AdmBdry`・`vt_code=1221`）を z4–7 に重ねる（`gsi_boundary_country`、見た目は `boundary_2` と同じ）。
   択捉島と得撫島の間、竹島と鬱陵島の間、対馬海峡、宗谷海峡、与那国島と台湾の間などに引かれ、根室海峡には無い。
   国土地理院のデータは z8 以上にこの線を持たない（標準地図も z8 以上では描かない）ので、z8 以上ではどちらの線も出ない

国名ラベルは「日本」だけが入っていて、北方領土付近に「ロシア」は出ない。

## スタイル（style/）

OpenFreeMap の [Bright](https://openfreemap.org/)（OSM Bright 系）をもとに、このリポジトリのタイル向けに直したもの。
フォント・アイコンは OpenFreeMap のものを参照する。

- タイルの参照先を R2 の PMTiles（`pmtiles://`）にする。表示側で [pmtiles](https://github.com/protomaps/PMTiles) のプロトコルを登録する
- 地名・道路名は日本語名（`name:ja`）→ `name` の順
- 北方領土・竹島に国土地理院の注記を重ねる（上記）
- 北方領土の係争線を消し、国土地理院の「国の所属界」を重ねる（上記）

`vendor/openfreemap-bright.json` を `build-style.ts` で書き換えて `openmaptiles-japan.json` を作る。手で編集しない。

```bash
cd style
pnpm install
pnpm build        # openmaptiles-japan.json を作り直す（CI は pnpm check で差分が無いことを確かめる）
pnpm dev          # 確認用ビューア http://localhost:5173/ 。?local を付けると ../work/osm/openmaptiles-japan.pmtiles を表示
```

`territories.json` は `tools/make_territories.py`（shapely）で OSM の海岸線から作る（手順はスクリプトの先頭）。

## 仕組み

```
GitHub Actions（週1）
  ├─ osm-openmaptiles.yml
  │    Geofabrik の Last-Modified（japan と補う地域）と Planetiler のバージョンを R2 のメタデータと比較
  │    → 変わっていれば pbf 取得 → 補う地域を切り出して結合 → Planetiler → pmtiles show で検査 → R2 に上書き → キャッシュをパージ
  └─ gsi-optimal-bvmap.yml
       配信元の ETag を R2 のメタデータと比較
       → 変わっていれば取得 → サイズ・ETag 再確認 → pmtiles show で検査 → R2 に上書き → キャッシュをパージ

Cloudflare
  ├─ shi-works.com        R2 カスタムドメイン（Range リクエストで pmtiles:// を読む）
  └─ tiles.shi-works.com  Worker dem2tiles-tiles（PMTiles → ZXY、Cache API）
```

- **差し替えは同じキーへの上書き。** マルチパートアップロードは完了時に一括で差し替わるので、
  書き込み途中の状態は読まれない。Worker はアーカイブの ETag が変わると読み直す
  （`EtagMismatch`）。その後 `shi-works.com/<key>` と `tiles.shi-works.com/<name>` を prefix でパージする。
- **壊れた成果物を上げない。** 前回の 70% 未満のサイズなら止まる（`force` で解除）。
  タイル形式が MVT でない場合も止まる。
- **作業はランナーの `/mnt`。** `/` は空きが少ない。OSM は約 30GB、国土地理院は約 22GB を要求する。
- 元データの情報は R2 オブジェクトのメタデータ（`x-amz-meta-source-*`、`planetiler-version`）に残る。

```bash
aws s3api head-object --bucket shi-works --key pmtiles/osm/openmaptiles-japan.pmtiles \
  --endpoint-url https://<account>.r2.cloudflarestorage.com --query Metadata
```

### Mapterhorn

上流は z0–12 の `planet.pmtiles`（全球 356GB）と、z13 以上を z6 タイル単位に分けた `6-{x}-{y}.pmtiles` で配られている
（[distribution](https://github.com/mapterhorn/mapterhorn/tree/main/distribution)）。日本域は 2026-10 時点で
サブピラミッド 22 本・251.8GB、planet の切り出しは 2.7GB。

- `plan` ジョブが `download_urls.json` の md5 と R2 のメタデータ `source-md5` を比べ、変わったファイルだけ `mirror` に回す
- サブピラミッドは最大 66GB でランナーのディスクに載らないため、**R2 の一時キー `_staging/…` へストリームで流し込み**、
  md5・サイズが上流と一致したら本番キーへ R2 内でコピーする。壊れた写しで本番を上書きしない
- 1 ファイル 1 ジョブ（同時 4 本）。最後に `tiles.shi-works.com/mapterhorn` をパージする
- ファイル名は上流と同じにしてあるので、後から[公式ミラー](https://github.com/mapterhorn/mapterhorn/blob/main/distribution/mirrors.json)に登録できる

手動実行は Actions の各ワークフローから `Run workflow`（`force` で強制再生成）。

## セットアップ

GitHub の Environment **`prod`** に登録する。

| 種類 | 名前 | 内容 |
|---|---|---|
| Variable | `R2_ACCOUNT_ID` | Cloudflare のアカウント ID |
| Variable | `CLOUDFLARE_ZONE_ID` | `shi-works.com` のゾーン ID |
| Secret | `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | R2 API トークン（バケット `shi-works` に限定、Object Read & Write） |
| Secret | `CLOUDFLARE_API_TOKEN` | `shi-works.com` ゾーンの **Cache Purge** 権限だけを持つ API トークン |

```bash
gh variable set R2_ACCOUNT_ID --env prod --body <account_id>
gh variable set CLOUDFLARE_ZONE_ID --env prod --body <zone_id>
gh secret set R2_ACCESS_KEY_ID --env prod
gh secret set R2_SECRET_ACCESS_KEY --env prod
gh secret set CLOUDFLARE_API_TOKEN --env prod
```

`CLOUDFLARE_API_TOKEN` が無い場合はパージを省略する（タイルは Worker のキャッシュ期限 1 日で入れ替わる）。

## ローカルで試す

スクリプトを変えたら、本番の前に **① ローカル → ② R2 の試験領域** の順に通す。Docker（compose）で動く。

```bash
docker compose build

# ① ローカルの S3 互換サーバー（versitygw）に書く。手順の誤りを見つける
docker compose run --rm pipeline scripts/test.sh local

# ② 本物の R2 の _test/ 以下に書き、最後に消す（失敗しても消す）。R2 固有の未実装 API を見つける
#    .env に R2_ACCOUNT_ID・AWS_ACCESS_KEY_ID・AWS_SECRET_ACCESS_KEY を置く（.gitignore 済み）
docker compose run --rm pipeline scripts/test.sh r2

docker compose down -v   # ① のローカル S3 を消す
```

どちらも 1〜2 分。国土地理院は小さい試験用 PMTiles（`./work/testsrc` を nginx で配信）を、Mapterhorn は竹島付近の
`planet-japan` と小さいバンドル 2 本を写し、サイズ・メタデータ・`_staging` の後始末・2 回目のスキップを確かめる。
`WITH_OSM=true` で OSM（四国、約 10 分）も加わる。パージはしない。

① だけでは足りない。versitygw は R2 が実装していない API（`x-amz-tagging-directive` など）も受け付けるので、
R2 内コピーの不具合は ② でしか出ない（2026-10 の初回本番で小さいバンドルが失敗したのはこれ）。

タイル生成だけを見るなら、書き込まない `DRY_RUN`（compose の既定）で個別のスクリプトを動かせる。

```bash
docker compose run --rm -e PBF_URL=https://download.geofabrik.de/asia/japan/shikoku-latest.osm.pbf \
  -e OSM_BOUNDS=132.0,32.7,134.8,34.6 -e EXTRA_SOURCES= pipeline scripts/build-osm.sh
```

`./work`（.gitignore 済み）の置き方。スクリプトはそれぞれ自分のディレクトリの中だけに書く。

| 場所 | 中身 | 消してよいか |
|---|---|---|
| `work/osm/` | `build-osm.sh` の作業場所。`openmaptiles-japan.pmtiles`（ビューアの `?local` が読む）、`planetiler.jar`、`data/sources/`（Natural Earth・水域ポリゴンのキャッシュと pbf） | pbf（`*.osm.pbf`）は毎回取り直すので消してよい。zip は消すと次回取り直す（約 1.4GB） |
| `work/gsi/` | `mirror-gsi.sh` の作業場所 | よい |
| `work/mapterhorn/` | `mapterhorn-plan.sh`・`mirror-mapterhorn.sh` の作業場所 | よい |
| `work/test-local/`・`work/test-r2/` | `test.sh` の作業場所。実行のたびに消して作り直す | よい |
| `work/testsrc/` | `test.sh` が使う試験用の国土地理院 PMTiles（compose の testsrc が配信）。無ければ作る | よい（次回作り直す） |
| `work/territories/` | `style/tools/make_territories.py` の入力（OSM の海岸線） | よい（手順はスクリプトの先頭） |
| `work/logs/` | 手で残すログ（`… 2>&1 \| tee work/logs/osm-japan.log` など） | よい |

## コストの目安

| 項目 | 目安 |
|---|---|
| R2 ストレージ | 約 275GB（Mapterhorn 254.5GB + 国土地理院 16.9GB + OSM 数GB）× $0.015/GB・月 ≒ **$4.1/月**（Mapterhorn 分が約 $3.8） |
| R2 書き込み（Class A） | 1 回のアップロードで 300 パート程度。無料枠（100 万/月）に収まる |
| R2 読み出し（Class B） | 未キャッシュのタイル 1 枚あたり 1〜2 回。1,000 万/月まで無料、超過は $0.36/100 万 |
| 転送量 | R2 は無料 |
| Workers | ZXY 経由のみ。無料プランは 10 万リクエスト/日、有料は $5/月で 1,000 万込み |
| GitHub Actions | public リポジトリの標準ランナーは無料 |

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
