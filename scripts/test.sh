#!/usr/bin/env bash
# 書き込みまで含めた通し試験。本番の前に ① → ② の順に通す。
#
#   docker compose run --rm pipeline scripts/test.sh local   … ① ローカルの S3 互換サーバー（compose の s3）に書く
#   docker compose run --rm pipeline scripts/test.sh r2      … ② 本物の R2 の _test/ 以下に書き、最後に消す
#                                                               （.env に R2_ACCOUNT_ID・AWS_ACCESS_KEY_ID・AWS_SECRET_ACCESS_KEY）
#   WITH_OSM=true … OSM の生成（四国、約 10 分）も行う。既定は省略（アップロードは国土地理院と同じ r2_upload）
#
# ① で手順の誤りを、② で R2 固有の未実装 API（x-amz-tagging-directive など）を見つける。
# どちらもパージはしない。本番キー（pmtiles/...）には書かない。
set -euo pipefail

MODE=${1:?local / r2}
REPO=$(cd "$(dirname "$0")/.." && pwd)
export DRY_RUN=false FORCE=false
: "${WORK_DIR:=/work}"
TESTSRC=$WORK_DIR/testsrc
export WORK_DIR="$WORK_DIR/test-$MODE"
export GITHUB_OUTPUT="$WORK_DIR/github_output"

case "$MODE" in
  local)
    export S3_ENDPOINT=http://s3:7070 AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=localsecret KEY_PREFIX=''
    ;;
  r2)
    unset S3_ENDPOINT
    export KEY_PREFIX=_test/
    : "${R2_ACCOUNT_ID:?.env に R2_ACCOUNT_ID が無い}" "${AWS_ACCESS_KEY_ID:?.env に AWS_ACCESS_KEY_ID が無い}"
    ;;
  *) echo "local / r2 のどちらか" >&2; exit 2 ;;
esac

# shellcheck source=scripts/lib.sh
source "$REPO/scripts/lib.sh"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
fails=0
# check <説明> <コマンド…>: コマンドが成功すれば OK、失敗すれば NG として数える
check() {
  local what=$1
  shift
  if "$@"; then log "OK   $what"; else log "NG   $what"; fails=$((fails + 1)); fi
}
s3() { aws --endpoint-url "$R2_ENDPOINT" "$@"; }
# 直近の実行の GITHUB_OUTPUT の値
out() { awk -F= -v k="$1" '$1==k{v=substr($0, length(k)+2)} END{print v}' "$GITHUB_OUTPUT"; }
run() { : >"$GITHUB_OUTPUT"; "$REPO/scripts/$1" "${@:2}"; }
# キーが無ければ成功
absent() { ! s3 s3api list-objects-v2 --bucket "$R2_BUCKET" --prefix "$1" --query 'Contents[].Key' --output text | grep -qv '^None$'; }

if [[ "$MODE" == local ]]; then
  s3 s3api head-bucket --bucket "$R2_BUCKET" 2>/dev/null || s3 s3api create-bucket --bucket "$R2_BUCKET" >/dev/null
  # 前回の試験の写しが残っていると「初回」にならないので空にする（ローカルの S3 だけ）
  s3 s3 rm "s3://$R2_BUCKET/" --recursive --only-show-errors
fi

# R2 の試験で書いたものは、途中で失敗しても消す
cleanup_r2() {
  [[ "$MODE" == r2 ]] || return 0
  log "== R2 の _test/ を削除"
  s3 s3 rm "s3://$R2_BUCKET/_test/" --recursive --only-show-errors
  s3 s3 rm "s3://$R2_BUCKET/_staging/_test/" --recursive --only-show-errors
}
trap cleanup_r2 EXIT

# ---- 国土地理院（配信元を testsrc の小さい MVT の PMTiles に差し替える）----
log "== 国土地理院"
SAMPLE=$TESTSRC/gsi-sample.pmtiles
if [[ ! -f "$SAMPLE" ]]; then
  install_pmtiles
  mkdir -p "$TESTSRC"
  # 本番の国土地理院 最適化ベクトルタイルから札幌周辺を切り出す（数十 MB。マルチパートアップロードになる大きさ）
  pmtiles extract https://shi-works.com/pmtiles/gsi/optimal_bvmap/optimal_bvmap-v1.pmtiles "$SAMPLE" \
    --bbox=141.2,42.9,141.5,43.2
fi
GSI_KEY="${KEY_PREFIX}pmtiles/gsi/optimal_bvmap/optimal_bvmap-v1.pmtiles"
SRC_URL=http://testsrc/gsi-sample.pmtiles run mirror-gsi.sh
check "初回はアップロードする" [ "$(out updated)" = true ]
check "サイズが一致する" [ "$(r2_size "$GSI_KEY")" = "$(stat -c %s "$SAMPLE")" ]
check "メタデータ source-etag がある" [ -n "$(r2_meta "$GSI_KEY" source-etag)" ]
SRC_URL=http://testsrc/gsi-sample.pmtiles run mirror-gsi.sh
check "2 回目は ETag が同じなのでスキップする" [ "$(out updated)" = false ]
GSI_PREV=$(previous_key "$GSI_KEY")
check "初回は直前の版が無い" absent "$GSI_PREV"

# ---- 直前の版の退避と戻し（国土地理院のキーで試す）----
log "== 直前の版"
r2_upload "$SAMPLE" "$GSI_KEY" '{"test-version":"2"}'
check "上書きの前に直前の版を退避する" [ -n "$(r2_meta "$GSI_PREV" source-etag)" ]
check "本番キーは新しい版になる" [ "$(r2_meta "$GSI_KEY" test-version)" = 2 ]
"$REPO/scripts/rollback.sh" gsi
check "戻すと本番キーが直前の版になる" [ -n "$(r2_meta "$GSI_KEY" source-etag)" ]
check "戻す前の版が直前の版の位置に入る" [ "$(r2_meta "$GSI_PREV" test-version)" = 2 ]
check "戻した後も Content-Type・Cache-Control を保つ" [ "$(s3 s3api head-object --bucket "$R2_BUCKET" --key "$GSI_KEY" \
  --query '[ContentType,CacheControl]' --output text)" = $'application/octet-stream\tpublic, max-age=3600' ]
check "戻すときの一時キーが消えている" absent "_staging/$GSI_KEY.rollback"
"$REPO/scripts/rollback.sh" gsi
check "もう一度戻すと戻す前の版に戻る" [ "$(r2_meta "$GSI_KEY" test-version)" = 2 ]

# ---- Mapterhorn（竹島付近だけ。6-55-24 は 4KB、6-58-22 は 13MB）----
log "== Mapterhorn"
export JAPAN_BBOX=131.5,37.0,132.0,37.5
MH="${KEY_PREFIX}pmtiles/mapterhorn"
run mapterhorn-plan.sh
check "計画が planet-japan と 6-55-24 になる（$(out files)）" [ "$(out files)" = '["planet-japan","6-55-24"]' ]
for name in planet-japan 6-55-24 6-58-22; do
  run mirror-mapterhorn.sh "$name"
  check "$name が本番キーにあり source-md5 が付いている" [ -n "$(r2_meta "$MH/$name.pmtiles" source-md5)" ]
  check "$name の _staging が消えている" absent "_staging/$MH/$name.pmtiles"
done
meta=$(s3 s3api head-object --bucket "$R2_BUCKET" --key "$MH/6-55-24.pmtiles" --query '[ContentType,CacheControl]' --output text)
check "R2 内コピーの後も Content-Type・Cache-Control を保つ（$meta）" [ "$meta" = $'application/octet-stream\tpublic, max-age=3600' ]
run mapterhorn-plan.sh
check "再計画で取り直すものが無い（$(out files)）" [ "$(out files)" = '[]' ]
unset JAPAN_BBOX

# ---- OSM（任意）----
if [[ "${WITH_OSM:-false}" == true ]]; then
  log "== OSM（四国）"
  PBF_URL=https://download.geofabrik.de/asia/japan/shikoku-latest.osm.pbf OSM_BOUNDS=132.0,32.7,134.8,34.6 EXTRA_SOURCES='' \
    run build-osm.sh
  check "OSM をアップロードする" [ "$(out updated)" = true ]
  check "メタデータ planetiler-version がある" \
    [ -n "$(r2_meta "${KEY_PREFIX}pmtiles/osm/openmaptiles-japan.pmtiles" planetiler-version)" ]
fi

# ---- 後片付け（R2 のみ。ローカルは docker compose down -v で消える）----
if [[ "$MODE" == r2 ]]; then
  trap - EXIT
  cleanup_r2
  check "_test/ が残っていない" absent _test/
fi

if ((fails)); then
  log "失敗 $fails 件"
  exit 1
fi
log "すべて OK（$MODE）"
