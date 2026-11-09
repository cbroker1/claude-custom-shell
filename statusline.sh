#!/usr/bin/env bash
# Claude Code status line.
#
#   Opus 5.5 high | ██████░░░░ 42% ⧗ 12 min | 34%↑ 3d18h | Documents/project | 🌿 rule-fixes | 📁 scratch
#
#   model+effort | context bar | cache countdown | plan usage + reset | project | worktree | scratchpad
#
# - Context bar: green under 50%, yellow under 80%, then red.
# - Cache countdown: minutes until the prompt cache goes cold. Hidden unless the
#   cache is warm and a rebuild would re-cache at least CACHE_STAKE_TOKENS.
# - Plan usage: the window closest to its limit. ↑ = usage is ahead of the
#   clock (used% > elapsed% of the window). Reset shown in days/hours only.
# - Project and scratchpad are OSC 8 links (click to open the folder).
# - Worktree only shows inside a linked git worktree; scratchpad only when it
#   has files in it.
#
# Usage numbers come from stdin's .rate_limits when Claude Code supplies them,
# merged with the /api/oauth/usage response (what /usage reads), cached for
# CACHE_TTL seconds and refreshed in the background.

input=$(cat)

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
CACHE="$CACHE_DIR/usage.json"
CACHE_TTL=300
CACHE_STAKE_TOKENS=${CACHE_STAKE_TOKENS:-20000}
CREDS="$HOME/.claude/.credentials.json"
SCRATCH_ROOT="${CLAUDE_SCRATCH_ROOT:-${TMPDIR:-/tmp}/claude-$(id -u)}"

# ---- colors ----
E=$'\033'
R="$E[0m"
WHITE="$E[97m"
GRAY="$E[90m"
DIM="$E[2m"
GREEN="$E[32m"
YELLOW="$E[33m"
RED="$E[31m"
SEP=" ${GRAY}|${R} "

# ---- usage endpoint fetch (atomic write into the cache) ----
fetch_usage() {
  local tok tmp
  tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS" 2>/dev/null)
  [ -z "$tok" ] && return 1
  mkdir -p "$CACHE_DIR"
  tmp=$(mktemp "$CACHE_DIR/usage.XXXXXX") || return 1
  if curl -sf --max-time 4 https://api.anthropic.com/api/oauth/usage \
       -H "Authorization: Bearer $tok" \
       -H "anthropic-beta: oauth-2025-04-20" \
       -H "User-Agent: claude-code-statusline" -o "$tmp" \
     && jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$CACHE"
  else
    rm -f "$tmp"
    touch "$CACHE" 2>/dev/null   # back off a full TTL on failure
    return 1
  fi
}

if [ ! -s "$CACHE" ]; then
  fetch_usage   # first run: block briefly so the line isn't empty
elif [ $(( $(date +%s) - $(stat -c %Y "$CACHE") )) -ge "$CACHE_TTL" ]; then
  touch "$CACHE"   # claim the refresh so concurrent renders don't all fetch
  ( fetch_usage >/dev/null 2>&1 & )
fi

usage_json='{}'
[ -s "$CACHE" ] && usage_json=$(cat "$CACHE")

now=$(date +%s)

# ---- pull everything out of stdin + usage cache in one jq pass ----
# Plan windows are collected as {used, resets, len} and the
# one with the highest used% wins.
IFS=$'\x1f' read -r model effort ctx_used cache_warm cache_exp cache_stake \
  project_dir cwd session_id worktree plan_used plan_resets plan_len < <(
  jq -r --argjson u "$usage_json" --argjson now "$now" '
    def epoch: if type == "number" then . elif type == "string" then
      (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601? // null) else null end;
    def win($used; $resets; $len): {used: $used, resets: ($resets | epoch), len: $len};
    ([
      (.rate_limits.five_hour  // empty | win(.used_percentage; .resets_at; 18000)),
      (.rate_limits.seven_day  // empty | win(.used_percentage; .resets_at; 604800)),
      ($u.five_hour  // empty | win(.utilization; .resets_at; 18000)),
      ($u.seven_day  // empty | win(.utilization; .resets_at; 604800)),
      ($u.limits // [] | .[] | select(.is_active != false)
        | win(.percent; .resets_at; (if .group == "weekly" then 604800 else 18000 end)))
    ] | map(select(.used != null and .resets != null and .resets > $now))
      | max_by(.used)) as $plan
    | [
        (.model.display_name // "?"),
        (.effort.level // ""),
        (.context_window.used_percentage // ""),
        (.prompt_cache.warm // false),
        (.prompt_cache.expires_at // ""),
        (.prompt_cache.recache_tokens_if_cold // 0),
        (.workspace.project_dir // .cwd // ""),
        (.cwd // .workspace.current_dir // ""),
        (.session_id // ""),
        (.worktree.branch // .worktree.name // .workspace.git_worktree // ""),
        ($plan.used // ""),
        ($plan.resets // ""),
        ($plan.len // "")
      ] | map(tostring) | join("\u001f")
  ' <<<"$input" 2>/dev/null
)

# ---- helpers ----
link() {  # $1 = path, $2 = label  ->  OSC 8 hyperlink
  printf '%s]8;;file://%s%s%s\\%s%s]8;;%s\\' "$E" "$(hostname)" "$1" "$E" "$2" "$E" "$E"
}

fmt_reset() {  # seconds -> "3d18h" / "18h" / "<1h"
  local s=$1 d h
  [ "$s" -le 0 ] && { echo "now"; return; }
  d=$((s / 86400)); h=$(((s % 86400) / 3600))
  if   [ "$d" -gt 0 ]; then echo "${d}d${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h"
  else echo "<1h"; fi
}

out=""

# ---- model (+ effort) ----
out+="${WHITE}${model}${R}"
[ -n "$effort" ] && out+=" ${GRAY}${effort}${R}"

# ---- context window bar ----
if [ -n "$ctx_used" ]; then
  pct=$(printf '%.0f' "$ctx_used")
  if   [ "$pct" -lt 50 ]; then c=$GREEN
  elif [ "$pct" -lt 80 ]; then c=$YELLOW
  else c=$RED; fi
  filled=$(( (pct + 5) / 10 )); [ "$filled" -gt 10 ] && filled=10
  bar=""
  for ((i = 0; i < 10; i++)); do
    if [ "$i" -lt "$filled" ]; then bar+="█"; else bar+="░"; fi
  done
  out+="${SEP}${c}${bar:0:filled}${DIM}${bar:filled}${R} ${WHITE}${pct}%${R}"
else
  out+="${SEP}${DIM}${GREEN}░░░░░░░░░░${R} ${WHITE}0%${R}"
fi

# ---- prompt cache countdown (only when a lot is at stake) ----
if [ "$cache_warm" = "true" ] && [ -n "$cache_exp" ] && [ "${cache_stake%.*}" -ge "$CACHE_STAKE_TOKENS" ]; then
  left=$(( ${cache_exp%.*} - now ))
  if [ "$left" -gt 0 ]; then
    out+=" ${YELLOW}⧗ $(( (left + 59) / 60 )) min${R}"
  fi
fi

# ---- plan usage: closest window, pace arrow, d/h reset ----
if [ -n "$plan_used" ]; then
  used=$(printf '%.0f' "$plan_used")
  remain=$(( ${plan_resets%.*} - now ))
  elapsed_pct=$(( (plan_len - remain) * 100 / plan_len ))
  arrow=""
  [ "$used" -gt "$elapsed_pct" ] && arrow="↑"
  if   [ "$used" -ge 90 ]; then c=$RED
  elif [ -n "$arrow" ] || [ "$used" -ge 75 ]; then c=$YELLOW
  else c=$GREEN; fi
  out+="${SEP}${c}${used}%${arrow}${R} ${WHITE}$(fmt_reset "$remain")${R}"
fi

# ---- project (last two path components, clickable) ----
if [ -n "$project_dir" ]; then
  parent=$(basename "$(dirname "$project_dir")")
  name="${parent}/$(basename "$project_dir")"
  [ "$project_dir" = "/" ] && name="/"
  out+="${SEP}${WHITE}$(link "$project_dir" "$name")${R}"
fi

# ---- git worktree (hidden unless in a linked worktree) ----
if [ -z "$worktree" ] && [ -n "$cwd" ]; then
  gd=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)
  gcd=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -n "$gd" ] && [ -n "$gcd" ] && [ "$gd" != "$gcd" ]; then
    worktree=$(git -C "$cwd" branch --show-current 2>/dev/null)
    [ -z "$worktree" ] && worktree=$(basename "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)")
  fi
fi
[ -n "$worktree" ] && out+="${SEP}🌿 ${WHITE}${worktree}${R}"

# ---- scratchpad (only when it has files, clickable) ----
if [ -n "$session_id" ] && [ -n "$project_dir" ]; then
  slug=$(printf '%s' "$project_dir" | sed 's/[^A-Za-z0-9]/-/g')
  scratch="$SCRATCH_ROOT/$slug/$session_id/scratchpad"
  if [ -d "$scratch" ] && [ -n "$(ls -A "$scratch" 2>/dev/null)" ]; then
    out+="${SEP}📁 ${WHITE}$(link "$scratch" "scratch")${R}"
  fi
fi

printf '%s' "$out"
