#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MIN_AGE_DAYS="${COREAGENT_MIN_RELEASE_AGE_DAYS:-7}"
PACKAGE="$ROOT/Package.swift"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not available; skipping minimum release age check"
  exit 0
fi

while IFS= read -r version; do
  url=$(grep -B5 "exact: \"$version\"" "$PACKAGE" | grep 'url:' | tail -1 | sed -E 's/.*url: "([^"]+)".*/\1/')
  if [[ -n "$url" && "$url" == *github.com* ]]; then
    repo=$(echo "$url" | sed -E 's#https://github.com/([^/]+/[^/.]+).*#\1#')
    published=$(gh api "repos/${repo}/releases/tags/${version}" --jq '.published_at' 2>/dev/null || echo "")
    if [[ -n "$published" && "$published" != "null" ]]; then
      published_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "${published}" "+%s" 2>/dev/null || date -d "$published" "+%s" 2>/dev/null || echo 0)
      now_epoch=$(date "+%s")
      age_days=$(( (now_epoch - published_epoch) / 86400 ))
      if [[ "$age_days" -lt "$MIN_AGE_DAYS" ]]; then
        echo "Dependency ${repo}@${version} is only ${age_days} day(s) old (minimum ${MIN_AGE_DAYS})"
        exit 1
      fi
      echo "OK: ${repo}@${version} (${age_days} days old)"
    fi
  fi
done < <(grep -oE 'exact: "[^"]+"' "$PACKAGE" | sed -E 's/exact: "([^"]+)"/\1/' || true)

echo "Minimum release age check passed"
