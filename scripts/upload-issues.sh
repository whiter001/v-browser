#!/usr/bin/env bash
# publish_issues.sh - bash 3.x 兼容
set -eo pipefail

REPO=whiter001/v-browser
ISSUES_DIR=issues
LOG=/tmp/vbrowser_issue_publish.log
: > "$LOG"

# 查询 milestone 编号 → title 双向映射
MS_JSON=$(gh api "repos/$REPO/milestones" --jq '.[] | "\(.number)|\(.title)"')

publish_one() {
    local file="$1"
    local rel="${file#$ISSUES_DIR/}"
    local title
    title=$(awk '/^# \[/ { sub(/^# \[.*\] /, ""); print; exit }' "$file")
    if [ -z "$title" ]; then
        echo "SKIP: $file" | tee -a "$LOG"
        return 0
    fi
    local -a labels=()
    local tag_line
    tag_line=$(grep -m1 '^> 标签:' "$file" | sed -e 's/^> 标签:[[:space:]]*//' -e 's/`//g')
    IFS=',' read -ra tags <<< "$tag_line"
    for t in "${tags[@]}"; do
        t=$(echo "$t" | xargs)
        [ -n "$t" ] && labels+=("$t")
    done
    local effort_line
    effort_line=$(grep -m1 '^> 工作量:' "$file" | sed -e 's/^> 工作量:[[:space:]]*//' -e 's/`//g' | xargs)
    case "$effort_line" in
        S|M|L|XL) labels+=("effort/$effort_line") ;;
    esac
    # 决定 milestone title（不是 number）
    local milestone_title=""
    for p in P0 P1 P2 P3; do
        for l in "${labels[@]}"; do
            if [ "$l" = "$p" ]; then
                case "$p" in
                    P0|P1) milestone_title="v0.2 Sprint";;
                    P2)    milestone_title="v0.3 Backlog";;
                    P3)    milestone_title="v0.4 Icebox";;
                esac
                break 2
            fi
        done
    done
    local body
    body=$(awk 'NR==1{next} /^> /{next} {print}' "$file")
    local -a args=(--repo "$REPO" --title "$title" --body "$body")
    for lbl in "${labels[@]}"; do args+=(--label "$lbl"); done
    if [ -n "$milestone_title" ]; then args+=(--milestone "$milestone_title"); fi
    local url
    if url=$(gh issue create "${args[@]}" 2>&1); then
        local joined
        joined=$(IFS=,; echo "${labels[*]}")
        echo "OK  $rel  $url  [$joined]" | tee -a "$LOG"
    else
        echo "FAIL  $rel  $url" | tee -a "$LOG"
    fi
}

export -f publish_one
export REPO ISSUES_DIR LOG

total=$(find "$ISSUES_DIR" -type f -name '*.md' \
       -not -name '._*' -not -name 'INDEX.md' -not -name '._INDEX.md' \
       | wc -l | xargs)
echo "publishing $total issues..." | tee -a "$LOG"
while IFS= read -r f; do
    publish_one "$f"
done < <(find "$ISSUES_DIR" -type f -name '*.md' \
         -not -name '._*' -not -name 'INDEX.md' -not -name '._INDEX.md' \
         | sort)

echo "=== summary ===" | tee -a "$LOG"
echo "succeeded: $(grep -c '^OK' "$LOG" 2>/dev/null || echo 0)" | tee -a "$LOG"
echo "failed:    $(grep -c '^FAIL' "$LOG" 2>/dev/null || echo 0)" | tee -a "$LOG"
