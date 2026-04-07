#!/bin/bash

# --- Colors ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- Defaults ---
ORG_NAME="KoalaVim"
ACTIONS_REPO="KoalaVim/actions-internal"
TRACKING_ISSUE="1"
PROTOCOL="ssh"
SSH_ALIAS="github.com"
ACTIONS_BRANCH="master"

usage() {
    echo -e "${YELLOW}Usage:${NC} $0 [-o org] [-i issue_id] [-p protocol] [-a alias] <user/repo>"
    exit 1
}

while getopts "o:i:p:a:" opt; do
    case $opt in
        o) ORG_NAME="$OPTARG" ;;
        i) TRACKING_ISSUE="$OPTARG" ;;
        p) PROTOCOL="$OPTARG" ;;
        a) SSH_ALIAS="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

SOURCE_REPO=$1
if [ -z "$SOURCE_REPO" ]; then usage; fi

REPO_NAME=$(echo "$SOURCE_REPO" | cut -d'/' -f2)
TEMP_DIR="${REPO_NAME}-migration"

echo -e "${CYAN}------------------------------------------------------------${NC}"
echo -e "🚀 ${CYAN}Migrating:${NC} $SOURCE_REPO ${CYAN}→${NC} $ORG_NAME/$REPO_NAME"
echo -e "${CYAN}------------------------------------------------------------${NC}"

# 0. Pre-cleanup
if [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
fi

# 1. Clone Source
echo -e "📥 ${BLUE}Cloning source...${NC}"
git clone --quiet "https://github.com/$SOURCE_REPO.git" "$TEMP_DIR"
cd "$TEMP_DIR" || exit

# 2. Get Upstream Info
echo -e "🔍 ${BLUE}Fetching upstream information...${NC}"
UPSTREAM_FULL_NAME=$(gh repo view "$SOURCE_REPO" --json parent --template '{{.parent.owner.login}}/{{.parent.name}}' 2>/dev/null)
if [ -z "$UPSTREAM_FULL_NAME" ] || [ "$UPSTREAM_FULL_NAME" == "/" ]; then
    echo -e "${RED}❌ Error: Could not find upstream parent.${NC}"
    exit 1
fi
echo -e "   ${GREEN}✓${NC} Upstream: $UPSTREAM_FULL_NAME"

# 3. Create Org Repo
echo -e "📦 ${BLUE}Preparing organization repository...${NC}"
if ! gh repo view "$ORG_NAME/$REPO_NAME" >/dev/null 2>&1; then
    gh repo create "$ORG_NAME/$REPO_NAME" --public -y >/dev/null
    echo -e "   ${GREEN}✓${NC} Created $ORG_NAME/$REPO_NAME"
else
    echo -e "   ${YELLOW}ℹ${NC} Repository already exists, skipping creation."
fi

# 4. Generate Sync Workflow
echo -e "🤖 ${BLUE}Generating Sync Workflow (using @$ACTIONS_BRANCH)...${NC}"
mkdir -p .github/workflows
cat <<EOF > .github/workflows/sync.yml
name: Sync
on:
  schedule:
    - cron: '0 0 * * 0'
  workflow_dispatch:

jobs:
  run-sync:
    uses: $ACTIONS_REPO/.github/workflows/rebase-plugin.yml@$ACTIONS_BRANCH
    with:
      upstream_repo: "$UPSTREAM_FULL_NAME"
      plugin_name: "$REPO_NAME"
      tracking_issue_number: "$TRACKING_ISSUE"
    secrets:
      KOALA_APP_ID: \${{ secrets.KOALA_APP_ID }}
      KOALA_APP_PRIVATE_KEY: \${{ secrets.KOALA_APP_PRIVATE_KEY }}
EOF

# 5. Setup Remote URL
if [ "$PROTOCOL" == "ssh" ]; then
    DEST_URL="git@$SSH_ALIAS:$ORG_NAME/$REPO_NAME.git"
else
    DEST_URL="https://github.com/$ORG_NAME/$REPO_NAME.git"
fi

# 6. Commit and Push
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")
git add .github/workflows/sync.yml
git commit -m "chore: add auto-sync workflow" --quiet

git remote set-url origin "$DEST_URL"
echo -e "📤 ${BLUE}Pushing branch '$BRANCH' via ${PROTOCOL}...${NC}"

if git push -u origin "$BRANCH" --quiet; then
    cd ..
    rm -rf "$TEMP_DIR"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    echo -e "${GREEN}✅ SUCCESS!${NC}"
    echo -e "${GREEN}🔗 Repo:${NC} https://github.com/$ORG_NAME/$REPO_NAME"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
else
    echo -e "${RED}❌ Push failed!${NC}"
    exit 1
fi
