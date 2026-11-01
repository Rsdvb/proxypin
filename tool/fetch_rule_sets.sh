#!/usr/bin/env bash
# Downloads the rule sets listed in rule_sets.txt and writes index.txt, the names of every
# rule set that can be picked in the app. Those are fetched on first use, so only the
# names ship. CI runs this before building, so each build ships current data and the
# repository stays free of binaries.
# Usage: fetch_rule_sets.sh <directory>
set -euo pipefail

directory="$1"
list="$(dirname "$0")/rule_sets.txt"
mkdir -p "$directory"

while IFS= read -r name || [ -n "$name" ]; do
  name="${name%$'\r'}"
  [ -z "$name" ] && continue
  case "$name" in
    geoip-*) repository=sing-geoip ;;
    *) repository=sing-geosite ;;
  esac
  curl -fsSL --retry 3 --retry-all-errors -o "$directory/$name.srs" \
    "https://raw.githubusercontent.com/SagerNet/$repository/rule-set/$name.srs"
done <"$list"

# Lists file names without downloading them: trees only, no blobs.
# Usage: list_files <repository> <branch> [<directory>/]
list_files() {
  local work
  work="$(mktemp -d)"
  git clone --quiet --depth 1 --filter=blob:none --no-checkout --branch "$2" "https://github.com/$1.git" "$work"
  git -C "$work" ls-tree --name-only HEAD ${3:+"$3"}
  rm -rf "$work"
}

{
  list_files SagerNet/sing-geosite rule-set | sed -n 's/\.srs$//p'
  list_files SagerNet/sing-geoip rule-set | sed -n 's/\.srs$//p'
  list_files KaringX/karing-ruleset sing ACL4SSR/ | sed -n 's#^ACL4SSR/\(.*\)\.srs$#acl-\1#p'
} | LC_ALL=C sort -u >"$directory/index.txt"

if [ "$(wc -l <"$directory/index.txt")" -lt 1000 ]; then
  echo "index.txt looks incomplete" >&2
  exit 1
fi
