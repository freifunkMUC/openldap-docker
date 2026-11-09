#!/usr/bin/env bash
# Reports new OpenLDAP upstream releases and open Debian security-tracker CVEs
# as GitHub issues. Visibility only: the image stays the Debian package.
#
# Sources:
#   - upstream: release tags OPENLDAP_REL_ENG_2_<minor>_<patch> in the official
#     repository (git ls-remote; stable, no scraping), newest of the 2.6 (LTS)
#     branch and newest of the 2.7+ (feature) branches
#   - installed: dpkg-query in the published image
#   - Debian: security-tracker JSON, package openldap, release trixie
# One issue per upstream version and one per CVE. An issue is looked up in all
# states, so closing it silences it. Fails on any source error (no silent green).
#
# Environment: IMAGE (required), DRY_RUN=1 (print instead of creating issues),
# IGNORE_URGENCY (default "unimportant", Debian's own "no fix needed").
# Needs: git, curl, jq, docker, gh (not in a dry run).
set -euo pipefail

: "${IMAGE:?IMAGE is required}"
IGNORE_URGENCY=${IGNORE_URGENCY:-unimportant}
DRY_RUN=${DRY_RUN:-0}
UPSTREAM=https://git.openldap.org/openldap/openldap.git
TRACKER=https://security-tracker.debian.org/tracker

# Whether an issue whose title starts with $1 exists (any state).
exists() {
  local n
  n=$(gh issue list --state all --limit 100 --search "$1 in:title" --json title \
        --jq "[.[] | select(.title | startswith(\"$1\"))] | length")
  [ "$n" -gt 0 ]
}

create() { # title, body
  if [ "$DRY_RUN" = 1 ]; then
    printf 'DRY RUN, would create issue: %s\n' "$1"
  else
    gh issue create --title "$1" --body "$2"
  fi
}

# Newest version by sort -V; fails on empty input.
newest() { sort -V | tail -n1 | grep .; }

tags=$(git ls-remote --tags --refs "$UPSTREAM" 'OPENLDAP_REL_ENG_2_*' | sed 's|.*refs/tags/OPENLDAP_REL_ENG_||')
[ -n "$tags" ] || { echo "no tags from $UPSTREAM" >&2; exit 1; }
lts=$(grep -E '^2_6_[0-9]+$' <<<"$tags" | tr _ . | newest) || { echo "no 2.6 release tag" >&2; exit 1; }
feature=$(grep -E '^2_([7-9]|[1-9][0-9])_[0-9]+$' <<<"$tags" | tr _ . | newest || true)

installed=$(docker run --rm --entrypoint dpkg-query "$IMAGE" -W -f '${Version}' slapd)
[ -n "$installed" ] || { echo "no slapd version in $IMAGE" >&2; exit 1; }
installed_up=$(sed 's/^[0-9]*://; s/[+~-].*//' <<<"$installed")

json=$(mktemp); trap 'rm -f "$json"' EXIT
curl -fsS --retry 3 --max-time 120 --compressed -o "$json" "$TRACKER/data/json"
jq -e '.openldap' "$json" >/dev/null || { echo "package openldap missing in the tracker data" >&2; exit 1; }
open_cves=$(jq -r --arg ign "$IGNORE_URGENCY" '
  .openldap | to_entries[]
  | select(.value.releases.trixie.status? and .value.releases.trixie.status != "resolved"
           and .value.releases.trixie.urgency != $ign)
  | [.key, .value.releases.trixie.status, .value.releases.trixie.urgency] | @tsv' "$json")

echo "image: slapd $installed (upstream $installed_up); upstream LTS $lts, feature ${feature:-none}"
echo "open trixie CVEs (urgency not $IGNORE_URGENCY): $(grep -c . <<<"$open_cves" || true)"

for v in $lts $feature; do
  # Only versions newer than the one in the image.
  [ "$(printf '%s\n%s\n' "$installed_up" "$v" | sort -V | tail -n1)" = "$v" ] && [ "$v" != "$installed_up" ] || continue
  prefix="OpenLDAP $v released"
  if exists "$prefix"; then echo "already reported: $v"; continue; fi
  tag="OPENLDAP_REL_ENG_${v//./_}"
  branch=LTS; case $v in 2.6.*) ;; *) branch=feature ;; esac
  body="OpenLDAP $v ($branch branch) was tagged upstream. The image has \`$installed\` from Debian trixie.

- Changes: https://git.openldap.org/openldap/openldap/-/blob/$tag/CHANGES
- Announcements: https://www.openldap.org/software/release/announce.html
- Debian tracker: https://tracker.debian.org/pkg/openldap
- Debian security tracker: $TRACKER/source-package/openldap

Debian backports security fixes into its own version, so a newer upstream release is not itself a reason to act. Check the CHANGES for security fixes and the security tracker for the status in trixie. Close this issue when done; it is not reported again.
Open CVEs in trixie (urgency other than $IGNORE_URGENCY): $(grep -c . <<<"$open_cves" || true)"
  create "$prefix (image: $installed)" "$body"
done

while IFS=$'\t' read -r cve status urgency; do
  [ -n "$cve" ] || continue
  prefix="Debian trixie: $cve open in openldap"
  if exists "$prefix"; then echo "already reported: $cve"; continue; fi
  create "$prefix ($urgency)" "Debian security tracker lists $cve for openldap in trixie as \`$status\`, urgency \`$urgency\`. The image has \`$installed\`.

- $TRACKER/$cve
- $TRACKER/source-package/openldap

Close this issue once it is resolved or judged irrelevant; it is not reported again."
done <<<"$open_cves"
