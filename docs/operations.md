# 運用

定期実行の一覧、手動での操作、セットアップ、試験の手順。仕組みは [design.md](design.md)。

## ワークフロー

| ワークフロー | 実行 | 役割 |
|---|---|---|
| `osm-openmaptiles.yml` | 毎週月曜 03:00 JST、手動 | OSM の生成・公開 |
| `gsi-optimal-bvmap.yml` | 毎月 2 日・16 日 03:00 JST、手動 | 国土地理院のミラー |
| `mapterhorn.yml` | 毎週木曜 03:00 JST、手動 | Mapterhorn のミラー |
| `rollback.yml` | 手動のみ | 直前の版と入れ替える |
| `pages.yml` | main の `style/` 変更時 | ビューアとスタイルを GitHub Pages に出す |
| `lint.yml` | push・PR | スクリプトとスタイルの検査 |

- **手動実行**: Actions の各ワークフローから `Run workflow`。`force` で更新判定と公開前の検査を飛ばして作り直す
- **公開前の検査で止まったとき**: 意図した変化（Planetiler の更新など）なら `force` で再実行する。そうでなければ原因を調べる
- **壊れた版を公開してしまったとき**: 「直前の版に戻す」（`rollback.yml`）を実行し、原因を直すまでそのワークフローを止めておく。
  もう一度実行すると戻す前の版に戻る（[design.md](design.md#直前の版への戻し)）

## 所要時間（OSM、日本全域）

2026-10-12 の本番（run 38219876676、`ubuntu-24.04` の標準ランナー 4 コア）で **35 分**。
このうち Planetiler が 26 分半で、その半分以上を z13 の書き出しが占める。ワークフローの上限（`timeout-minutes`）は 300 分。

| 段階 | 時間 | 内容 |
|---|---|---|
| 準備 | 15 秒 | checkout・osmium の導入・更新判定・Planetiler の取得 |
| japan の pbf の取得 | 4 分 | `japan-latest.osm.pbf`（Geofabrik） |
| 補う地域 | 4 分 | ロシア極東の取得・切り出し 1 分、韓国の取得・切り出しと結合 3 分 |
| Planetiler: 準備 | 1 分半 | Natural Earth・水域ポリゴン・湖の中心線の取得と読み込み |
| Planetiler: OSM の読み込み | 10 分 | pass1 48 秒（ノード 3.3 億・道 4,700 万・関係 25 万）、pass2 9 分（うち道 6 分半）、並べ替え 48 秒 |
| Planetiler: 書き出し | 14 分 | z0–12 が 1 分、**z13 が 12 分**、z14 が 1 分 |
| 検査・アップロード | 20 秒 | 主要都市の検査 3 秒、1.7GB のアップロード 14 秒 |

- 北方領土・竹島・尖閣諸島の名前を消す処理（`strip_territory_names`）はこの計測の後に入った。結合した pbf を 2 回切り出して差し替えるので、手元（Docker、14 コア）で約 2〜3 分増えた
- 元データが前回と同じならスキップするので、その週は数秒で終わる
- 手元（Docker、14 コア）では Geofabrik からの取得が遅く、japan の pbf だけで 6 分かかった

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

元データの情報は R2 オブジェクトのメタデータで確かめられる。

```bash
aws s3api head-object --bucket shi-works --key pmtiles/osm/openmaptiles-japan.pmtiles \
  --endpoint-url https://<account>.r2.cloudflarestorage.com --query Metadata
```

### Mapterhorn の Worker（`worker/`）

`mapterhorn.shi-works.com` に Custom Domain として割り当てる（`wrangler.jsonc`）。R2 の `shi-works` を読むだけで、
書き込みはしない。コードを変えたときだけ手でデプロイする（ワークフローからはデプロイしない）。

```bash
cd worker
pnpm install
pnpm typecheck && pnpm check   # check は wrangler deploy --dry-run
pnpm exec wrangler login       # 初回のみ
pnpm deploy
```

手元で試すときは、小さいアーカイブを手元の R2 に入れて `pnpm dev` で動かす（`--local`。本番のバケットには触らない）。

```bash
pmtiles extract https://shi-works.com/pmtiles/mapterhorn/planet-japan.pmtiles planet-japan.pmtiles --maxzoom=7
pnpm exec wrangler r2 object put shi-works/pmtiles/mapterhorn/planet-japan.pmtiles --file planet-japan.pmtiles --local
pnpm dev   # http://127.0.0.1:8787/tilejson.json、http://127.0.0.1:8787/7/113/50.webp
```

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
直前の版の退避と `rollback.sh` での入れ替え（2 回で元に戻る）も国土地理院のキーで確かめる。
`WITH_OSM=true` で OSM（四国、約 10 分）も加わる。パージはしない。

① だけでは足りない。versitygw は R2 が実装していない API（`x-amz-tagging-directive` など）も受け付けるので、
R2 内コピーの不具合は ② でしか出ない（2026-10 の初回本番で小さいバンドルが失敗したのはこれ）。

タイル生成だけを見るなら、書き込まない `DRY_RUN`（compose の既定）で個別のスクリプトを動かせる。

```bash
docker compose run --rm -e PBF_URL=https://download.geofabrik.de/asia/japan/shikoku-latest.osm.pbf \
  -e OSM_BOUNDS=132.0,32.7,134.8,34.6 -e EXTRA_SOURCES= pipeline scripts/build-osm.sh
```

## 作業領域

本番はランナーの `/mnt`。ランナーによっては `/` と同じディスクで、空きは約 86GB。OSM は約 30GB、国土地理院は約 22GB を要求する。
Mapterhorn のサブピラミッドはランナーに置かず R2 へ直接流す。

手元では `./work`（.gitignore 済み）を使う。スクリプトはそれぞれ自分のディレクトリの中だけに書く。

| 場所 | 中身 | 消してよいか |
|---|---|---|
| `work/osm/` | `build-osm.sh` の作業場所。`openmaptiles-japan.pmtiles`（ビューアの `?local` が読む）、`planetiler.jar`、`data/sources/`（Natural Earth・水域ポリゴンのキャッシュと pbf） | pbf（`*.osm.pbf`）は毎回取り直すので消してよい。zip は消すと次回取り直す（約 1.4GB） |
| `work/gsi/` | `mirror-gsi.sh` の作業場所 | よい |
| `work/mapterhorn/` | `mapterhorn-plan.sh`・`mirror-mapterhorn.sh` の作業場所 | よい |
| `work/test-local/`・`work/test-r2/` | `test.sh` の作業場所。実行のたびに消して作り直す | よい |
| `work/testsrc/` | `test.sh` が使う試験用の国土地理院 PMTiles（compose の testsrc が配信）。無ければ作る | よい（次回作り直す） |
| `work/territories/` | `style/tools/make_territories.py` の入力（OSM の海岸線） | よい（手順はスクリプトの先頭） |
| `work/logs/` | 手で残すログ（`… 2>&1 \| tee work/logs/osm-japan.log` など） | よい |
