#!/usr/bin/env bash
# Called by build.sh inside its private working directory.
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
config=$1 dest=$2
mkdir -p "$dest"
printf '{}\n' > "$dest/commits.json"
: > "$dest/inputs.jsonl"
for kind in geoip geosite asn; do
    IFS=$'\t' read -r repo ref file < <(jq -r --arg kind "$kind" '.[$kind] | [.repository,.ref,.file] | @tsv' "$config")
    key="$repo@$ref"
    commit=$(jq -r --arg key "$key" '.[$key] // empty' "$dest/commits.json")
    if [[ -z $commit ]]; then
        if [[ $ref =~ ^[a-f0-9]{40}$ ]]; then
            commit=$ref
        else
            headers=()
            if [[ -n ${GITHUB_TOKEN:-} ]]; then headers=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
            curl --fail --silent --show-error --retry 3 --connect-timeout 20 --max-time 180 \
                --proto '=https' "${headers[@]}" \
                "https://api.github.com/repos/$repo/commits/$ref" -o "$dest/commit.json"
            commit=$(jq -er '.sha | select(test("^[a-f0-9]{40}$"))' "$dest/commit.json")
        fi
        jq --arg key "$key" --arg commit "$commit" '.[$key]=$commit' "$dest/commits.json" > "$dest/commits.new"
        mv -- "$dest/commits.new" "$dest/commits.json"
    fi
    url="https://raw.githubusercontent.com/$repo/$commit/$file"
    printf 'Downloading %s/%s @ %.12s\n' "$repo" "$file" "$commit"
    fetch "$url" "$dest/$kind.dat"
    fetch "$url.sha256sum" "$dest/$kind.sha256sum"
    read -r expected _ < "$dest/$kind.sha256sum"
    actual=$(checksum "$dest/$kind.dat")
    [[ ${expected,,} == "$actual" ]] || fail "Upstream SHA256 mismatch: $repo/$file"
    jq -n --arg kind "$kind" --arg repo "$repo" --arg commit "$commit" --arg file "$file" \
        --arg url "$url" --arg sha "$actual" --argjson size "$(stat -c %s "$dest/$kind.dat")" \
        '{kind:$kind,repository:$repo,commit:$commit,file:$file,url:$url,sha256:$sha,size:$size}' >> "$dest/inputs.jsonl"
done
jq -s '.' "$dest/inputs.jsonl" > "$dest/sources.json"
