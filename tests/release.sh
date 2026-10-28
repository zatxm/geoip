#!/usr/bin/env bash
# Exercise publication without contacting GitHub.
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/../scripts/common.sh"
artifact=$(realpath -- "${1:-$ROOT/dist}")
work=$(mktemp -d "$ROOT/.cache/release-test.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == release ]]
printf '%s\n' "$2" >> "$GH_CALL_LOG"
if [[ $2 == upload && ${GH_FAIL:-} == upload ]]; then exit 7; fi
if [[ $2 == create ]]; then
    while (($#)); do
        if [[ $1 == --notes-file ]]; then grep -q 'lanboat-allinone-rules.tar.gz' "$2"; break; fi
        shift
    done
fi
MOCK
chmod +x "$work/bin/gh"
export GH_CALL_LOG="$work/calls" GH_REPO=example/offline-test GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if PATH="$work/bin:$PATH" GH_FAIL=upload bash "$ROOT/release.sh" "$artifact" > "$work/failure.log" 2>&1; then
    fail 'Publication accepted an upload failure'
fi
[[ $(paste -sd, "$GH_CALL_LOG") == create,upload,delete ]] || fail 'Failed draft was not cleaned up correctly'
: > "$GH_CALL_LOG"
PATH="$work/bin:$PATH" bash "$ROOT/release.sh" "$artifact" > "$work/success.log" 2>&1
[[ $(paste -sd, "$GH_CALL_LOG") == create,upload,edit ]] || fail 'Release was published before upload'
printf 'Offline release tests passed (no GitHub requests)\n'
