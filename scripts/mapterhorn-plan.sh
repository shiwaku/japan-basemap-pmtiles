#!/usr/bin/env bash
# Mapterhorn の日本域で、R2 の写しと md5 が違うファイルを列挙する。
#
#   scripts/mapterhorn-plan.sh   → GITHUB_OUTPUT に files=["planet-japan","6-56-25",...]
#
# 判定は download_urls.json の md5sum と、R2 オブジェクトのメタデータ source-md5 の比較。
#   planet-japan … planet.pmtiles（z0–12、全球）から日本を切り出したもの。planet の md5 で判定する
#   6-x-y        … z13 以上のサブピラミッド。日本の範囲に掛かるものをそのまま写す
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/mapterhorn-config.sh
source "$(dirname "$0")/mapterhorn-config.sh"

mkdir -p "$WORK_DIR"
curl -fsSL -o "$WORK_DIR/download_urls.json" "$MAPTERHORN_BASE/download_urls.json"
log "download_urls.json version $(jq -r .version "$WORK_DIR/download_urls.json")"

# 名前・md5・サイズを「name md5 size」の行で出す。planet は planet-japan として扱う
jq -r --argjson b "[$JAPAN_BBOX]" '
  .items[]
  | if .name == "planet.pmtiles" then "planet-japan \(.md5sum) \(.size)"
    elif (.min_lon < $b[2] and .max_lon > $b[0] and .min_lat < $b[3] and .max_lat > $b[1])
    then "\(.name | rtrimstr(".pmtiles")) \(.md5sum) \(.size)"
    else empty end
' "$WORK_DIR/download_urls.json" >"$WORK_DIR/japan-files.txt"

changed=()
total=0
while read -r name md5 size; do
  prev=$(r2_meta "$MAPTERHORN_PREFIX/$name.pmtiles" source-md5)
  if [[ "${FORCE:-false}" == "true" || "$md5" != "$prev" ]]; then
    changed+=("$name")
    [[ "$name" == planet-japan ]] || total=$((total + size))
    log "更新: $name（$((size / 1000000)) MB）"
  fi
done <"$WORK_DIR/japan-files.txt"

log "日本域 $(wc -l <"$WORK_DIR/japan-files.txt") ファイル中 ${#changed[@]} 件を取り直す（サブピラミッド計 $((total / 1000000000)) GB）"
files=$(jq -cn '$ARGS.positional' --args "${changed[@]}")
echo "$files"
gh_output files "$files"
