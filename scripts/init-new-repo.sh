#!/usr/bin/env bash
#
# Detach this folder into its own standalone GitHub repository.
#
# The session that generated this project could not create a new GitHub repo
# (its integration is scoped to an existing repo), so run this once on your Mac
# to give Winday Notetaker its own repo.
#
# Usage:
#   cd winday-notetaker
#   ./scripts/init-new-repo.sh [github-owner] [repo-name]
#
# Defaults: owner=flemercier6  repo=winday-notetaker
set -euo pipefail

OWNER="${1:-flemercier6}"
REPO="${2:-winday-notetaker}"

# Run from the project root (parent of scripts/).
cd "$(dirname "$0")/.."

if [ -d .git ]; then
  echo "✋ A .git directory already exists here. Aborting to avoid clobbering it."
  exit 1
fi

echo "▶ Initializing a fresh git repo for ${OWNER}/${REPO}…"
git init -b main
git add .
git commit -m "Initial commit: Winday Notetaker macOS app scaffold"

if command -v gh >/dev/null 2>&1; then
  echo "▶ Creating ${OWNER}/${REPO} on GitHub via gh CLI…"
  gh repo create "${OWNER}/${REPO}" --public --source=. --remote=origin --push
  echo "✅ Done. Repo created and pushed."
else
  echo "ℹ gh CLI not found. Create the repo manually, then run:"
  echo
  echo "    git remote add origin git@github.com:${OWNER}/${REPO}.git"
  echo "    git push -u origin main"
  echo
  echo "  (Create an empty repo first at https://github.com/new — do NOT add a README.)"
fi

echo
echo "Next steps:"
echo "  brew install xcodegen   # if needed"
echo "  xcodegen generate"
echo "  open WindayNotetaker.xcodeproj"
