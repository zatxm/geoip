#!/usr/bin/env bash
# Compare two builds by the decoded semantics inside their rule archives.
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/../scripts/common.sh"
before=$(realpath -- "$1") after=$(realpath -- "$2")
work=$(mktemp -d "$ROOT/.cache/compare.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
for file in geoip.dat geosite.dat geolite2-asn.mmdb; do cmp -- "$before/$file" "$after/$file"; done
jq -r '.[].path' "$before/rules-index.json" | sort > "$work/before.paths"
jq -r '.[].path' "$after/rules-index.json" | sort > "$work/after.paths"
diff -u "$work/before.paths" "$work/after.paths"
for version in before after; do
    base=${!version}
    mkdir "$work/$version"
    tar -xzf "$base/lanboat-allinone-rules.tar.gz" -C "$work/$version"
done
export work
# Worker expressions expand in the child shell.
# shellcheck disable=SC2016
xargs -r -d '\n' -P "${JOBS:-4}" -I '{}' bash -euo pipefail -c '
    path=$1
    prefix="$work/${path//\//_}"
    for version in before after; do
        sing-box rule-set decompile "$work/$version/$path" -o "$prefix.$version.json" >/dev/null 2>&1
        jq -Sc -f "$ROOT/scripts/normalize.jq" "$prefix.$version.json" > "$prefix.$version.normalized"
    done
    cmp -- "$prefix.before.normalized" "$prefix.after.normalized"
' _ '{}' < "$work/after.paths"
printf 'Compared %s decoded SRS rules and all complete upstream files: identical\n' "$(wc -l < "$work/after.paths")"
