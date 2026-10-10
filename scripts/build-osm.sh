#!/usr/bin/env bash
# Geofabrik の japan-latest.osm.pbf から OpenMapTiles スキーマの PMTiles を Planetiler で生成し、R2 に置く。
#
#   WORK_DIR=/mnt/work FORCE=false scripts/build-osm.sh
#   PLANETILER_TMP … Planetiler の一時ディレクトリ（既定 $WORK_DIR/data/tmp）
#
# Geofabrik の japan は OSM の実効支配による範囲で、北方領土（ロシア側）と竹島（韓国側）を含まない。
# その地物を隣国の抽出から切り出して結合する（issue #3）。国境線・国名の表示は OSM のまま変わらないので、
# 日本の公式見解での表示はスタイル側で行う（README「領土の表示」）。
#
# 元データ（すべての Last-Modified）と Planetiler のバージョンが前回と同じなら何もしない。
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

PLANETILER_VERSION=0.10.2
PLANETILER_SHA256=f310bd0413e2e4512b27f4046d418664e8e1d3bf31603c2a70e23de06c167e4d
# ローカル試験では小さい地域に替えられる（例: asia/japan/shikoku-latest.osm.pbf）。R2 のキーは変わらないので本番では替えない
: "${PBF_URL:=https://download.geofabrik.de/asia/japan-latest.osm.pbf}"
# 補う地域。"URL|切り出す bbox（west,south,east,north）" を空白区切りで並べる。空にすると補わない
#   北方領土（色丹・歯舞・国後・択捉。得撫島より南）と竹島
: "${EXTRA_SOURCES=\
https://download.geofabrik.de/russia/far-eastern-fed-district-latest.osm.pbf|145.2,43.2,149.0,45.65 \
https://download.geofabrik.de/asia/south-korea-latest.osm.pbf|131.8,37.2,131.95,37.3}"
# タイルを作る範囲。結合した pbf のヘッダには範囲が残らないので明示する
: "${OSM_BOUNDS:=122.9,20.4,154.0,45.6}"
KEY="${KEY_PREFIX}pmtiles/osm/openmaptiles-japan.pmtiles"
: "${JAVA_XMX:=10g}"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 補う地域の名前（地名・道路名・店名など）を消す。北方領土はロシア語・竹島は韓国語や韓国の行政名になっており、
# name:ja も日本の地名とは限らないため。地名はスタイルで国土地理院 最適化ベクトルタイルの注記を重ねる（README「領土の表示」）。
#   strip_names <入力 pbf> <出力 pbf>
# OPL（1 行 1 オブジェクト、タグは "T" で始まる欄にカンマ区切り）にして名前系のキーだけ落とす
strip_names() {
  osmium cat -f opl "$1" | awk '
    {
      for (i = 1; i <= NF; i++) {
        if (substr($i, 1, 1) != "T") continue
        n = split(substr($i, 2), tags, ",")
        kept = ""
        for (j = 1; j <= n; j++) {
          key = tags[j]
          sub(/=.*/, "", key)
          if (key ~ /^(name|alt_name|old_name|official_name|short_name|int_name|loc_name|reg_name|nat_name|sorting_name)(:|$)/) continue
          kept = kept (kept == "" ? "" : ",") tags[j]
        }
        $i = "T" kept
      }
      print
    }' | osmium cat -F opl - --overwrite -o "$2"
  local left
  left=$(osmium cat -f opl "$2" | grep -cE '(^| )T([^ ]*,)?(name|alt_name|old_name|official_name)(:[^=,]*)?=' || true)
  ((left == 0)) || { log "名前が消えていない: $left 件"; exit 1; }
}

last_modified() { curl -fsSIL "$1" | tr -d '\r' | awk -F': ' 'tolower($1)=="last-modified"{v=$2} END{print v}'; }

read -ra extras <<<"$EXTRA_SOURCES"
# 前回との比較用。補う地域の URL・bbox を変えたときも作り直す
src_modified=$(last_modified "$PBF_URL")
for e in "${extras[@]}"; do
  src_modified+="; $e $(last_modified "${e%%|*}")"
done
log "元データ: $src_modified"
prev_modified=$(r2_meta "$KEY" source-last-modified)
prev_planetiler=$(r2_meta "$KEY" planetiler-version)
if [[ "${FORCE:-false}" != "true" && "$src_modified" == "$prev_modified" && "$PLANETILER_VERSION" == "$prev_planetiler" ]]; then
  log "前回と同じ元データ・同じ Planetiler なのでスキップ"
  gh_output updated false
  exit 0
fi

require_free_gb 30
install_pmtiles
command -v osmium >/dev/null || { log "osmium（osmium-tool）が無い"; exit 1; }

log "Planetiler $PLANETILER_VERSION を取得"
curl -fsSL -o planetiler.jar \
  "https://github.com/onthegomap/planetiler/releases/download/v${PLANETILER_VERSION}/planetiler.jar"
echo "$PLANETILER_SHA256  planetiler.jar" | sha256sum -c -

log "pbf を取得"
mkdir -p data/sources
curl -fsSL --retry 3 -o data/sources/japan.osm.pbf "$PBF_URL"
osm_input=data/sources/japan.osm.pbf
if ((${#extras[@]})); then
  parts=(data/sources/japan.osm.pbf)
  for i in "${!extras[@]}"; do
    url=${extras[$i]%%|*} bbox=${extras[$i]#*|}
    log "補う地域を取得・切り出し: $url（$bbox）"
    curl -fsSL --retry 3 -o "data/sources/extra-$i.osm.pbf" "$url"
    # smart: bbox にかかる道・マルチポリゴンは bbox の外にはみ出す部分も完全な形で残す
    osmium extract --strategy=smart -b "$bbox" --overwrite \
      -o "data/sources/extra-$i.raw.osm.pbf" "data/sources/extra-$i.osm.pbf"
    rm "data/sources/extra-$i.osm.pbf"
    strip_names "data/sources/extra-$i.raw.osm.pbf" "data/sources/extra-$i.clip.osm.pbf"
    rm "data/sources/extra-$i.raw.osm.pbf"
    parts+=("data/sources/extra-$i.clip.osm.pbf")
  done
  # 両方の抽出に入っている同じ版のオブジェクト（境界線など）は 1 つにまとまる。
  # 同じ版なら先に渡した japan 側（名前を消していない方）が残る
  osmium merge --overwrite -o data/sources/merged.osm.pbf "${parts[@]}"
  osmium fileinfo -e data/sources/merged.osm.pbf | grep -E 'Number of (nodes|ways|relations):' >&2
  osm_input=data/sources/merged.osm.pbf
fi

# --download: Natural Earth・水域ポリゴン・湖の中心線を取得する（OpenMapTiles の低ズームと海に必要）
log "Planetiler（OpenMapTiles）で生成"
rm -f openmaptiles-japan.pmtiles
java "-Xmx${JAVA_XMX}" -jar planetiler.jar \
  --osm-path="$osm_input" \
  --bounds="$OSM_BOUNDS" \
  --download \
  --download-dir=data/sources \
  --tmpdir="${PLANETILER_TMP:-data/tmp}" \
  --output=openmaptiles-japan.pmtiles \
  --nodemap-type=array --storage=mmap

pmtiles show openmaptiles-japan.pmtiles | tee show.txt
grep -qiE 'tile type:.*mvt' show.txt || { log "MVT ではない"; exit 1; }

guard_size openmaptiles-japan.pmtiles "$KEY"
r2_upload openmaptiles-japan.pmtiles "$KEY" \
  "$(jq -cn --arg u "$PBF_URL" --arg m "$src_modified" --arg v "$PLANETILER_VERSION" \
    '{"source-url":$u,"source-last-modified":$m,"planetiler-version":$v}')"
purge_cache "$KEY"

gh_output updated true
gh_output size "$(stat -c %s openmaptiles-japan.pmtiles)"
