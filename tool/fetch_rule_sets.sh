#!/usr/bin/env bash
# Downloads the rule sets listed in rule_sets.txt. CI runs this before building,
# so each build ships current data and the repository stays free of binaries.
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
  curl -fsSL --retry 3 -o "$directory/$name.srs" \
    "https://raw.githubusercontent.com/SagerNet/$repository/rule-set/$name.srs"
done <"$list"
