#!/bin/bash

# Status line - shows account, model, git branch, context usage, rate limits

data=$(cat)

# Extract all needed JSON fields in a single pass using node (jq is not
# installed anywhere on PATH in this environment; node is already on PATH
# and used for other tooling here). One value per line, in the fixed order
# below; missing/null fields come out as an empty line so the downstream
# `[ -n "$x" ]` / `!= "null"` checks behave the same as the jq `// empty`
# fallbacks they replace.
mapfile -t _fields < <(echo "$data" | node -e "
let d = '';
process.stdin.on('data', c => d += c).on('end', () => {
  let j = {};
  try { j = JSON.parse(d); } catch (e) {}
  const out = [
    (j.model && (j.model.display_name || j.model.id)) || 'unknown',
    (j.effort && j.effort.level) || '',
    (j.thinking && j.thinking.enabled) || '',
    (j.workspace && j.workspace.current_dir) || j.cwd || '',
    (j.context_window && j.context_window.context_window_size) || 200000,
    (j.context_window && j.context_window.used_percentage),
    (j.rate_limits && j.rate_limits.five_hour && j.rate_limits.five_hour.used_percentage),
    (j.rate_limits && j.rate_limits.five_hour && j.rate_limits.five_hour.resets_at),
    (j.rate_limits && j.rate_limits.seven_day && j.rate_limits.seven_day.used_percentage),
    (j.rate_limits && j.rate_limits.seven_day && j.rate_limits.seven_day.resets_at)
  ];
  console.log(out.map(v => (v === undefined || v === null) ? '' : v).join('\n'));
});
")
model="${_fields[0]:-unknown}"
effort_level="${_fields[1]}"
thinking_on="${_fields[2]}"
cwd="${_fields[3]}"
max_ctx="${_fields[4]:-200000}"
used_pct="${_fields[5]}"
five_hour_pct="${_fields[6]}"
five_hour_reset="${_fields[7]}"
seven_day_pct="${_fields[8]}"
seven_day_reset="${_fields[9]}"

# Color codes (bright ANSI variants; Claude Code renders the status line
# dimmed, so bright codes land close to normal saturation instead of
# washing out to near-illegible). One hue per segment so they stay visually
# distinct at a glance:
#   MAGENTA account   CYAN model   GREEN git branch
#   BLUE/RED context (existing low/high-usage semantics)
#   YELLOW/RED rate limits (existing warn/critical semantics)
# Standard ANSI codes are used (not truecolor) so terminal themes that remap
# the 16-color palette for light backgrounds still apply automatically;
# otherwise this is tuned for a dark background.
BLUE='\033[94m'
RED='\033[91m'
YELLOW='\033[93m'
GREEN='\033[92m'
MAGENTA='\033[95m'
CYAN='\033[96m'
RESET='\033[0m'

# Account: this user runs multiple Claude Code profiles via CLAUDE_CONFIG_DIR
# (e.g. .claude-c2, .claude-james), set per-session by Claude Code itself.
# Derive the alias from the config dir's basename, stripping the ".claude"
# prefix and leading "-" (".claude-c2" -> "c2"). The unaliased default
# (".claude", or CLAUDE_CONFIG_DIR unset) shows as "default" so the segment
# is always present and the bar layout stays consistent.
if [ -n "$CLAUDE_CONFIG_DIR" ]; then
    config_base=$(basename "$CLAUDE_CONFIG_DIR")
else
    config_base=".claude"
fi
if [ "$config_base" = ".claude" ]; then
    profile_alias="default"
else
    profile_alias="${config_base#.claude}"
    profile_alias="${profile_alias#-}"
fi
account="${MAGENTA}${profile_alias}${RESET}"

# Strip any trailing parenthetical from the model name (e.g. "(1M context)")
model=$(echo "$model" | sed 's/ *([^)]*)$//')

# Thinking / effort level, shown after the model name when available
if [ -n "$effort_level" ] && [ "$effort_level" != "null" ]; then
    model="${model} (${effort_level})"
elif [ "$thinking_on" = "true" ]; then
    model="${model} (thinking)"
fi
model="${CYAN}${model}${RESET}"

# Git branch (skips optional locks so it never blocks on a repo lock file;
# left empty, and omitted from the output, when cwd isn't a git repo)
git_branch=""
if [ -n "$cwd" ] && git --no-optional-locks -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch=$(git --no-optional-locks -C "$cwd" branch --show-current 2>/dev/null)
    [ -z "$branch" ] && branch=$(git --no-optional-locks -C "$cwd" rev-parse --short HEAD 2>/dev/null)
    [ -n "$branch" ] && git_branch="${GREEN}${branch}${RESET}"
fi

# Format context display
if [ -z "$used_pct" ] || [ "$used_pct" = "null" ]; then
    # Loading state - empty circles
    context_info="○○○○○○○○○○ loading..."
else
    pct=$(printf "%.0f" "$used_pct" 2>/dev/null || echo "$used_pct")
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    # Calculate tokens (used in k; max shown in m once it reaches 1000k)
    used_k=$(( max_ctx * pct / 100 / 1000 ))
    max_k=$(( max_ctx / 1000 ))
    if [ "$max_k" -ge 1000 ]; then
        max_label="$(( max_k / 1000 ))m"
    else
        max_label="${max_k}k"
    fi

    # Build circle bar (10 segments)
    bar=""
    filled=$(( pct / 10 ))

    # Blue by default, red when > 60%
    if [ "$pct" -gt 60 ]; then
        COLOR="$RED"
    else
        COLOR="$BLUE"
    fi

    for i in 0 1 2 3 4 5 6 7 8 9; do
        if [ "$i" -lt "$filled" ]; then
            bar="${bar}${COLOR}●${RESET}"
        else
            bar="${bar}○"
        fi
    done

    context_info="${bar} ${used_k}k/${max_label} (${pct}%)"
fi

# Format a single limit segment, coloring by severity
format_limit() {
    label="$1"
    rounded=$(printf "%.0f" "$2" 2>/dev/null || echo "$2")
    if [ "$rounded" -ge 90 ] 2>/dev/null; then
        echo "${label} ${RED}${rounded}%${RESET}"
    elif [ "$rounded" -ge 70 ] 2>/dev/null; then
        echo "${label} ${YELLOW}${rounded}%${RESET}"
    else
        echo "${label} ${rounded}%"
    fi
}

# Format an epoch with the given strftime spec (BSD/macOS date, then GNU date fallback)
format_when() {
    out=$(date -r "$1" "+$2" 2>/dev/null) || out=$(date -d "@$1" "+$2" 2>/dev/null)
    echo "$out" | tr -s ' ' | sed 's/^ //'
}

# Build "5h X% (02:39 PM) · Wk Y% (May 21, 04:00 PM)", omitting any segment that isn't present yet
limits=""
if [ -n "$five_hour_pct" ] && [ "$five_hour_pct" != "null" ]; then
    fh=$(format_limit "5h" "$five_hour_pct")
    if [ -n "$five_hour_reset" ] && [ "$five_hour_reset" != "null" ]; then
        t=$(format_when "$five_hour_reset" "%I:%M %p")
        [ -n "$t" ] && fh="${fh} (${t})"
    fi
    limits="$fh"
fi
if [ -n "$seven_day_pct" ] && [ "$seven_day_pct" != "null" ]; then
    wk=$(format_limit "Wk" "$seven_day_pct")
    if [ -n "$seven_day_reset" ] && [ "$seven_day_reset" != "null" ]; then
        when=$(format_when "$seven_day_reset" "%b %e, %I:%M %p")
        [ -n "$when" ] && wk="${wk} (${when})"
    fi
    [ -n "$limits" ] && limits="${limits} · ${wk}" || limits="$wk"
fi

# Output: Account | Model | Branch | Context | Limits, omitting empty segments
segments=()
[ -n "$account" ] && segments+=("$account")
segments+=("$model")
[ -n "$git_branch" ] && segments+=("$git_branch")
segments+=("$context_info")
[ -n "$limits" ] && segments+=("$limits")

output=""
for seg in "${segments[@]}"; do
    if [ -z "$output" ]; then
        output="$seg"
    else
        output="${output} | ${seg}"
    fi
done

printf '%b\n' "$output"
