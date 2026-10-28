#!/usr/bin/env bash
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/scripts/common.sh"
config="$ROOT/config.json"
output="$ROOT/dist"
while (($#)); do
    case $1 in
        --config) config=$(realpath -- "$2"); shift 2 ;;
        --output) output=$(realpath -m -- "$2"); shift 2 ;;
        *) fail "Usage: $0 [--config FILE] [--output NEW_DIRECTORY]" ;;
    esac
done
for tool in jq curl sha256sum tar gzip xargs; do need "$tool"; done
validate_config "$config"
[[ ! -e $output ]] || fail "Output already exists: $output"
for tool in meta-rules-converter geoview geo sing-box mmdbinspect; do need "$tool"; done
workers=${JOBS:-4}
if [[ ! $workers =~ ^[1-9][0-9]?$ ]] || (( workers > 32 )); then fail 'JOBS must be 1-32'; fi
mkdir -p -- "$(dirname -- "$output")" "$ROOT/.cache"
stage=$(mktemp -d "$(dirname -- "$output")/.geodata.XXXXXX")
work=$(mktemp -d "$ROOT/.cache/build.XXXXXX")
trap 'rm -rf -- "$stage" "$work"' EXIT
trap 'printf "Build failed at line %s\n" "$LINENO" >&2' ERR
bash "$ROOT/scripts/download-data.sh" "$config" "$work/input"
cp -- "$work/input/geoip.dat" "$stage/geoip.dat"
cp -- "$work/input/geosite.dat" "$stage/geosite.dat"
cp -- "$work/input/asn.dat" "$stage/geolite2-asn.mmdb"
cp -- "$work/input/sources.json" "$stage/sources.json"
cp -- "$config" "$stage/build-config.json"
cp -- "$ROOT/tools.json" "$stage/tools.json"
for kind in geoip geosite; do
    codes=$(jq -r --arg kind "lite_$kind" '.[$kind] | join(",")' "$config")
    geoview -type "$kind" -action convert -input "$stage/$kind.dat" -list "$codes" \
        -format "$kind" -regex -output "$stage/$kind-lite.dat"
    list_codes "$kind" "$stage/$kind-lite.dat" > "$work/$kind-lite.codes"
    jq -r --arg kind "lite_$kind" '.[$kind][]' "$config" | sort -u > "$work/wanted.codes"
    diff -u "$work/wanted.codes" "$work/$kind-lite.codes"
    mkdir -p "$work/srs/$kind" "$work/json/$kind"
    printf 'Converting all %s classifications\n' "$kind"
    meta-rules-converter "$kind" -f "$stage/$kind.dat" -o "$work/json/$kind" -t sing-box
    # Recompile the textual output with the pinned official sing-box codec.
    find "$work/json/$kind" -type f -name '*.srs' -delete
    if [[ $kind == geoip ]]; then
        list_codes geoip "$stage/geoip.dat" > "$work/geoip.codes"
    fi
done
geo convert site -i v2ray -o sing -f "$stage/geosite-lite.db" "$stage/geosite-lite.dat"
geo convert site -i v2ray -o sing -f "$work/geosite.db" "$stage/geosite.dat" > "$work/geo.log"
list_codes geosite "$work/geosite.db" > "$work/geosite.codes"
list_codes geosite "$stage/geosite.dat" > "$work/geosite-base.codes"
list_codes geosite "$stage/geosite-lite.db" > "$work/geosite-lite-all.codes"
for kind in geoip geosite; do
    if grep -Ev '^[a-z0-9][a-z0-9_.!@+-]*$' "$work/$kind.codes"; then fail "Invalid $kind category name"; fi
    find "$work/json/$kind" -type f -name '*.json' -printf '%f\n' | sed 's/\.json$//' | sort > "$work/generated.codes"
    diff -u "$work/$kind.codes" "$work/generated.codes"
done
printf 'Reading and validating ASN records\n'
mmdbinspect -jsonl -db "$stage/geolite2-asn.mmdb" ::/0 |
    jq -n --argjson wanted "$(jq '.asn_rules' "$config")" '
      reduce inputs as $row ({count:0, selected:{}};
        if ($row.record.autonomous_system_number|type) != "number" or $row.record.autonomous_system_number <= 0
          then error("Invalid ASN record") else .count += 1 end |
        $row.record.autonomous_system_number as $asn |
        if ($wanted | index($asn)) != null then .selected["AS\($asn)"] += [$row.network] else . end)
      | if .count > 0 then . else error("Empty ASN database") end
    ' > "$work/asns.json"
mkdir -p "$work/json/asn" "$work/srs/asn"
while read -r asn; do
    jq -e --arg name "AS$asn" '.selected[$name] | length > 0' "$work/asns.json" >/dev/null || fail "Missing AS$asn"
    jq --arg name "AS$asn" '{version:2,rules:[{ip_cidr:(.selected[$name]|sort|unique)}]}' \
        "$work/asns.json" > "$work/json/asn/AS$asn.json"
done < <(jq -r '.asn_rules[]' "$config")
export stage work
# Worker expressions expand in the child shell.
# shellcheck disable=SC2016
find "$work/json" -type f -name '*.json' -print0 | sort -z |
    xargs -0 -r -P "$workers" -I '{}' bash -euo pipefail -c '
      relative=${1#"$work/json/"}
      jq -cf "$ROOT/scripts/normalize.jq" "$1" > "$1.normalized"
      mv -- "$1.normalized" "$1"
      sing-box rule-set compile "$1" -o "$work/srs/${relative%.json}.srs" >/dev/null
    ' _ '{}'
jq -n '[inputs | input_filename as $path | ($path|capture("/json/(?<kind>[^/]+)/(?<category>[^/]+)\\.json$")) as $name |
    {kind:$name.kind, category:$name.category, path:("srs/"+$name.kind+"/"+$name.category+".srs"),
     entries:([.rules[] | (.ip_cidr//[]),(.domain//[]),(.domain_suffix//[]),(.domain_keyword//[]),(.domain_regex//[]) | if type=="array" then length else 1 end] | add)}]
    | sort_by(.kind,.category)' "$work"/json/*/*.json > "$stage/rules-index.json"
cp -- "$ROOT/README.md" "$stage/"
bash "$ROOT/scripts/package.sh" "$stage" "$work"
# Inventory excludes the manifest and checksum files to avoid circular hashes.
(cd "$stage" && find . -type f -printf '%P\t%s\n' | sort) > "$work/sizes.tsv"
(cd "$stage" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$work/hashes.txt"
jq -Rn '[inputs|split("\t")|{key:.[0],value:(.[1]|tonumber)}]|from_entries' "$work/sizes.tsv" > "$work/sizes.json"
jq -Rn --slurpfile sizes "$work/sizes.json" '[inputs|capture("^(?<sha>[a-f0-9]{64})  ./+(?<path>.+)$")|
    {key:.path,value:{sha256:.sha,size:$sizes[0][.path]}}]|from_entries' "$work/hashes.txt" > "$work/files.json"
epoch=${SOURCE_DATE_EPOCH:-$(date +%s)}
[[ $epoch =~ ^[0-9]+$ ]] || fail 'SOURCE_DATE_EPOCH must be Unix seconds'
jq -n --arg built "$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)" \
    --arg commit "${GITHUB_SHA:-}" --slurpfile sources "$stage/sources.json" \
    --slurpfile tools "$ROOT/tools.json" --slurpfile rules "$stage/rules-index.json" \
    --slurpfile files "$work/files.json" --slurpfile asns "$work/asns.json" \
    --argjson ip_count "$(wc -l < "$work/geoip.codes")" --argjson site_count "$(wc -l < "$work/geosite-base.codes")" \
    '{schema:1,builder:"shell",builder_commit:$commit,built_at:$built,srs_version:2,inputs:$sources[0],tools:$tools[0],
      geoip_categories:$ip_count,geosite_categories:$site_count,asn_records:$asns[0].count,rules:$rules[0],files:$files[0]}' > "$stage/manifest.json"
(cd "$stage" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's/  .\//  /' > "$work/checksums")
mv -- "$work/checksums" "$stage/SHA256SUMS"
while IFS= read -r -d '' file; do
    (cd "$stage" && sha256sum "${file##*/}") > "$file.sha256sum"
done < <(find "$stage" -maxdepth 1 -type f ! -name SHA256SUMS -print0)
bash "$ROOT/verify.sh" "$stage"
[[ ! -e $output ]] || fail "Output appeared during build: $output"
mv -T -- "$stage" "$output"
printf 'Completed: %s\n' "$output"
