# AI Conflict Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add AI-powered re-implementation of fork changes when git rebase fails, using GitHub Models API with zero additional secrets.

**Architecture:** Insert new workflow steps between the existing rebase failure and issue creation. On rebase failure, extract the fork's diff, send it to GitHub Models API (GPT-4o-mini) along with current upstream files, parse the AI response, and open a PR. Fall back to existing issue creation if AI fails.

**Tech Stack:** GitHub Actions workflow (YAML), bash, curl, GitHub Models API, gh CLI

---

### Task 1: Extract Fork Changes on Rebase Failure

**Files:**
- Modify: `.github/workflows/rebase-plugin.yml:55-67` (after "Attempt Rebase" step)

This task modifies the existing "Attempt Rebase" step to capture fork metadata on failure, and adds a new step to extract the fork's diff and affected file contents.

- [ ] **Step 1: Modify "Attempt Rebase" to capture merge-base and fork info on failure**

In `.github/workflows/rebase-plugin.yml`, replace the "Attempt Rebase" step (lines 55-67) with:

```yaml
      - name: Attempt Rebase
        id: rebase
        run: |
          UPSTREAM_BR=${{ steps.setup.outputs.upstream_branch }}
          LOCAL_BR=${{ steps.setup.outputs.local_branch }}

          if git rebase upstream/$UPSTREAM_BR; then
            git push origin $LOCAL_BR --force
            echo "status=success" >> $GITHUB_OUTPUT
            echo "sha=$(git rev-parse HEAD)" >> $GITHUB_OUTPUT
          else
            git rebase --abort
            echo "status=failed" >> $GITHUB_OUTPUT
          fi
```

The only change: added `git rebase --abort` on failure so we're back to a clean state.

- [ ] **Step 2: Add "Extract Fork Changes" step**

Add this new step immediately after "Attempt Rebase":

```yaml
      - name: Extract Fork Changes
        id: extract
        if: steps.rebase.outputs.status == 'failed'
        run: |
          UPSTREAM_BR=${{ steps.setup.outputs.upstream_branch }}
          MERGE_BASE=$(git merge-base HEAD upstream/$UPSTREAM_BR)

          # Capture fork's diff and commit log
          git diff "$MERGE_BASE"..HEAD > /tmp/fork.diff
          git log --oneline "$MERGE_BASE"..HEAD > /tmp/fork_log.txt

          # Collect affected file names
          AFFECTED_FILES=$(git diff --name-only "$MERGE_BASE"..HEAD)
          echo "$AFFECTED_FILES" > /tmp/affected_files.txt

          # Collect current upstream versions of affected files
          mkdir -p /tmp/upstream_files
          while IFS= read -r file; do
            dir=$(dirname "$file")
            mkdir -p "/tmp/upstream_files/$dir"
            git show "upstream/$UPSTREAM_BR:$file" > "/tmp/upstream_files/$file" 2>/dev/null || true
          done <<< "$AFFECTED_FILES"

          echo "merge_base=$MERGE_BASE" >> $GITHUB_OUTPUT
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/rebase-plugin.yml
git commit -m "feat(ai-rebase): extract fork changes on rebase failure"
```

---

### Task 2: Call GitHub Models API

**Files:**
- Modify: `.github/workflows/rebase-plugin.yml` (add new step after "Extract Fork Changes")

This task adds the step that builds the prompt, calls the GitHub Models API, and saves the AI response.

- [ ] **Step 1: Add "AI Re-implementation" step**

Add this step after "Extract Fork Changes":

```yaml
      - name: AI Re-implementation
        id: ai_resolve
        if: steps.rebase.outputs.status == 'failed'
        env:
          GH_TOKEN: ${{ steps.generate_token.outputs.token }}
        run: |
          UPSTREAM_BR=${{ steps.setup.outputs.upstream_branch }}

          # Build the prompt with fork diff and upstream file contents
          FORK_DIFF=$(cat /tmp/fork.diff)
          UPSTREAM_CONTENT=""
          while IFS= read -r file; do
            if [ -f "/tmp/upstream_files/$file" ]; then
              CONTENT=$(cat "/tmp/upstream_files/$file")
              UPSTREAM_CONTENT="${UPSTREAM_CONTENT}
          --- FILE: ${file} ---
          ${CONTENT}
          --- END FILE ---
          "
            fi
          done < /tmp/affected_files.txt

          PROMPT="You are re-implementing changes from a forked repository onto the current upstream code.

          Here are the changes the fork made (as a unified diff):
          \`\`\`diff
          ${FORK_DIFF}
          \`\`\`

          Here are the current upstream versions of the affected files:
          ${UPSTREAM_CONTENT}

          Re-implement the fork's changes on top of the current upstream code. Preserve the intent of every change in the diff.

          Output ONLY the modified files in this exact format (no other text):

          --- FILE: path/to/file ---
          <full file content here>
          --- END FILE ---"

          # Build JSON payload using jq
          PAYLOAD=$(jq -n \
            --arg model "openai/gpt-4o-mini" \
            --arg prompt "$PROMPT" \
            '{
              model: $model,
              messages: [
                { role: "user", content: $prompt }
              ]
            }')

          # Call GitHub Models API
          HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/ai_response.json \
            "https://models.github.ai/inference/chat/completions" \
            -H "Authorization: Bearer $GH_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD")

          if [ "$HTTP_CODE" -ne 200 ]; then
            echo "GitHub Models API returned HTTP $HTTP_CODE"
            cat /tmp/ai_response.json
            echo "status=failed" >> $GITHUB_OUTPUT
            exit 0
          fi

          # Extract the AI's response content
          AI_OUTPUT=$(jq -r '.choices[0].message.content // empty' /tmp/ai_response.json)

          if [ -z "$AI_OUTPUT" ]; then
            echo "AI response was empty"
            echo "status=failed" >> $GITHUB_OUTPUT
            exit 0
          fi

          echo "$AI_OUTPUT" > /tmp/ai_output.txt
          echo "status=success" >> $GITHUB_OUTPUT
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/rebase-plugin.yml
git commit -m "feat(ai-rebase): add GitHub Models API call for re-implementation"
```

---

### Task 3: Apply AI Output and Open PR

**Files:**
- Modify: `.github/workflows/rebase-plugin.yml` (add new step after "AI Re-implementation")

This task parses the AI response, applies the files on a new branch based on upstream, and opens a PR.

- [ ] **Step 1: Add "Apply AI Resolution" step**

Add this step after "AI Re-implementation":

```yaml
      - name: Apply AI Resolution
        id: ai_pr
        if: steps.rebase.outputs.status == 'failed' && steps.ai_resolve.outputs.status == 'success'
        env:
          GH_TOKEN: ${{ steps.generate_token.outputs.token }}
        run: |
          UPSTREAM_BR=${{ steps.setup.outputs.upstream_branch }}
          LOCAL_BR=${{ steps.setup.outputs.local_branch }}
          PLUGIN_NAME="${{ inputs.plugin_name }}"
          UPSTREAM_SHA=$(git rev-parse upstream/$UPSTREAM_BR)
          BRANCH_NAME="ai-rebase-${PLUGIN_NAME}-${UPSTREAM_SHA:0:7}"

          # Create new branch from upstream
          git checkout -b "$BRANCH_NAME" "upstream/$UPSTREAM_BR"

          # Parse AI output and write files
          AI_OUTPUT=$(cat /tmp/ai_output.txt)
          CURRENT_FILE=""
          CURRENT_CONTENT=""

          while IFS= read -r line; do
            if echo "$line" | grep -qE '^--- FILE: .+ ---$'; then
              # If we were accumulating a file, write it
              if [ -n "$CURRENT_FILE" ]; then
                mkdir -p "$(dirname "$CURRENT_FILE")"
                printf '%s\n' "$CURRENT_CONTENT" > "$CURRENT_FILE"
              fi
              CURRENT_FILE=$(echo "$line" | sed 's/^--- FILE: //;s/ ---$//')
              CURRENT_CONTENT=""
            elif echo "$line" | grep -qE '^--- END FILE ---$'; then
              if [ -n "$CURRENT_FILE" ]; then
                mkdir -p "$(dirname "$CURRENT_FILE")"
                printf '%s\n' "$CURRENT_CONTENT" > "$CURRENT_FILE"
              fi
              CURRENT_FILE=""
              CURRENT_CONTENT=""
            else
              if [ -n "$CURRENT_FILE" ]; then
                if [ -z "$CURRENT_CONTENT" ]; then
                  CURRENT_CONTENT="$line"
                else
                  CURRENT_CONTENT="${CURRENT_CONTENT}
          $line"
                fi
              fi
            fi
          done <<< "$AI_OUTPUT"

          # Write last file if no END marker
          if [ -n "$CURRENT_FILE" ]; then
            mkdir -p "$(dirname "$CURRENT_FILE")"
            printf '%s\n' "$CURRENT_CONTENT" > "$CURRENT_FILE"
          fi

          AFFECTED_FILES=$(cat /tmp/affected_files.txt)
          FORK_LOG=$(cat /tmp/fork_log.txt)

          git add -A
          git commit -m "chore(ai-rebase): re-implement fork changes for ${PLUGIN_NAME}"

          git push origin "$BRANCH_NAME"

          gh pr create \
            --repo ${{ github.repository }} \
            --title "AI Rebase: ${PLUGIN_NAME}" \
            --base "$LOCAL_BR" \
            --head "$BRANCH_NAME" \
            --body "$(cat <<EOF
          Automated AI re-implementation of fork changes onto upstream.

          **Original fork commits:**
          \`\`\`
          ${FORK_LOG}
          \`\`\`

          **Files modified by AI:**
          \`\`\`
          ${AFFECTED_FILES}
          \`\`\`

          > This PR was generated by AI and requires human review.
          EOF
          )"
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/rebase-plugin.yml
git commit -m "feat(ai-rebase): apply AI output and open PR"
```

---

### Task 4: Update Failure Handling Conditions

**Files:**
- Modify: `.github/workflows/rebase-plugin.yml:69-84` (existing "Handle Failure" step)

This task updates the existing "Handle Failure" step so it only triggers when both the rebase AND the AI resolution failed.

- [ ] **Step 1: Update the "Handle Failure" condition**

Change the `if` condition on the existing "Handle Failure" step from:

```yaml
        if: steps.rebase.outputs.status == 'failed'
```

to:

```yaml
        if: steps.rebase.outputs.status == 'failed' && steps.ai_resolve.outputs.status != 'success'
```

This means the issue + dashboard comment only fires when:
- The rebase failed, AND
- The AI either failed or was never reached

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/rebase-plugin.yml
git commit -m "fix(ai-rebase): only create issue when AI resolution also fails"
```

---

### Task 5: Final Review and Validation

**Files:**
- Read: `.github/workflows/rebase-plugin.yml` (full file review)

- [ ] **Step 1: Read the full workflow file and verify**

Read `.github/workflows/rebase-plugin.yml` end to end and verify:
- Step ordering: Generate Token → Checkout → Setup → Attempt Rebase → Extract Fork Changes → AI Re-implementation → Apply AI Resolution → Handle Failure → Update KoalaVim Lockfile
- All `if` conditions are correct:
  - Extract Fork Changes: `steps.rebase.outputs.status == 'failed'`
  - AI Re-implementation: `steps.rebase.outputs.status == 'failed'`
  - Apply AI Resolution: `steps.rebase.outputs.status == 'failed' && steps.ai_resolve.outputs.status == 'success'`
  - Handle Failure: `steps.rebase.outputs.status == 'failed' && steps.ai_resolve.outputs.status != 'success'`
  - Update KoalaVim Lockfile: `steps.rebase.outputs.status == 'success'` (unchanged)
- All step ID references resolve correctly
- The `env.GH_TOKEN` is set on steps that need it

- [ ] **Step 2: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/rebase-plugin.yml'))" && echo "YAML OK"
```

Expected: `YAML OK`

- [ ] **Step 3: Commit any fixes if needed, then final commit**

If any issues found, fix and commit:
```bash
git add .github/workflows/rebase-plugin.yml
git commit -m "fix(ai-rebase): address review findings"
```
