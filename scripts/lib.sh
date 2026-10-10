# shellcheck shell=bash
# 各スクリプトから source する共通処理。
#
# 必要な環境変数:
#   R2_ACCOUNT_ID, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY  … R2（S3 互換 API）
#   CLOUDFLARE_API_TOKEN, CLOUDFLARE_ZONE_ID                 … キャッシュのパージ
#   WORK_DIR                                                  … 作業ディレクトリ（大容量）

set -euo pipefail

: "${R2_BUCKET:=shi-works}"
: "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID が未設定}"
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

export AWS_DEFAULT_REGION=auto
# AWS CLI 2.23 以降の既定（CRC 整合性チェック）は R2 と噛み合わないことがあるので、必要時のみにする
export AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED
export AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED

PMTILES_VERSION=1.31.2
PMTILES_SHA256=3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# GitHub Actions のステップ出力。ローカル実行では何もしない
gh_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1=$2" >>"$GITHUB_OUTPUT"; fi
}

# 作業ディレクトリの空きを確かめる（GB）
require_free_gb() {
  local need=$1 free
  free=$(df -BG --output=avail "$WORK_DIR" | tail -1 | tr -dc 0-9)
  log "空き容量 ${free}GB（必要 ${need}GB）: $WORK_DIR"
  ((free >= need)) || { log "空き容量が足りない"; exit 1; }
}

install_pmtiles() {
  command -v pmtiles >/dev/null && return
  local tgz="$WORK_DIR/go-pmtiles.tar.gz"
  curl -fsSL -o "$tgz" \
    "https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/go-pmtiles_${PMTILES_VERSION}_Linux_x86_64.tar.gz"
  echo "$PMTILES_SHA256  $tgz" | sha256sum -c -
  mkdir -p "$WORK_DIR/bin"
  tar -xzf "$tgz" -C "$WORK_DIR/bin" pmtiles
  export PATH="$WORK_DIR/bin:$PATH"
}

# R2 オブジェクトのユーザーメタデータ（x-amz-meta-*）を1つ読む。オブジェクトが無ければ空文字
r2_meta() {
  local key=$1 name=$2
  aws s3api head-object --endpoint-url "$R2_ENDPOINT" --bucket "$R2_BUCKET" --key "$key" \
    --query "Metadata.\"$name\"" --output text 2>/dev/null | grep -v '^None$' || true
}

r2_size() {
  local key=$1
  aws s3api head-object --endpoint-url "$R2_ENDPOINT" --bucket "$R2_BUCKET" --key "$key" \
    --query ContentLength --output text 2>/dev/null || echo 0
}

# PMTiles を R2 にアップロードする。同じキーへの上書き（URL を変えない）。
# マルチパートは完了時に一括で差し替わるので、途中の状態が読まれることはない。
#   r2_upload <file> <key> <metadata JSON>（値にカンマを含む Last-Modified を入れるため JSON で渡す）
r2_upload() {
  local file=$1 key=$2 meta=$3
  aws configure set default.s3.multipart_chunksize 64MB
  aws configure set default.s3.max_concurrent_requests 16
  log "アップロード: $file → s3://$R2_BUCKET/$key"
  aws s3 cp "$file" "s3://$R2_BUCKET/$key" --endpoint-url "$R2_ENDPOINT" \
    --content-type application/octet-stream \
    --cache-control "public, max-age=3600" \
    --metadata "$meta" --only-show-errors
  local got want
  got=$(r2_size "$key")
  want=$(stat -c %s "$file")
  [[ "$got" == "$want" ]] || { log "サイズ不一致: R2=$got local=$want"; exit 1; }
  log "アップロード完了（$want bytes）"
}

# 差し替えたアーカイブのキャッシュを消す。
#   shi-works.com/<key>           … pmtiles:// で直接読む経路
#   tiles.shi-works.com/<name>    … Worker dem2tiles-tiles の ZXY / TileJSON（Cache API）
purge_cache() {
  local key=$1 name=${1#pmtiles/}
  name=${name%.pmtiles}
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${CLOUDFLARE_ZONE_ID:-}" ]]; then
    log "CLOUDFLARE_API_TOKEN / CLOUDFLARE_ZONE_ID が無いのでパージを省略"
    return
  fi
  local body
  body=$(printf '{"prefixes":["shi-works.com/%s","tiles.shi-works.com/%s"]}' "$key" "$name")
  log "キャッシュをパージ: $body"
  curl -fsS -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/purge_cache" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H 'Content-Type: application/json' \
    --data "$body" | grep -q '"success":true' || { log "パージ失敗"; exit 1; }
}

# 前回より極端に小さい成果物は壊れているとみなしてアップロードしない
guard_size() {
  local file=$1 key=$2 min_ratio=${3:-70}
  local prev now
  prev=$(r2_size "$key")
  now=$(stat -c %s "$file")
  log "サイズ: 今回 $now / 前回 $prev"
  if ((prev > 0 && now * 100 < prev * min_ratio)); then
    log "前回の ${min_ratio}% 未満。中断する（意図した縮小なら FORCE=true で再実行）"
    [[ "${FORCE:-false}" == "true" ]] || exit 1
  fi
}
