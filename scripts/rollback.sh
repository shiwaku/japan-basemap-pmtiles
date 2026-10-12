#!/usr/bin/env bash
# 本番キーを直前の版（r2_upload が上書きの前に写した _previous/<key>）に戻し、キャッシュをパージする。
# 今の版と直前の版を入れ替えるので、もう一度実行すると戻す前の版に戻る。
#
#   scripts/rollback.sh osm | gsi | planet-japan
#
# Mapterhorn の 6-x-y は直前の版を残していないので戻せない（上流から取り直す）。
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/mapterhorn-config.sh
source "$(dirname "$0")/mapterhorn-config.sh"

case "${1:?osm / gsi / planet-japan}" in
  osm) KEY="${KEY_PREFIX}pmtiles/osm/openmaptiles-japan.pmtiles" ;;
  gsi) KEY="${KEY_PREFIX}pmtiles/gsi/optimal_bvmap/optimal_bvmap-v1.pmtiles" ;;
  planet-japan) KEY="$MAPTERHORN_PREFIX/planet-japan.pmtiles" ;;
  *) log "osm / gsi / planet-japan のどれか"; exit 2 ;;
esac
PREV=$(previous_key "$KEY")
TMP="_staging/$KEY.rollback"

r2_readable || { log "R2 の認証情報が無い"; exit 1; }
prev_size=$(r2_size "$PREV")
((prev_size > 0)) || { log "直前の版が無い: $PREV"; exit 1; }
log "今の版: $(r2_size "$KEY") bytes / 直前の版: $prev_size bytes"
if is_dry_run; then
  log "DRY_RUN: 入れ替えない"
  exit 0
fi

# 本番キーは R2 内コピーで丸ごと差し替わるので、途中で止まっても壊れた状態にはならない
log "今の版を一時キーへ: $TMP"
r2_copy "$KEY" "$TMP"
log "直前の版を本番キーへ: $PREV → $KEY"
r2_copy "$PREV" "$KEY"
log "戻す前の版を直前の版の位置へ: $TMP → $PREV"
r2_copy "$TMP" "$PREV"
aws s3 rm "s3://$R2_BUCKET/$TMP" --endpoint-url "$R2_ENDPOINT" --only-show-errors

if [[ "$1" == planet-japan ]]; then
  # tiles.shi-works.com/mapterhorn/... はファイル名と URL が対応しないのでまとめて消す（mapterhorn.yml と同じ）
  purge_prefixes "shi-works.com/$KEY" "tiles.shi-works.com/mapterhorn"
else
  purge_cache "$KEY"
fi
log "戻した: $KEY"
