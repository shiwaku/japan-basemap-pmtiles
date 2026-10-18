# 設計

タイルを更新して公開するまでの仕組み。使い方は [README](../README.md)、運用の手順は [operations.md](operations.md)。

## 全体構成

3 つとも「タイル化」と呼んでいるが、自分でタイルを作るのは OSM だけで、国土地理院と Mapterhorn は配信元の完成品を写すミラーである。
どれも最後は R2 に PMTiles を 1 本ずつ置いて終わり、そこから先の配信は共通。

| データ | やっていること | 処理 |
|---|---|---|
| OSM | 生データ（.osm.pbf）から**タイルを作る** | `osm-openmaptiles.yml`・`scripts/build-osm.sh` |
| 国土地理院 | 配信元の PMTiles を**そのまま写す** | `gsi-optimal-bvmap.yml`・`scripts/mirror-gsi.sh` |
| Mapterhorn | 配信元の PMTiles を**写す**（z12 以下だけ日本の範囲を切り出す） | `mapterhorn.yml`・`scripts/mapterhorn-plan.sh`・`scripts/mirror-mapterhorn.sh` |

```
GitHub Actions（OSM・Mapterhorn は週1、国土地理院は月2回）
  ├─ osm-openmaptiles.yml
  │    Geofabrik の Last-Modified（japan と補う地域）と Planetiler のバージョンを R2 のメタデータと比較
  │    → 変わっていれば pbf 取得 → 補う地域を切り出して結合 → Planetiler → pmtiles show・主要都市のタイルで検査 → R2 に上書き → キャッシュをパージ
  ├─ gsi-optimal-bvmap.yml
  │    配信元の ETag を R2 のメタデータと比較
  │    → 変わっていれば取得 → サイズ・ETag 再確認 → pmtiles show で検査 → R2 に上書き → キャッシュをパージ
  └─ mapterhorn.yml
       plan: 上流の md5 と R2 のメタデータを比較 → mirror: 変わったファイルだけ写す → purge

Cloudflare
  ├─ shi-works.com             R2 カスタムドメイン（Range リクエストで pmtiles:// を読む）
  ├─ tiles.shi-works.com       Worker dem2tiles-tiles（OSM・国土地理院の PMTiles → ZXY、Cache API）
  └─ mapterhorn.shi-works.com  Worker japan-basemap-mapterhorn（worker/。Mapterhorn を本家と同じ形の ZXY で、Cache API）
```

## OSM（生成）

所要は約 35 分、成果物は約 1.7GB（2026-10-12 の本番）。

1. **更新判定**: Geofabrik（japan と補う地域）の Last-Modified、補う地域の URL・bbox、名前を消す範囲（`territories.json` のハッシュ）、Planetiler のバージョンを R2 のメタデータと比べる。
   すべて同じなら何もしない（`force` で解除）
2. **取得**: `japan-latest.osm.pbf` と、補う地域の抽出（`russia/far-eastern-fed-district`、`asia/south-korea`）を取る
3. **補う地域の加工**: osmium で北方領土・竹島の bbox を切り出し、名前を消し（`strip_names`）、航路を除く（`drop_ferries`）。
   どちらも残りが 0 件でなければ止める（[領土の表示](#領土の表示北方領土竹島尖閣諸島)）
4. **結合**: osmium で japan と結合する。結合した pbf のヘッダには範囲が残らないので、タイルを作る範囲は明示する
5. **領土の範囲の名前を消す**: 結合したデータのうち、北方領土・竹島・尖閣諸島の範囲（`style/territories.json`）に入る地物の名前を消す
   （`strip_territory_names`）。消した後にもう一度切り出し、名前が残っていれば止める
6. **生成**: Planetiler 0.10.2（OpenMapTiles プロファイル）で z0–14 の PMTiles を作る。
   `--download` で Natural Earth・水域ポリゴンを取り、`--nodemap-type=sparsearray` でノード位置表を数 GB に抑える
   （array は最大のノード ID 分の領域を取り、約 76GB 要求してランナーのディスクが尽きた）
7. **検査**: `pmtiles show` で形式が MVT か、主要都市のタイルで地物数と都市名を、領土の範囲で名前の付いた地物が無いことを確かめる（[公開前の検査](#公開前の検査)）
8. **公開**: [公開と配信](#公開と配信)

元データの情報は R2 オブジェクトのメタデータ（`x-amz-meta-source-*`、`planetiler-version`）に、検査の統計は `feature-stats` に残す。

## 国土地理院（ミラー）

配信元の `optimal_bvmap-v1.pmtiles` を作り直さずに写す（作業領域に約 22GB を要する）。

1. **更新判定**: 配信元の ETag を R2 のメタデータと比べ、同じなら何もしない
2. **取得**: ランナーの `/mnt` に落とす
3. **再確認**: 取得中に配信元が差し替わっていないか、サイズと ETag をもう一度見る（新旧が混ざったファイルを上げない）
4. **検査**: `pmtiles show` で形式が MVT かを見る
5. **公開**: [公開と配信](#公開と配信)

配信元の全国更新は 2〜4 か月ごとなので、確認は月 2 回（2 日・16 日）で足りる。曜日での隔週は cron で書けないため日付で指定している。

## Mapterhorn（ミラー）

上流は z0–12 の `planet.pmtiles`（全球 356GB）と、z13 以上を z6 タイル単位に分けた `6-{x}-{y}.pmtiles` で配られている
（[distribution](https://github.com/mapterhorn/mapterhorn/tree/main/distribution)）。日本域は 2026-10 時点で
サブピラミッド 22 本・251.8GB、planet の切り出しは 2.7GB。

| ファイル | ズーム | 作り方 |
|---|---|---|
| `planet-japan.pmtiles` | z0–12 | `pmtiles extract` で日本の bbox（122.9,20.4,154.0,45.6）を切り出す |
| `6-{x}-{y}.pmtiles`（22 本） | z13–16 | 上流と同じ名前・同じ中身で写す（日本の外も含む） |

- `plan` ジョブが `download_urls.json` の md5 と R2 のメタデータ `source-md5` を比べ、変わったファイルだけ `mirror` に回す
- サブピラミッドは最大 66GB でランナーのディスクに載らないため、上流から 2GiB ずつ Range で取り、**R2 の一時キー `_staging/…` へストリームで流し込み**、
  md5・サイズが上流と一致したら本番キーへ R2 内でコピーする。壊れた写しで本番を上書きしない
- `planet-japan` は切り出し中に上流の planet が差し替わっていたら次回に回す
- 1 ファイル 1 ジョブ（同時 4 本）。最後に `mapterhorn.shi-works.com` をパージする
- ファイル名は上流と同じにしてあるので、後から[公式ミラー](https://github.com/mapterhorn/mapterhorn/blob/main/distribution/mirrors.json)に登録できる

表示する側は z12 以下を `planet-japan`、z13 以上をそのタイルを含む z6 タイルの `6-x-y` から読む。
ZXY では Worker（`worker/`）が、ビューアでは独自スキーム `mapterhorn://` がこの振り分けをする。

## 公開と配信

公開とは R2 の同じキーへの上書きのことで、配信はそのファイルを 2 通りで読むだけである。

- **差し替えは同じキーへの上書き。** マルチパートアップロードは完了時に一括で差し替わるので、書き込み途中の状態は読まれない
- **上書きの前に直前の版を退避する**（[直前の版への戻し](#直前の版への戻し)）
- **R2 内のコピー**は 5GiB 未満が単発の CopyObject、5GiB 以上がマルチパートコピー。
  R2 は `x-amz-tagging-directive` も GetObjectTagging も実装していないので、どちらも使わない書き方にしている（`scripts/lib.sh` の `r2_copy`）

| 経路 | ホスト | 仕組み |
|---|---|---|
| PMTiles 直読み | `shi-works.com` | R2 のカスタムドメイン。ブラウザが Range リクエストで必要な部分だけ読む。ビューアはこちら |
| ZXY（OSM・国土地理院） | `tiles.shi-works.com` | dem2tiles の Worker `dem2tiles-tiles` が PMTiles から 1 枚取り出して返す |
| ZXY（Mapterhorn） | `mapterhorn.shi-works.com` | このリポジトリの `worker/`（`japan-basemap-mapterhorn`）。ズームでアーカイブを選ぶ。日本の外は 404 |

- Worker はアーカイブのヘッダとディレクトリをメモリに持ち、返したタイルを Cache API に置く（R2 の Range 読みは 1 回約 0.2 秒）。
  アーカイブの ETag が変わると読み直す（`EtagMismatch`）
- 差し替えの後に `shi-works.com/<key>` と ZXY のホストを prefix でパージする。
  `CLOUDFLARE_API_TOKEN` が無ければパージを省き、Worker のキャッシュ期限 1 日で入れ替わる
- Mapterhorn の Worker は R2 を読むだけで書き込まない。コードを変えたときだけ手でデプロイする（[operations.md](operations.md#mapterhorn-の-workerworker)）

## 公開前の検査

壊れたものや荒らされたものは上げない。どれかに引っかかると止まる（`force` で解除）。

| 検査 | 対象 | 止める条件 |
|---|---|---|
| サイズ（`guard_size`） | 全部 | 前回の 70% 未満 |
| 形式（`pmtiles show`） | OSM・国土地理院 | タイル形式が MVT でない |
| 地物数（`scripts/check-osm.py`） | OSM | 主要都市の z14 タイルで、レイヤ別の地物数が前回から 20% を超えて増減 |
| 都市名（`scripts/check-osm.py`） | OSM | z10 タイルの `place` に都市名（「札幌市」「東京都」など）が日本語で出ていない |
| 領土の範囲の名前（`scripts/check-osm.py`） | OSM | 北方領土・竹島・尖閣諸島の範囲に名前の付いた地物がある（[領土の表示](#領土の表示北方領土竹島尖閣諸島)） |
| md5 照合 | Mapterhorn | `_staging` の写しが上流の md5・サイズと一致しない |
| 取得中の差し替わり | 国土地理院・Mapterhorn の planet | 取得の前後で ETag・md5 が違う |

OSM は誰でも編集できるデータを週 1 で無審査に公開するので、一部地域の欠落や荒らしを素通りさせないために主要都市のタイルを見る。

- 都市は札幌・仙台・東京・名古屋・大阪・広島・松山・福岡・那覇。レイヤは `transportation`・`building`・`water`・`landuse`・`poi`・`place`
- 前回 50 未満のレイヤは揺れが大きいので見ない。前回の数は R2 のメタデータ `feature-stats` に入れてあり、直前の版の退避・戻しでも一緒に動く
- 閾値（`CHECK_MAX_CHANGE`・`CHECK_MIN_COUNT`）は仮。数週分の実測で週ごとの自然な変動幅を見て決め直す。
  意図した変化（Planetiler の更新など）で止まったら `force` で解除する

## 直前の版への戻し

R2 にはバージョニングが無いので、上書きの前に今の版を `_previous/<key>` へ R2 内でコピーする
（OSM・国土地理院・Mapterhorn の `planet-japan`）。壊れた版を公開してしまったら、Actions の「直前の版に戻す」
（`rollback.yml`、`scripts/rollback.sh`）で今の版と入れ替えてパージする。もう一度実行すると戻す前の版に戻る。

- 戻しても次の定期実行で同じものが再び上がりうるので、原因を直すまでそのワークフローを止めておく
- Mapterhorn の `6-x-y` は上流と md5 を照合してから差し替える写しで、合計 254GB あるため残さない（上流から取り直す）

## 領土の表示（北方領土・竹島・尖閣諸島）

日本の領土の表記は外務省が公表する立場（北方領土・竹島・尖閣諸島はいずれも日本の領土）に合わせる。

OSM は実効支配に基づいて国を分ける（On the Ground 原則）。Geofabrik の `japan` には北方領土（ロシア側）と
竹島（韓国側）が入っていないため、`russia/far-eastern-fed-district` と `asia/south-korea` から
その範囲だけを切り出して結合している（`scripts/build-osm.sh` の `EXTRA_SOURCES`）。
これで道路・建物・地名などの地物はタイルに入る。

切り出しは範囲にかかる way を範囲の外まで丸ごと残すので、そのままだと竹島〜鬱陵島、北方領土〜サハリン（コルサコフ）、
色丹島〜国後島といった隣国が運航する航路も入る。補った地域からは航路（`route=ferry`）を除いている（`build-osm.sh` の `drop_ferries`）。

**地名は国土地理院の注記を使う。** OSM の名前は、北方領土はロシア語、竹島は韓国語や韓国の行政名（「독도리」／`name:ja`「独島里」）で、
`name:ja` も日本の地名とは限らない（例: 国後島の中心集落が「古釜布」ではなく「ユジノ・クリリスク」）。そこで

尖閣諸島は Geofabrik の `japan` に入っているが、`name` が「魚釣島/釣魚臺/钓鱼岛」のような併記だったり、
海峡・湾・山の名前が中国語だけ（「元宝门/元寶門」「钓鱼西水道」など）だったりする。そこで

1. **タイル生成時**に、北方領土・竹島・尖閣諸島の範囲（`style/territories.json`）に入る地物の名前（`name`・`name:*`・`alt_name` など。地名・道路名・店名）を消す。
   補った地域の抽出からは名前をすべて消し（`build-osm.sh` の `strip_names`）、さらに結合した後のデータで範囲に入るものを消す（`strip_territory_names`）。
   後者が要るのは、japan の抽出から入る地物があるため（尖閣諸島のすべて、歯舞群島にかかるロシアの保護区「Малые Курилы」など。
   両方の抽出に同じ版で入っているオブジェクトは、結合でどちらが残るかが決まらない）。名前を消したオブジェクトは版を 1 つ上げ、
   `osmium apply-changes` で差し替える。
   行政界（`boundary=administrative`）の関係は名前を残す。範囲に少しでもかかると「日本」「北海道」のような範囲の外の行政区画まで消えてしまうため
   （タイルの行政界に名前は付かない）。どの OpenMapTiles 系スタイルで表示しても、ロシア語・韓国語・中国語の地名は出ない
2. **スタイル**（`style/openmaptiles-japan.json`）で、同じ範囲にだけ国土地理院 最適化ベクトルタイルの注記（`Anno` レイヤー）を重ねる。
   範囲は島の海岸線から 10km、北方領土は北海道の海岸線との中間線で切ってある（`style/tools/make_territories.py`）
3. **公開前の検査**（`scripts/check-osm.py`）で、範囲の中に名前の付いた地物が無いことを z10・z12・z14 のタイルで確かめる
   （1 つの多角形で 400 枚を超えるズームは見ない）

**国境線は国土地理院の「国の所属界」を使う。** タイルには根室海峡などの日露の線が `admin_level=2`・`maritime=1`・
`adm0_l=RUS`／`adm0_r=JPN`・`disputed=0`（係争扱いになっていない）で入っている。ただし Bright は海上の線（`maritime=1`）を描かないので、
日本周辺でスタイルに出る OSM の線は、z0–4（Natural Earth 由来）の北方領土の係争線（`disputed=1`、根室海峡〜国後水道）だけになる。そこで

1. その係争線を消す（`boundary_disputed` に、北方領土周辺の範囲に収まる線を除く条件を足す）
2. 国土地理院 最適化ベクトルタイルの「国の所属界」（`AdmBdry`・`vt_code=1221`）を z4–7 に重ねる（`gsi_boundary_country`、見た目は `boundary_2` と同じ）。
   択捉島と得撫島の間、竹島と鬱陵島の間、対馬海峡、宗谷海峡、与那国島と台湾の間などに引かれ、根室海峡には無い。
   国土地理院のデータは z8 以上にこの線を持たない（標準地図も z8 以上では描かない）ので、z8 以上ではどちらの線も出ない

国名ラベルは「日本」だけが入っていて、北方領土付近に「ロシア」は出ない。

**「日本海」は国土地理院の注記で出す。** OSM の日本海の点は Geofabrik の `japan` の範囲の外にあり、タイルに入らない。
スタイルで国土地理院の注記の「日本海」（z4–6）を重ねる（`gsi_anno_japan_sea`）。

## スタイルとビューアの作り方

- `style/openmaptiles-japan.json`（PMTiles 版）と `openmaptiles-japan-zxy.json`（ZXY 版）は、`vendor/openfreemap-bright.json` を
  `build-style.ts` で書き換えて作る。2 本はタイルの参照先だけが違う。手で編集しない（CI は `pnpm check` で差分が無いことを確かめる）
- 2 本は `pages.yml` がビューアと一緒に GitHub Pages のルートに置く（`vite.config.ts` の `emit-styles`）。
  R2 に置かないのは、main へのマージだけで更新でき、R2 へ上げる仕組みが要らないため。GitHub Pages は `Access-Control-Allow-Origin: *` を返すので、ほかのサイトからも読める
- フォント・アイコンは OpenFreeMap（`tiles.openfreemap.org`）を参照している。困ったことが起きるまでは自前で持たない
- `territories.json` は `tools/make_territories.py`（shapely）で OSM の海岸線から作る（手順はスクリプトの先頭）
- ビューア（`style/index.html`・`style/src/main.ts`）は main の `style/` が変わると `pages.yml` がビルドして GitHub Pages に出す
- ビューアの Mapterhorn は、本家の [PMTiles の例](https://github.com/mapterhorn/mapterhorn/tree/main/website/examples/pmtiles)と同じく、
  独自スキーム `mapterhorn://` の中で z12 以下は `planet-japan`、z13 以上は `6-x-y` を選ぶ。読む区画の一覧は `src/main.ts` の `BUNDLES`
  （上流で区画が増えたら足す）
- `vendor/gsi-std.json` は [gsi-cyberjapan/optimal_bvmap](https://github.com/gsi-cyberjapan/optimal_bvmap) の `style/std.json`（2ce7dcf、2025-09-03）の写し。
  参照先を R2 に替えて使う。フォントとアイコンは配信元（gsi-cyberjapan.github.io）を参照する

## コストの目安

| 項目 | 目安 |
|---|---|
| R2 ストレージ | 約 294GB（Mapterhorn 254.5GB + 国土地理院 16.9GB + OSM 1.7GB と、その直前の版 約 21GB）× $0.015/GB・月 ≒ **$4.4/月**（Mapterhorn 分が約 $3.8） |
| R2 書き込み（Class A） | 1 回のアップロードで 300 パート程度。無料枠（100 万/月）に収まる |
| R2 読み出し（Class B） | 未キャッシュのタイル 1 枚あたり 1〜2 回。1,000 万/月まで無料、超過は $0.36/100 万 |
| 転送量 | R2 は無料 |
| Workers | ZXY 経由のみ。無料プランは 10 万リクエスト/日、有料は $5/月で 1,000 万込み |
| GitHub Actions | public リポジトリの標準ランナーは無料 |
