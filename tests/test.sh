#!/usr/bin/env bash
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/../scripts/common.sh"
work=$(mktemp -d "$ROOT/.cache/test.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
for script in "$ROOT"/*.sh "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do bash -n "$script"; done
validate_config "$ROOT/config.json"
for expression in '.lite_geoip=["cn","cn"]' '.geoip.repository="other/source"' '.asn_rules=[0]' '.lite_geosite=["../escape"]'; do
    jq "$expression" "$ROOT/config.json" > "$work/bad.json"
    if (validate_config "$work/bad.json") >/dev/null 2>&1; then fail "Invalid config accepted: $expression"; fi
done
mkdir "$work/keep"
printf 'unchanged' > "$work/keep/file"
if bash "$ROOT/build.sh" --output "$work/keep" >/dev/null 2>&1; then fail 'Existing output accepted'; fi
[[ $(cat "$work/keep/file") == unchanged ]] || fail 'Existing output modified'
mkdir "$work/bin"
cat > "$work/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
url= out= auth=
while (($#)); do
    case $1 in
        -o) out=$2; shift 2 ;;
        -H) auth=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
printf '%s\n' "$url" >> "$CURL_LOG"
if [[ $url == https://api.github.com/* ]]; then
    [[ $auth == 'Authorization: Bearer fake-token' ]]
    printf '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' > "$out"
else
    [[ -z $auth && $url == */aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/* ]]
    if [[ $url == *.sha256sum ]]; then
        if [[ ${BAD_HASH:-0} == 1 ]]; then printf '%064d  data\n' 0 > "$out"
        else printf 'fixture' | sha256sum > "$out"; fi
    else printf 'fixture' > "$out"; fi
fi
MOCK
chmod +x "$work/bin/curl"
export CURL_LOG="$work/curl.log" GITHUB_TOKEN=fake-token
PATH="$work/bin:$PATH" bash "$ROOT/scripts/download-data.sh" "$ROOT/config.json" "$work/input" >/dev/null
[[ $(grep -c 'api.github.com' "$CURL_LOG") == 2 ]] || fail 'A shared source was resolved twice'
jq -e 'length==3 and all(.[]; .commit=="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")' "$work/input/sources.json" >/dev/null
if PATH="$work/bin:$PATH" BAD_HASH=1 bash "$ROOT/scripts/download-data.sh" "$ROOT/config.json" "$work/bad-input" >/dev/null 2>&1; then fail 'Bad upstream checksum accepted'; fi
unset GITHUB_TOKEN
mkdir -p "$work/package-stage" "$work/package-work/srs/geoip" "$work/package-work/srs/geosite" "$work/package-work/srs/asn"
printf 'rule\n' > "$work/package-work/srs/geoip/cn.srs"
printf 'rule\n' > "$work/package-work/srs/geoip/us.srs"
printf 'rule\n' > "$work/package-work/srs/geosite/example.srs"
printf 'rule\n' > "$work/package-work/srs/asn/AS13335.srs"
cat > "$work/package-stage/rules-index.json" <<'JSON'
[{"kind":"geoip","category":"cn","path":"srs/geoip/cn.srs"},
 {"kind":"geoip","category":"us","path":"srs/geoip/us.srs"},
 {"kind":"geosite","category":"example","path":"srs/geosite/example.srs"},
 {"kind":"asn","category":"AS13335","path":"srs/asn/AS13335.srs"}]
JSON
printf '{"lite_geoip":["cn"]}\n' > "$work/package-stage/build-config.json"
printf 'example\n' > "$work/package-work/geosite-lite-all.codes"
for name in sources.json tools.json; do printf '{}\n' > "$work/package-stage/$name"; done
printf 'fixture\n' > "$work/package-stage/README.md"
bash "$ROOT/scripts/package.sh" "$work/package-stage" "$work/package-work"
[[ -f $work/package-stage/lanboat-allinone-rules.tar.gz && -f $work/package-stage/lanboat-allinone-rules-lite.tar.gz ]] || fail 'Missing rule archives'
[[ ! -e $work/package-stage/sing-box-rules.tar.gz && ! -d $work/package-stage/srs ]] || fail 'Unexpected standalone rules'
tar -xOzf "$work/package-stage/lanboat-allinone-rules.tar.gz" ./rules-index.json | jq -e 'length==4' >/dev/null
tar -xOzf "$work/package-stage/lanboat-allinone-rules-lite.tar.gz" ./rules-index.json |
    jq -e 'length==3 and all(.[]; .category != "us")' >/dev/null
if [[ ${1:-} == --integration ]]; then
    for tool in geoview geo meta-rules-converter sing-box; do need "$tool"; done
    cp -- "$ROOT/tests/fixtures/geosite.dat" "$work/sites.dat"
    geoview -type geosite -action convert -input "$work/sites.dat" -list fixture -format geosite -regex -output "$work/lite.dat"
    [[ $(list_codes geosite "$work/lite.dat") == fixture ]] || fail 'DAT selection failed'
    meta-rules-converter geosite -f "$work/lite.dat" -o "$work/rules" -t sing-box
    jq -e 'def array: if type=="array" then . else [.] end;
        .rules[0] | (.domain|array)==["exact.test"] and (.domain_suffix|array)==["suffix.test"]
        and (.domain_keyword|array)==["needle"] and (.domain_regex|array)==["^regex[0-9]+\\.test$"]' "$work/rules/fixture.json" >/dev/null
    [[ -s $work/rules/fixture@cn.json ]] || fail 'Attribute subset lost'
    sing-box rule-set compile "$work/rules/fixture.json" -o "$work/fixture.srs" >/dev/null
    for host in suffix.test www.suffix.test exact.test needle.example regex12.test; do
        result=$(sing-box rule-set match -f binary "$work/fixture.srs" "$host" 2>&1)
        [[ $result == *'match rules.'* ]] || fail "Missing match: $host"
    done
    result=$(sing-box rule-set match -f binary "$work/fixture.srs" notsuffix.test 2>&1)
    [[ -z $result ]] || fail 'Suffix boundary changed'
    geo convert site -i v2ray -o sing -f "$work/lite.db" "$work/lite.dat" >/dev/null
    [[ $(list_codes geosite "$work/lite.db" | wc -l) == 2 ]] || fail 'Legacy DB lost attributes'
    cp -- "$ROOT/tests/fixtures/geoip.dat" "$work/ip.dat"
    geoview -type geoip -action convert -input "$work/ip.dat" -list cn -format geoip -output "$work/ip-lite.dat"
    meta-rules-converter geoip -f "$work/ip-lite.dat" -o "$work/ip-rules" -t sing-box
    jq -e '.rules[0].ip_cidr|index("1.2.3.0/24")!=null and index("2001:db8::/32")!=null' "$work/ip-rules/cn.json" >/dev/null
fi
printf 'Shell tests passed%s\n' "${1:+ ($1)}"
