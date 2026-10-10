# shellcheck shell=bash disable=SC2034
# Mapterhorn ミラーの設定（mapterhorn-plan.sh / mirror-mapterhorn.sh から source する）

MAPTERHORN_BASE=https://download.mapterhorn.com
# R2 のキーの接頭辞。ファイル名は上流と同じにしておく（公式ミラー登録をできるように）
MAPTERHORN_PREFIX=pmtiles/mapterhorn
# 日本の範囲（与那国島〜南鳥島、沖ノ鳥島〜宗谷岬）。min_lon,min_lat,max_lon,max_lat
# ローカル試験では狭い範囲に替えられる（planet-japan の切り出し範囲と、対象サブピラミッドの選択の両方に効く）
: "${JAPAN_BBOX:=122.9,20.4,154.0,45.6}"
