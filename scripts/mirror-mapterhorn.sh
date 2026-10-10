#!/usr/bin/env bash
# Mapterhorn のファイルを 1 つ R2 に写す。
#
#   WORK_DIR=/mnt/work scripts/mirror-mapterhorn.sh planet-japan
#   WORK_DIR=/mnt/work scripts/mirror-mapterhorn.sh 6-56-25
#
# planet-japan: planet.pmtiles から日本の範囲を pmtiles extract で切り出して上げる（約 2.7GB）
# 6-x-y       : ディスクを使わず R2 の一時キーへ流し込み、md5 が上流と一致したら本番キーへ R2 内でコピーする。
#               最大 66GB あり、ランナーのディスクには載らない。壊れた写しで本番キーを上書きしないための二段構え
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/mapterhorn-config.sh
source "$(dirname "$0")/mapterhorn-config.sh"

NAME=${1:?ファイル名（planet-japan / 6-x-y）}
[[ "$NAME" =~ ^(planet-japan|6-[0-9]+-[0-9]+)$ ]] || { log "不正な名前: $NAME"; exit 1; }
KEY="$MAPTERHORN_PREFIX/$NAME.pmtiles"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
curl -fsSL -o download_urls.json "$MAPTERHORN_BASE/download_urls.json"
src_name=$NAME.pmtiles
[[ "$NAME" == planet-japan ]] && src_name=planet.pmtiles
read -r md5 size < <(jq -r --arg n "$src_name" '.items[] | select(.name == $n) | "\(.md5sum) \(.size)"' download_urls.json)
[[ -n "${md5:-}" ]] || { log "$src_name が download_urls.json に無い"; exit 1; }
src_url="$MAPTERHORN_BASE/$src_name"
log "$src_name md5=$md5 size=$size"

aws configure set default.s3.multipart_chunksize 64MB
aws configure set default.s3.max_concurrent_requests 16

if [[ "$NAME" == planet-japan ]]; then
  install_pmtiles
  rm -f planet-japan.pmtiles
  pmtiles extract "$src_url" planet-japan.pmtiles --bbox="$JAPAN_BBOX" --download-threads=8
  pmtiles show planet-japan.pmtiles | tee show.txt
  grep -qiE 'tile type:.*webp' show.txt || { log "WebP ではない"; exit 1; }
  # 抽出中に planet が差し替わっていたら混ざっている可能性がある
  now_md5=$(curl -fsSL "$MAPTERHORN_BASE/download_urls.json" | jq -r '.items[] | select(.name == "planet.pmtiles") | .md5sum')
  [[ "$now_md5" == "$md5" ]] || { log "抽出中に planet.pmtiles が更新された。次回に回す"; exit 1; }
  guard_size planet-japan.pmtiles "$KEY"
  r2_upload planet-japan.pmtiles "$KEY" \
    "$(jq -cn --arg u "$src_url" --arg m "$md5" --arg b "$JAPAN_BBOX" '{"source-url":$u,"source-md5":$m,"bbox":$b}')"
  purge_prefixes "shi-works.com/$KEY"
  gh_output size "$(stat -c %s planet-japan.pmtiles)"
  exit 0
fi

STAGING="_staging/$KEY"
for attempt in 1 2 3; do
  log "転送 $attempt 回目: $src_url → s3://$R2_BUCKET/$STAGING"
  rm -f got.md5
  # 途中で切れたら curl の再開は使わず（ストリームが継ぎはぎになる）、最初からやり直す
  if curl -fsSL "$src_url" \
    | tee >(md5sum | cut -d' ' -f1 >got.md5) \
    | aws s3 cp - "s3://$R2_BUCKET/$STAGING" --endpoint-url "$R2_ENDPOINT" \
      --expected-size "$size" \
      --content-type application/octet-stream \
      --cache-control "public, max-age=3600" \
      --metadata "$(jq -cn --arg u "$src_url" --arg m "$md5" '{"source-url":$u,"source-md5":$m}')" \
      --only-show-errors; then
    for _ in $(seq 60); do [[ -s got.md5 ]] && break; sleep 1; done
    got=$(cat got.md5 2>/dev/null || true)
    got_size=$(r2_size "$STAGING")
    if [[ "$got" == "$md5" && "$got_size" == "$size" ]]; then
      log "md5・サイズ一致"
      break
    fi
    log "不一致: md5 $got（期待 $md5）/ size $got_size（期待 $size）"
  fi
  [[ $attempt == 3 ]] && { log "3 回失敗"; exit 1; }
  sleep 60
done

# R2 内のコピー。大きいオブジェクトはマルチパートコピーになり、AWS CLI が呼ぶ GetObjectTagging を
# R2 が実装していないので --copy-props metadata-directive が要る（R2-STRUCTURE.md §6.7）
log "本番キーへコピー: $KEY"
aws s3 cp "s3://$R2_BUCKET/$STAGING" "s3://$R2_BUCKET/$KEY" --endpoint-url "$R2_ENDPOINT" \
  --copy-props metadata-directive --only-show-errors
[[ "$(r2_size "$KEY")" == "$size" && "$(r2_meta "$KEY" source-md5)" == "$md5" ]] || { log "コピー後の確認に失敗"; exit 1; }
aws s3 rm "s3://$R2_BUCKET/$STAGING" --endpoint-url "$R2_ENDPOINT" --only-show-errors
purge_prefixes "shi-works.com/$KEY"
gh_output size "$size"
