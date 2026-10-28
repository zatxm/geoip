#!/usr/bin/env bash
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/scripts/common.sh"
root=$(realpath -- "${1:-$ROOT/dist}")
for tool in jq sha256sum tar sing-box geoview; do need "$tool"; done
mkdir -p "$ROOT/.cache"
work=$(mktemp -d "$ROOT/.cache/verify.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
jq -e '.schema == 1 and (.files|length)>0 and (.rules|length)>0
    and all(.files|keys[]; test("^[a-zA-Z0-9_.!@+/-]+$") and (split("/")|all(. != "..")) and (startswith("/")|not))
    and all(.rules[].path; test("^srs/(geoip|geosite|asn)/[a-zA-Z0-9_.!@+-]+\\.srs$"))' "$root/manifest.json" >/dev/null
(cd "$root" && sha256sum -c SHA256SUMS > "$work/checksums.log")
jq -r '.files | to_entries[] | "\(.value.sha256)  \(.key)"' "$root/manifest.json" > "$work/manifest-sums"
(cd "$root" && sha256sum -c "$work/manifest-sums" > "$work/manifest.log")
for name in geoip.dat geoip-lite.dat geolite2-asn.mmdb geosite.dat geosite-lite.dat geosite-lite.db; do
    [[ -s $root/$name ]] || fail "Missing artifact: $name"
done
expected_geoip=$(jq -er '.inputs[] | select(.kind == "geoip") | .sha256' "$root/manifest.json")
[[ $(checksum "$root/geoip.dat") == "$expected_geoip" ]] || fail 'Full GeoIP differs from the upstream file'
list_codes geoip "$root/geoip.dat" > "$work/geoip.codes"
[[ $(wc -l < "$work/geoip.codes") == "$(jq -r '.geoip_categories' "$root/manifest.json")" ]] || fail 'Incomplete GeoIP category list'
for kind in geoip geosite; do
    list_codes "$kind" "$root/$kind-lite.dat" > "$work/actual.codes"
    jq -r --arg name "lite_$kind" '.[$name][]' "$root/build-config.json" | sort -u > "$work/expected.codes"
    diff -u "$work/expected.codes" "$work/actual.codes"
done
[[ -z $(find "$root" -type f -name '*.srs' -print -quit) ]] || fail 'Standalone SRS files found in release directory'
list_codes geosite "$root/geosite-lite.db" > "$work/db.codes"
while read -r code; do
    geoview -type geosite -input "$root/geosite-lite.db" -list "$code" -regex -action extract > "$work/db-items"
    [[ -s $work/db-items ]] || fail "Empty legacy category: $code"
done < "$work/db.codes"
jq -Rn '[inputs]|map({key:.,value:true})|from_entries' "$work/db.codes" > "$work/lite-site.json"
for variant in full lite; do
    if [[ $variant == full ]]; then archive=lanboat-allinone-rules.tar.gz; else archive=lanboat-allinone-rules-lite.tar.gz; fi
    dest="$work/$variant"
    mkdir "$dest"
    tar -tzf "$root/$archive" > "$work/members"
    if grep -E '(^/|(^|/)\.\.(/|$))' "$work/members"; then fail "Unsafe archive: $archive"; fi
    tar -tvzf "$root/$archive" > "$work/member-types"
    if grep -Ev '^[d-]' "$work/member-types"; then fail "Archive contains links or special files: $archive"; fi
    tar --no-same-owner --no-same-permissions -xzf "$root/$archive" -C "$dest"
    (cd "$dest" && sha256sum -c SHA256SUMS > "$work/archive-$variant.log")
    if [[ $variant == full ]]; then
        cmp -- "$root/rules-index.json" "$dest/rules-index.json"
    else
        jq --slurpfile config "$root/build-config.json" --slurpfile sites "$work/lite-site.json" '
          [.[] | select(.kind == "asn" or (.kind == "geoip" and (.category as $name | $config[0].lite_geoip|index($name)) != null)
            or (.kind == "geosite" and $sites[0][.category] == true))]
        ' "$root/rules-index.json" > "$work/expected-lite.json"
        cmp -- "$work/expected-lite.json" "$dest/rules-index.json"
    fi
    find "$dest/srs" -type f -name '*.srs' -printf '%P\n' | sort > "$work/actual.rules"
    jq -r '.[].path | ltrimstr("srs/")' "$dest/rules-index.json" | sort > "$work/expected.rules"
    diff -u "$work/expected.rules" "$work/actual.rules"
    if [[ $variant == lite ]]; then
        while read -r path; do cmp -- "$work/full/$path" "$dest/$path"; done < <(jq -r '.[].path' "$dest/rules-index.json")
    fi
done
export work
# Worker expressions expand in the child shell.
# shellcheck disable=SC2016
jq -r '.[].path' "$root/rules-index.json" |
    xargs -r -d '\n' -P "${JOBS:-4}" -I '{}' bash -euo pipefail -c '
        relative=$1
        output="$work/${relative//\//_}.json"
        sing-box rule-set decompile "$work/full/$relative" -o "$output" >/dev/null 2>&1
        jq -e ".version == 2 and (.rules|length)==1" "$output" >/dev/null
    ' _ '{}'
printf 'Verified %s packaged SRS files, full GeoIP and both archives\n' "$(jq length "$root/rules-index.json")"
