#!/usr/bin/env bash
# Geofabrik の japan-latest.osm.pbf から OpenMapTiles スキーマの PMTiles を Planetiler で生成し、R2 に置く。
#
#   WORK_DIR=/mnt/work FORCE=false scripts/build-osm.sh
#   PLANETILER_TMP … Planetiler の一時ディレクトリ（既定 $WORK_DIR/data/tmp）
#
# 元データ（Last-Modified）と Planetiler のバージョンが前回と同じなら何もしない。
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

PLANETILER_VERSION=0.10.2
PLANETILER_SHA256=f310bd0413e2e4512b27f4046d418664e8e1d3bf31603c2a70e23de06c167e4d
# ローカル試験では小さい地域に替えられる（例: asia/japan/shikoku-latest.osm.pbf）。R2 のキーは変わらないので本番では替えない
: "${PBF_URL:=https://download.geofabrik.de/asia/japan-latest.osm.pbf}"
KEY=pmtiles/osm/openmaptiles-japan.pmtiles
: "${JAVA_XMX:=10g}"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

src_modified=$(curl -fsSIL "$PBF_URL" | tr -d '\r' | awk -F': ' 'tolower($1)=="last-modified"{v=$2} END{print v}')
log "Geofabrik Last-Modified: $src_modified"
prev_modified=$(r2_meta "$KEY" source-last-modified)
prev_planetiler=$(r2_meta "$KEY" planetiler-version)
if [[ "${FORCE:-false}" != "true" && "$src_modified" == "$prev_modified" && "$PLANETILER_VERSION" == "$prev_planetiler" ]]; then
  log "前回と同じ元データ・同じ Planetiler なのでスキップ"
  gh_output updated false
  exit 0
fi

require_free_gb 30
install_pmtiles

log "Planetiler $PLANETILER_VERSION を取得"
curl -fsSL -o planetiler.jar \
  "https://github.com/onthegomap/planetiler/releases/download/v${PLANETILER_VERSION}/planetiler.jar"
echo "$PLANETILER_SHA256  planetiler.jar" | sha256sum -c -

log "pbf を取得"
mkdir -p data/sources
curl -fsSL --retry 3 -o data/sources/japan.osm.pbf "$PBF_URL"

# --download: Natural Earth・水域ポリゴン・湖の中心線を取得する（OpenMapTiles の低ズームと海に必要）
log "Planetiler（OpenMapTiles）で生成"
rm -f openmaptiles-japan.pmtiles
java "-Xmx${JAVA_XMX}" -jar planetiler.jar \
  --osm-path=data/sources/japan.osm.pbf \
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
