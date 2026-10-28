#!/usr/bin/env bash
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
for tool in curl jq sha256sum tar; do need "$tool"; done
[[ $(uname -s)/$(uname -m) == Linux/x86_64 ]] || fail 'The pinned build tools currently support Linux x86_64.'
mkdir -p "$TOOLS"
work=$(mktemp -d "$ROOT/.cache/setup.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
while IFS=$'\t' read -r name url sha member; do
    archive="$TOOLS/$name.download"
    # Check the archive on cache hits as well as new downloads.
    if [[ ! -f $archive ]] || [[ $(checksum "$archive") != "$sha" ]]; then
        fetch "$url" "$work/download"
        [[ $(checksum "$work/download") == "$sha" ]] || fail "Tool SHA256 mismatch: $name"
        mv -- "$work/download" "$archive"
    fi
    if [[ $member == - ]]; then
        cp -- "$archive" "$work/binary"
    else
        tar -xOzf "$archive" -- "$member" > "$work/binary"
    fi
    chmod 755 "$work/binary"
    mv -- "$work/binary" "$TOOLS/$name"
done < <(jq -r 'to_entries[] | select(.value.url) | [.key,.value.url,.value.sha256,(.value.member|if . == "" then "-" else . end)] | @tsv' "$ROOT/tools.json")
module=$(jq -r '."meta-rules-converter".module' "$ROOT/tools.json")
if [[ ! -x $TOOLS/meta-rules-converter || ! -f $TOOLS/converter.module || ! -f $TOOLS/converter.sha256 ]] ||
   [[ $(cat "$TOOLS/converter.module") != "$module" ]] ||
   [[ $(checksum "$TOOLS/meta-rules-converter") != "$(cat "$TOOLS/converter.sha256")" ]]; then
    need go
    GOBIN="$work" go install "$module"
    mv -- "$work/meta-rules-converter" "$TOOLS/meta-rules-converter"
    printf '%s\n' "$module" > "$TOOLS/converter.module"
    checksum "$TOOLS/meta-rules-converter" > "$TOOLS/converter.sha256"
fi
printf 'Pinned conversion tools ready: %s\n' "$TOOLS"
