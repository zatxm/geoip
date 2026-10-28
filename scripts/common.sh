#!/usr/bin/env bash
# Shared shell utilities. Data files are never executed or sourced.
set -Eeuo pipefail
export LC_ALL=C
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT
TOOLS="$ROOT/.cache/tools"
export PATH="$TOOLS:$PATH"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || fail "Missing command: $1"; }
checksum() { sha256sum -- "$1" | cut -d ' ' -f 1; }
fetch() {
    local url=$1 dest=$2
    curl --fail --location --silent --show-error --retry 3 --connect-timeout 20 \
        --max-time 180 --proto '=https' --proto-redir '=https' "$url" -o "$dest"
    [[ -s $dest ]] || fail "Empty download: $url"
}
list_codes() {
    geoview -type "$1" -input "$2" | sed '1{/^Available codes:$/d;}' | tr '[:upper:]' '[:lower:]' | sort -u
}
validate_config() {
    jq -e '
      def source: (.repository == "Loyalsoldier/geoip" or .repository == "Loyalsoldier/v2ray-rules-dat")
        and (.ref|test("^[A-Za-z0-9_.-]+$")) and (.file|test("^[A-Za-z0-9_.-]+$"));
      def categories: type == "array" and length > 0 and length == (unique|length)
        and all(.[]; type == "string" and test("^[a-z0-9][a-z0-9_.!@+-]*$"));
      (.geoip|source) and (.geosite|source) and (.asn|source)
      and (.lite_geoip|categories) and (.lite_geosite|categories)
      and (.asn_rules|type == "array" and length == (unique|length)
        and all(.[]; type == "number" and . >= 1 and . <= 4294967295 and floor == .))
    ' "$1" >/dev/null || fail 'Invalid config.json'
}
