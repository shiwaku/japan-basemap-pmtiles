# shellcheck shell=bash disable=SC2034
# Mapterhorn ミラーの設定（mapterhorn-plan.sh / mirror-mapterhorn.sh から source する）

MAPTERHORN_BASE=https://download.mapterhorn.com
# R2 のキーの接頭辞。ファイル名は上流と同じにしておく（公式ミラー登録をできるように）
MAPTERHORN_PREFIX=pmtiles/mapterhorn
# 日本の範囲（与那国島〜南鳥島、沖ノ鳥島〜宗谷岬）。min_lon,min_lat,max_lon,max_lat
JAPAN_BBOX=122.9,20.4,154.0,45.6
