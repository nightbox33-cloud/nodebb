#!/usr/bin/env bash
# 01_clone_inventory.sh
#
# Prerequisite step of the audit: enumerate every repo in the zeta-chain
# GitHub org and clone all of them (all branches + all tags), then record the
# exact commit hash + commit date of HEAD for each clone.
#
# Usage:  ./01_clone_inventory.sh [DEST]        (DEST default: /tmp/zeta)
# Output: $DEST/INVENTORY.tsv  and  $DEST/heads.txt
#
# Requires: git, gh (authenticated), python3.

set -euo pipefail

DEST="${1:-/tmp/zeta}"
mkdir -p "$DEST"

# ---- 1. enumerate the org (paginated) -------------------------------------
gh api 'orgs/zeta-chain/repos?per_page=100' --paginate \
  -q '.[] | "\(.name)\t\(.private)\t\(.archived)\t\(.pushed_at)"' \
  > "$DEST/INVENTORY.tsv"

cut -f1 "$DEST/INVENTORY.tsv" | sort > "$DEST/_all_repos.txt"
echo "repos in org: $(wc -l < "$DEST/_all_repos.txt")"

# ---- 2. clone everything (all branches, all tags) -------------------------
while read -r repo; do
  [ -z "$repo" ] && continue
  if [ -d "$DEST/$repo/.git" ]; then
    echo "SKIP (present) $repo"
    continue
  fi
  if git clone --quiet --no-single-branch \
       "https://github.com/zeta-chain/$repo.git" "$DEST/$repo" 2>/dev/null; then
    echo "OK   $repo"
  else
    # empty repos / LFS failures: record, keep going
    echo "FAIL $repo" | tee -a "$DEST/_clone_failures.txt"
  fi
done < "$DEST/_all_repos.txt"

# ---- 3. record exact HEAD hash + date per repo ---------------------------
: > "$DEST/heads.txt"
while read -r repo; do
  [ -z "$repo" ] && continue
  if [ -d "$DEST/$repo/.git" ]; then
    printf '%s\t%s\t%s\t%s\n' \
      "$repo" \
      "$(git -C "$DEST/$repo" rev-parse HEAD)" \
      "$(git -C "$DEST/$repo" log -1 --format=%cs)" \
      "$(git -C "$DEST/$repo" rev-list --count HEAD)" \
      >> "$DEST/heads.txt"
  else
    printf '%s\tMISSING\t-\t-\n' "$repo" >> "$DEST/heads.txt"
  fi
done < "$DEST/_all_repos.txt"

column -t "$DEST/heads.txt"
echo
echo "clones:    $(ls -d "$DEST"/*/.git 2>/dev/null | wc -l)"
echo "failures:  $([ -f "$DEST/_clone_failures.txt" ] && wc -l < "$DEST/_clone_failures.txt" || echo 0)"
