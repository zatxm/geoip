#!/usr/bin/env bash
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/scripts/common.sh"
root=$(realpath -- "${1:-$ROOT/dist}")
need gh
[[ -n ${GH_REPO:-} && -n ${GITHUB_SHA:-} ]] || fail 'GH_REPO and GITHUB_SHA are required.'
work=$(mktemp -d "$ROOT/.cache/release.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
bash "$ROOT/verify.sh" "$root"
tag="$(TZ=Asia/Shanghai date +'%Y%m%d-%H%M%S')-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
title="Rules $(TZ=Asia/Shanghai date +'%Y-%m-%d %H:%M') UTC+8"
jq -r '
  "构建时间：\(.built_at)\n\nGeoIP：\(.geoip_categories)类；GeoSite：\(.geosite_categories)类；SRS：\(.rules|length)份。\n",
  "适用于sing-box，请下载lanboat-allinone-rules.tar.gz或lanboat-allinone-rules-lite.tar.gz。DAT/DB/MMDB为兼容或查询格式。\n",
  "校验见SHA256SUMS；精简版保留所选分类的完整数据。"
' "$root/manifest.json" > "$work/notes.md"
gh release create "$tag" --draft --target "$GITHUB_SHA" --title "$title" --notes-file "$work/notes.md"
# Only a release created by this invocation can be cleaned up after a failure.
trap 'gh release delete "$tag" --yes --cleanup-tag || true' ERR
mapfile -d '' assets < <(find "$root" -maxdepth 1 -type f -print0 | sort -z)
gh release upload "$tag" "${assets[@]}"
gh release edit "$tag" --draft=false --latest
trap - ERR
printf 'Published release: %s\n' "$tag"
