#!/usr/bin/env bash
# Claude Code status line.
#
#   Opus 5.5 high | ███▌⡪⡪⡪⡪⡪⡪ 35% ⧗ 12 min | 34%↑ 4d2h | Documents/project | 🌿 main | 📁 scratch
#
#   model+effort | context bar | cache countdown | plan usage + reset | project | worktree | scratchpad
#
# - Context bar: solid fill on a dark diagonal-hatched track, 1/8-cell resolution.
#   Green under 50%, yellow under 80%, then red.
# - Cache countdown: minutes until the prompt cache goes cold. Hidden unless the
#   cache is warm and a rebuild would re-cache at least CACHE_STAKE_TOKENS.
# - Plan usage: the window closest to its limit. ↑ = usage is ahead of the
#   clock (used% > elapsed% of the window). Reset shown in days/hours only.
# - Project and scratchpad become clickable OSC 8 links with STATUSLINE_LINKS=1
#   (off by default: VS Code underlines links with dashes).
# - 🌿 shows the worktree/branch inside git (hidden otherwise); scratchpad only when it
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
LEAF_C="$E[38;2;106;190;69m"     # leaf green
FOLDER_C="$E[38;2;232;192;110m"  # folder tan
SEP=" ${GRAY}|${R} "

# Context bar palettes: fill fg, track bg, hatch fg (truecolor).
# The track is fine diagonal hatching: braille ⡪ tiles into //// stripes.
BAR_HATCH="⡪"
BAR_GREEN=("$E[38;2;108;200;114m" "$E[48;2;16;30;20m" "$E[38;2;50;108;62m")
BAR_YELLOW=("$E[38;2;232;190;64m" "$E[48;2;34;28;10m" "$E[38;2;112;94;36m")
BAR_RED=("$E[38;2;226;84;72m"   "$E[48;2;36;14;12m" "$E[38;2;114;46;40m")
BAR_WIDTH=10

# Icons. The scratch folder is the Nerd Font folder glyph (U+F07B) so it always
# shows in tan; emoji ignore ANSI color and may render mono. The leaf stays an
# emoji. STATUSLINE_ICONS=emoji uses 📁 for the folder too; =nerd uses the
# Nerd Font leaf (U+F06C) as well.
LEAF="🌿" FOLDER=$'\uf07b'
case "${STATUSLINE_ICONS:-}" in
  emoji) FOLDER="📁" ;;
  nerd)  LEAF=$'\uf06c' ;;
esac

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
# Plan windows are collected as {used, resets, len} and the one with the
# highest used% wins. stdin's windows beat the cached copy of the same window.
IFS=$'\x1f' read -r model effort ctx_used cache_warm cache_exp cache_stake \
  project_dir cwd session_id worktree plan_used plan_resets plan_len < <(
  jq -r --argjson u "$usage_json" --argjson now "$now" '
    def epoch: if type == "number" then . elif type == "string" then
      (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601? // null) else null end;
    def win($used; $resets; $len): {used: $used, resets: ($resets | epoch), len: $len};
    ([.rate_limits.five_hour // empty | win(.used_percentage; .resets_at; 18000)]) as $s5
    | ([.rate_limits.seven_day // empty | win(.used_percentage; .resets_at; 604800)]) as $s7
    | (if ($u.limits | type) == "array" then
         [$u.limits[] | select(.is_active != false)
           | select(.kind != "weekly_all" or ($s7 | length) == 0)
           | select(.group == "weekly" or ($s5 | length) == 0)
           | win(.percent; .resets_at; (if .group == "weekly" then 604800 else 18000 end))]
       else
         [($u.five_hour // empty | select(($s5 | length) == 0) | win(.utilization; .resets_at; 18000)),
          ($u.seven_day // empty | select(($s7 | length) == 0) | win(.utilization; .resets_at; 604800))]
       end) as $cached
    | ($s5 + $s7 + $cached
        | map(select(.used != null and .resets != null and .resets > $now))
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
link() {  # $1 = path, $2 = label  ->  label, or an OSC 8 link with STATUSLINE_LINKS=1
  # Off by default: VS Code's terminal draws a dashed underline under every
  # OSC 8 link and has no setting to hide it.
  if [ "${STATUSLINE_LINKS:-0}" = "1" ]; then
    printf '%s]8;;file://%s%s%s\\%s%s]8;;%s\\' "$E" "$(hostname)" "$1" "$E" "$2" "$E" "$E"
  else
    printf '%s' "$2"
  fi
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
# Solid fill on a dark hatched track, at 1/8-cell resolution: full blocks, one
# partial block for the edge, then diagonal hatching over the track background.
pct=0
[ -n "$ctx_used" ] && pct=$(printf '%.0f' "$ctx_used")
[ "$pct" -gt 100 ] && pct=100
if   [ "$pct" -lt 50 ]; then pal=("${BAR_GREEN[@]}")
elif [ "$pct" -lt 80 ]; then pal=("${BAR_YELLOW[@]}")
else pal=("${BAR_RED[@]}"); fi
partials=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")
eighths=$(( (pct * BAR_WIDTH * 8 + 50) / 100 ))
[ "$pct" -gt 0 ] && [ "$eighths" -eq 0 ] && eighths=1   # never look empty when not
full=$((eighths / 8)) rem=$((eighths % 8))
bar="${pal[1]}${pal[0]}"
for ((i = 0; i < full; i++)); do bar+="█"; done
used_cells=$full
if [ "$rem" -gt 0 ]; then bar+="${partials[rem]}"; used_cells=$((full + 1)); fi
bar+="${pal[2]}"
for ((i = used_cells; i < BAR_WIDTH; i++)); do bar+="$BAR_HATCH"; done
out+="${SEP}${bar}${R} ${WHITE}${pct}%${R}"

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

# ---- git worktree / branch (hidden outside git) ----
# In a linked worktree: the worktree's branch (or name). In a normal checkout:
# the current branch (short commit hash when detached).
if [ -z "$worktree" ] && [ -n "$cwd" ]; then
  if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    worktree=$(git -C "$cwd" branch --show-current 2>/dev/null)
    [ -z "$worktree" ] && worktree=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
    [ -z "$worktree" ] && worktree=$(basename "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)")
  fi
fi
[ -n "$worktree" ] && out+="${SEP}${LEAF_C}${LEAF}${R} ${WHITE}${worktree}${R}"

# ---- scratchpad (only when it has files, clickable) ----
if [ -n "$session_id" ] && [ -n "$project_dir" ]; then
  slug=$(printf '%s' "$project_dir" | sed 's/[^A-Za-z0-9]/-/g')
  scratch="$SCRATCH_ROOT/$slug/$session_id/scratchpad"
  if [ -d "$scratch" ] && [ -n "$(ls -A "$scratch" 2>/dev/null)" ]; then
    out+="${SEP}${FOLDER_C}${FOLDER}${R} ${WHITE}$(link "$scratch" "scratch")${R}"
  fi
fi

printf '%s' "$out"
