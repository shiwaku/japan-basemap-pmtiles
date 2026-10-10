#!/usr/bin/env bash
# 国土地理院 最適化ベクトルタイル（optimal_bvmap-v1.pmtiles）を R2 にミラーする。
#
#   WORK_DIR=/mnt/work FORCE=false scripts/mirror-gsi.sh
#
# 配信元の ETag が前回と同じなら何もしない（全国更新は 2〜4 か月ごと）。
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

SRC_URL=https://cyberjapandata.gsi.go.jp/xyz/optimal_bvmap-v1/optimal_bvmap-v1.pmtiles
KEY=pmtiles/gsi/optimal_bvmap/optimal_bvmap-v1.pmtiles

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

headers=$(curl -fsSIL "$SRC_URL" | tr -d '\r')
header() { awk -F': ' -v h="$1" 'tolower($1)==h{v=$2} END{print v}' <<<"$headers"; }
src_etag=$(header etag | tr -d '"')
src_modified=$(header last-modified)
src_length=$(header content-length)
log "GSI ETag: $src_etag / Last-Modified: $src_modified / $src_length bytes"
[[ -n "$src_etag" && -n "$src_length" ]] || { log "配信元のヘッダが取れない"; exit 1; }

prev_etag=$(r2_meta "$KEY" source-etag)
if [[ "${FORCE:-false}" != "true" && "$src_etag" == "$prev_etag" ]]; then
  log "配信元が更新されていないのでスキップ"
  gh_output updated false
  exit 0
fi

require_free_gb $((src_length / 1000000000 + 5))
install_pmtiles

log "ダウンロード"
rm -f optimal_bvmap-v1.pmtiles
curl -fsSL --retry 5 --retry-all-errors -C - -o optimal_bvmap-v1.pmtiles "$SRC_URL"
got=$(stat -c %s optimal_bvmap-v1.pmtiles)
[[ "$got" == "$src_length" ]] || { log "サイズ不一致: $got != $src_length"; exit 1; }

# ダウンロード中に配信元が差し替わっていないか（混ざったファイルを上げない）
after_etag=$(curl -fsSIL "$SRC_URL" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{v=$2} END{print v}' | tr -d '"')
[[ "$after_etag" == "$src_etag" ]] || { log "ダウンロード中に配信元が更新された。次回に回す"; exit 1; }

pmtiles show optimal_bvmap-v1.pmtiles | tee show.txt
grep -qiE 'tile type:.*mvt' show.txt || { log "MVT ではない"; exit 1; }

guard_size optimal_bvmap-v1.pmtiles "$KEY"
r2_upload optimal_bvmap-v1.pmtiles "$KEY" \
  "$(jq -cn --arg u "$SRC_URL" --arg e "$src_etag" --arg m "$src_modified" \
    '{"source-url":$u,"source-etag":$e,"source-last-modified":$m}')"
purge_cache "$KEY"

gh_output updated true
gh_output size "$got"
