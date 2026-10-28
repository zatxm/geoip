#!/usr/bin/env bash
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
stage=$1 work=$2
for variant in full lite; do
    dest="$work/bundle-$variant"
    mkdir -p "$dest"
    if [[ $variant == full ]]; then
        cp -- "$stage/rules-index.json" "$dest/rules-index.json"
        filename=lanboat-allinone-rules.tar.gz
    else
        jq -Rn '[inputs]|map({key:.,value:true})|from_entries' "$work/geosite-lite-all.codes" > "$work/lite-site.json"
        jq --slurpfile config "$stage/build-config.json" --slurpfile sites "$work/lite-site.json" '
          [.[] | select(.kind == "asn" or (.kind == "geoip" and (.category as $name | $config[0].lite_geoip|index($name)) != null)
            or (.kind == "geosite" and $sites[0][.category] == true))]
        ' "$stage/rules-index.json" > "$dest/rules-index.json"
        filename=lanboat-allinone-rules-lite.tar.gz
    fi
    while read -r relative; do
        mkdir -p "$dest/$(dirname -- "$relative")"
        cp -- "$work/$relative" "$dest/$relative"
    done < <(jq -r '.[].path' "$dest/rules-index.json")
    cp -- "$stage/sources.json" "$stage/build-config.json" "$stage/tools.json" "$stage/README.md" "$dest/"
    (cd "$dest" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sed 's/  .\//  /' > "$work/bundle-sums")
    cp -- "$work/bundle-sums" "$dest/SHA256SUMS"
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$dest" -cf - . |
        gzip -n -9 > "$stage/$filename"
done
