#!/usr/bin/env bash
# test-panel-config.sh — the config file is the one place that says who reviews and with which
# model. These tests exist because the alternative failed in production: `cursor` was dropped from
# the panel on 2026-08-13 and kept reviewing for weeks, because callers that omit --reviewers got
# the default assigned in the script rather than the configured panel. The first test below is
# that incident, in a form that fails.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB="$HERE/../lib-panel.sh"
PASS=0
FAIL=0
ok() {
  echo "  ok   [-] $1"
  PASS=$((PASS + 1))
}
bad() {
  echo "  FAIL $1"
  FAIL=$((FAIL + 1))
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CFG="$WORK/config"

# Every case runs with the model/panel environment scrubbed. Without this the suite reads the
# developer's own exports and "the file wins" passes for the wrong reason — the exact trap the
# relay's own tests already guard against for CURSOR_REVIEW_MODEL.
resolve() { # $1 = config body (or ""), rest = panel_resolve args
  local body="$1"
  shift
  printf '%s' "$body" >"$CFG"
  env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
    bash -c '. "$0"; panel_config_load 2>/dev/null; panel_resolve "$@"' "$LIB" "$@"
}

echo "panel config tests:"

# THE INCIDENT: a panel set in the file must reach a caller that passes no flag at all.
got=$(resolve 'REVIEWERS=claude,codex' NOT_SET_ANYWHERE REVIEWERS 'claude,codex,grok,opencode')
[ "$got" = "claude,codex" ] && ok "a panel in the config reaches a caller that omits --reviewers" ||
  bad "config panel ignored — got '$got'"

# No config at all → the script default. The machine with nothing configured must still work.
got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$WORK/absent" \
  bash -c '. "$0"; panel_config_load 2>/dev/null; panel_resolve NOPE REVIEWERS "$1"' "$LIB" 'claude,codex,grok,opencode')
[ "$got" = "claude,codex,grok,opencode" ] && ok "no config file → the script default still applies" ||
  bad "missing config broke the default — got '$got'"

# Precedence: env beats file.
got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" CLAUDE_REVIEW_MODEL=sonnet \
  bash -c 'printf "MODEL_claude=opus\n" > "$2"; . "$0"; panel_config_load 2>/dev/null; panel_resolve CLAUDE_REVIEW_MODEL MODEL_claude fallback' "$LIB" x "$CFG")
[ "$got" = "sonnet" ] && ok "the environment beats the config file" || bad "env lost to the file — got '$got'"

# An EMPTY value means "not configured", at every layer — NOT "disable". The relay's own tests
# run with CURSOR_REVIEW_MODEL= on purpose so a stray export cannot make an assertion pass; if
# empty meant "disabled" the model would silently unpin and argv would carry a bare --model.
got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" CURSOR_REVIEW_MODEL= \
  bash -c 'printf "" > "$2"; . "$0"; panel_config_load 2>/dev/null; panel_resolve CURSOR_REVIEW_MODEL MODEL_cursor composer-2.5' "$LIB" x "$CFG")
[ "$got" = "composer-2.5" ] && ok "an empty env value means 'not set', not 'disabled'" ||
  bad "empty env unpinned the model — got '$got'"
got=$(resolve 'MODEL_cursor=' CURSOR_REVIEW_MODEL MODEL_cursor composer-2.5)
[ "$got" = "composer-2.5" ] && ok "an empty file value means 'not set' too" || bad "empty file value — got '$got'"

# THE TIMEOUT DEFAULT, pinned as a literal. `panel_resolve` takes its fallback as an ARGUMENT, so
# every test above proves the ladder and none of them proves which number the script actually hands
# it — a plan review that dies on the clock reports no findings, which reads exactly like a clean
# review, so the number is worth pinning. Reading the literal out of the script is the only way to
# assert it without a full relay run; change 500 here and this goes red, which is its whole job.
#
# ~/.config/pr-review-relay/config's AGENT_TIMEOUT is the one place to override it, for this tool
# AND for ship-feature's plan-review, which reads this same file.
RELAY="$HERE/../pr-review-relay"
got=$(grep -o 'panel_resolve PR_RELAY_AGENT_TIMEOUT AGENT_TIMEOUT [0-9]*' "$RELAY" | awk '{print $4}')
[ "$got" = "500" ] && ok "the built-in per-reviewer timeout is 500s" ||
  bad "the built-in timeout default is '$got', not 500"

# review-local runs the SAME panel with the SAME seats off the SAME config key, so its literal has to
# agree with the relay's. Two entrypoints in one repo quietly disagreeing on a no-config machine is
# the drift this default exists to remove, and nothing else in the suite compares them.
LOCAL="$HERE/../review-local"
got=$(grep -o 'panel_resolve PR_RELAY_AGENT_TIMEOUT AGENT_TIMEOUT [0-9]*' "$LOCAL" | awk '{print $4}')
[ "$got" = "500" ] && ok "review-local uses the same 500s default as the relay" ||
  bad "review-local's timeout default is '$got', not 500"

# The file still beats that literal — the override has to keep working, or the default becomes a cap.
got=$(resolve 'AGENT_TIMEOUT=470' PR_RELAY_AGENT_TIMEOUT AGENT_TIMEOUT 500)
[ "$got" = "470" ] && ok "AGENT_TIMEOUT in the config beats the built-in default" ||
  bad "config timeout ignored — got '$got'"

# Every seat named in a panel must be configurable. This is the cursor bug in its second form:
# a seat you can name but cannot pin drifts back to a default nobody chose.
for seat in claude claude_fallback codex cursor grok opencode antigravity; do
  got=$(resolve "MODEL_$seat=pinned-$seat" NOT_SET "MODEL_$seat" 'script-default')
  [ "$got" = "pinned-$seat" ] && ok "MODEL_$seat is configurable" || bad "MODEL_$seat ignored — got '$got'"
done

# The seat is 'antigravity' — that is what --reviewers takes. Its variable happens to be called
# AGY_REVIEW_MODEL, and the call site used to read MODEL_agy, so MODEL_antigravity was accepted,
# stored, and read by nothing: a setting that vanished in silence, in the file written to stop
# settings vanishing in silence. MODEL_agy stays working as an alias for anyone who wrote it.
got=$(resolve 'MODEL_agy=via-alias' NOT_SET MODEL_antigravity 'script-default')
[ "$got" = "via-alias" ] && ok "MODEL_agy still resolves as an alias of MODEL_antigravity" ||
  bad "the MODEL_agy alias broke — got '$got'"

# A suffix that names no seat is stored (ship-feature reads this file too and may know seats this
# repo does not) but must be REPORTED, or a typo reads as a setting that simply had no effect.
out=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
  bash -c 'printf "MODEL_opencde=oops\n" > "$2"; . "$0"; panel_config_load 2>&1 >/dev/null' "$LIB" x "$CFG")
printf '%s' "$out" | grep -q "no reviewer seat named 'opencde'" && ok "a MODEL_ key for a non-seat is reported" ||
  bad "typo'd seat name swallowed — got: $out"

# ...and a seat this repo does not drive itself must NOT be reported: ship-feature's plan panel
# uses these, and warning about them would train everyone to ignore the warning.
out=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
  bash -c 'printf "MODEL_kimi3=x\nMODEL_grok45high=y\n" > "$2"; . "$0"; panel_config_load 2>&1 >/dev/null' "$LIB" x "$CFG")
[ -z "$out" ] && ok "plan-review seats are not reported as unknown" || bad "plan seat warned about — got: $out"
# glm and gemini are ship-feature's CURRENT plan seats. Before they were listed here, every relay run
# on a machine that pinned them printed "no reviewer seat named 'glm'" — always wrong, so ignored.
out=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
  bash -c 'printf "MODEL_glm=x\nMODEL_gemini=y\nEFFORT_glm=z\n" > "$2"; . "$0"; panel_config_load 2>&1 >/dev/null' "$LIB" x "$CFG")
[ -z "$out" ] && ok "glm and gemini keys are not reported as unknown" || bad "glm/gemini warned about — got: $out"

# --- panel_seat_pins: what each seat's dispatch line shows -----------------------
# Sourced in the order both entry points use (panel, opencode, grok), because the grok and
# opencode arms call those libs' resolvers. Globals the scripts set at load time are passed in.
GLIB="$HERE/../lib-grok.sh"
OLIB="$HERE/../lib-opencode.sh"
pins() { # $1 = config body, $2 = seat, rest = VAR=value assignments for the call
  local body="$1" seat="$2"
  shift 2
  printf '%s' "$body" >"$CFG"
  env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" "$@" \
    bash -c 'set -u; . "$0"; . "$1"; . "$2"; panel_config_load 2>/dev/null; panel_seat_pins "$3"' "$LIB" "$OLIB" "$GLIB" "$seat"
}
got=$(pins '' grok)
[ "$got" = " (model=grok-4.6, effort=medium)" ] && ok "unpinned grok shows the grok-4.6 / medium defaults" || bad "unpinned grok pins: '$got'"
got=$(pins $'MODEL_grok=grok-4.7\nEFFORT_grok=low\n' grok)
[ "$got" = " (model=grok-4.7, effort=low)" ] && ok "MODEL_grok / EFFORT_grok reach the grok line" || bad "file grok pins: '$got'"
got=$(pins $'MODEL_grok=grok-4.7\n' grok GROK_REVIEW_MODEL=env-grok)
[ "$got" = " (model=env-grok, effort=medium)" ] && ok "GROK_REVIEW_MODEL beats MODEL_grok on the line too" || bad "env grok pin: '$got'"
got=$(pins $'MODEL_opencode=zai/glm-5.3\n' opencode)
[ "$got" = " (model=zai/glm-5.3)" ] && ok "MODEL_opencode reaches the opencode line" || bad "opencode pin: '$got'"
got=$(pins '' opencode)
[ "$got" = " (model=cli default)" ] && ok "unpinned opencode says cli default" || bad "unpinned opencode: '$got'"
got=$(pins '' codex CODEX_REVIEW_MODEL=gpt-x)
[ "$got" = " (model=gpt-x, effort=cli default)" ] && ok "codex shows its model and an unpinned effort" || bad "codex pins: '$got'"
got=$(pins '' claude CLAUDE_REVIEW_MODEL=opus CLAUDE_REVIEW_FALLBACK_MODEL=sonnet CLAUDE_REVIEW_EFFORT=high)
[ "$got" = " (model=opus, fallback=sonnet, effort=high)" ] && ok "claude shows model, fallback and effort" || bad "claude pins: '$got'"
# cursor and antigravity read the load-time globals the scripts set from panel_resolve. The globals
# are resolved here the way the scripts resolve them, so MODEL_agy — an alias the PARSER maps onto
# MODEL_antigravity — is proven to reach the line, not just a value passed in by hand.
seatglob() { # $1 = config body, $2 = seat; resolves CURSOR/AGY like pr-review-relay:179-190
  printf '%s' "$1" >"$CFG"
  env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
    bash -c 'set -u; . "$0"; panel_config_load 2>/dev/null
      CURSOR_REVIEW_MODEL="$(panel_resolve CURSOR_REVIEW_MODEL MODEL_cursor composer-2.5)"
      AGY_REVIEW_MODEL="$(panel_resolve AGY_REVIEW_MODEL MODEL_antigravity "")"
      panel_seat_pins "$1"' "$LIB" "$2"
}
got=$(seatglob '' cursor)
[ "$got" = " (model=composer-2.5)" ] && ok "unpinned cursor shows composer-2.5" || bad "cursor default: '$got'"
got=$(seatglob $'MODEL_cursor=composer-9\n' cursor)
[ "$got" = " (model=composer-9)" ] && ok "MODEL_cursor reaches the cursor line" || bad "cursor pin: '$got'"
got=$(seatglob '' antigravity)
[ "$got" = " (model=cli default)" ] && ok "unpinned antigravity says cli default" || bad "antigravity default: '$got'"
got=$(seatglob $'MODEL_agy=gemini-x\n' antigravity)
[ "$got" = " (model=gemini-x)" ] && ok "MODEL_agy (alias) reaches the antigravity line" || bad "MODEL_agy alias: '$got'"
# Every global unset, under set -u: must not abort (both callers run set -u).
got=$(pins '' claude)
rc=$?
[ "$rc" = 0 ] && [ "$got" = " (model=cli default, fallback=none, effort=cli default)" ] &&
  ok "claude with no globals set does not abort under set -u" || bad "claude unset globals: rc=$rc '$got'"
# A seat with no pin, and a name nobody knows: empty, exit 0 — never an error.
got=$(pins '' qwen)
rc=$?
[ "$rc" = 0 ] && [ -z "$got" ] && ok "qwen (no pin) prints nothing" || bad "qwen: rc=$rc '$got'"
got=$(pins '' no-such-seat)
rc=$?
[ "$rc" = 0 ] && [ -z "$got" ] && ok "an unknown seat prints nothing and succeeds" || bad "unknown seat: rc=$rc '$got'"
# A caller that sources lib-panel.sh ALONE (pr-review-distill does) gets nothing for grok rather
# than "command not found".
got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG=/dev/null \
  bash -c 'set -u; . "$0"; panel_seat_pins grok' "$LIB" 2>&1)
rc=$?
[ "$rc" = 0 ] && [ -z "$got" ] && ok "grok pins without lib-grok.sh print nothing, no error" || bad "grok without its lib: rc=$rc '$got'"

# --- the pi seats (lib-pi.sh) ---------------------------------------------------
# pins() above does not source lib-pi.sh, so a positive pi case through it would print nothing and
# pass for the wrong reason — the same result as the negative case. pipins() sources it too.
PLIB="$HERE/../lib-pi.sh"
pipins() { # $1 = config body, $2 = seat, rest = VAR=value assignments for the call
  local body="$1" seat="$2"
  shift 2
  printf '%s' "$body" >"$CFG"
  env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" "$@" \
    bash -c 'set -u; . "$0"; . "$1"; . "$2"; . "$3"; panel_config_load 2>/dev/null; panel_seat_pins "$4"' "$LIB" "$OLIB" "$GLIB" "$PLIB" "$seat"
}
out=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
  bash -c 'printf "MODEL_pi_glm=a\nEFFORT_pi_glm=b\nMODEL_pi_grok=c\nEFFORT_pi_grok=d\n" > "$2"; . "$0"; panel_config_load 2>&1 >/dev/null' "$LIB" x "$CFG")
[ -z "$out" ] && ok "MODEL_/EFFORT_ keys for pi_glm and pi_grok load with no warning" || bad "pi seat keys warned about — got: $out"
got=$(pipins '' pi_glm)
[ "$got" = " (model=zai/glm-5.3, effort=low)" ] && ok "unpinned pi_glm shows zai/glm-5.3 / low" || bad "unpinned pi_glm: '$got'"
got=$(pipins '' pi_grok)
[ "$got" = " (model=xai/grok-4.7, effort=low)" ] && ok "unpinned pi_grok shows xai/grok-4.7 / low" || bad "unpinned pi_grok: '$got'"
got=$(pipins $'MODEL_pi_grok=xai/grok-9\nEFFORT_pi_grok=medium\n' pi_grok)
[ "$got" = " (model=xai/grok-9, effort=medium)" ] && ok "MODEL_pi_grok / EFFORT_pi_grok reach the pi_grok line" || bad "file pi_grok pins: '$got'"
got=$(pipins $'EFFORT_pi_glm=medium\n' pi_glm PI_GLM_REVIEW_EFFORT=high PI_GLM_REVIEW_MODEL=zai/env)
[ "$got" = " (model=zai/env, effort=high)" ] && ok "PI_GLM_REVIEW_* beat the config on the line too" || bad "env pi_glm pins: '$got'"
got=$(pins '' pi_glm)
rc=$?
[ "$rc" = 0 ] && [ -z "$got" ] && ok "pi_glm pins without lib-pi.sh print nothing, no error" || bad "pi_glm without its lib: rc=$rc '$got'"

# Parsing is fail-noisy, never fail-silent: a config that disappears without a word is the very
# defect this file exists to remove.
out=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
  bash -c 'printf "TYPO_KEY=x\nno-equals-here\n" > "$2"; . "$0"; panel_config_load 2>&1 >/dev/null' "$LIB" x "$CFG")
printf '%s' "$out" | grep -q "unknown key" && ok "an unknown key is reported" || bad "unknown key swallowed"
printf '%s' "$out" | grep -q "malformed" && ok "a malformed line is reported" || bad "malformed line swallowed"

# The file is READ, never SOURCED. A config that executes is arbitrary code run by a tool that
# runs from cron.
canary="$WORK/pwned"
env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
  bash -c 'printf "REVIEWERS=\$(touch %s)\n" "$3" > "$2"; . "$0"; panel_config_load >/dev/null 2>&1' "$LIB" x "$CFG" "$canary"
[ -e "$canary" ] && bad "the config file was EXECUTED — command substitution ran" ||
  ok "the config is read, never sourced (no command substitution)"

# The KEY side of the same rule, which the test above does not cover. `printf -v name[i]` assigns
# to an array element and bash evaluates that subscript as arithmetic — so MODEL_x[$(cmd)] would
# run cmd while the file was merely being parsed. The key must be a bare identifier first.
for inj in 'MODEL_x[$(touch %s)]=y' 'MODEL_x[`touch %s`]=y' 'EFFORT_a[$(touch %s)]=z'; do
  canary="$WORK/pwned-key"
  rm -f "$canary"
  printf "$inj\n" "$canary" >"$CFG"
  out=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
    bash -c '. "$0"; panel_config_load; panel_resolve NOPE REVIEWERS d' "$LIB" 2>&1)
  if [ -e "$canary" ]; then
    bad "key injection EXECUTED a command: $inj"
  elif printf '%s' "$out" | grep -q "invalid key"; then
    ok "an injected key is rejected and reported: ${inj%%=*}"
  else bad "injected key neither ran nor was reported: $inj (out: $out)"; fi
done
rm -f "$WORK/pwned-key"

# A key that is a plain identifier but unknown is still just an unknown key — the charset check
# must not swallow that distinction, or the warning stops telling you which mistake you made.
out=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
  bash -c 'printf "NOT_A_KEY=1\n" > "$2"; . "$0"; panel_config_load; panel_resolve NOPE REVIEWERS d' "$LIB" x "$CFG" 2>&1)
printf '%s' "$out" | grep -q "unknown key" && ok "a valid-looking but unknown key still says 'unknown key'" ||
  bad "unknown identifier key misreported — got: $out"

# PANEL_CFG_* is the loader's output, not an input. An exported one would be a fifth precedence
# layer nobody documented, outranking the script default — cursor coming back through the very fix
# that removed it. This is asserted with NO config file, the case where the leak survives longest.
got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$WORK/absent" PANEL_CFG_REVIEWERS=cursor \
  bash -c '. "$0"; panel_config_load 2>/dev/null; panel_resolve NOPE REVIEWERS "$1"' "$LIB" 'claude,codex,grok,opencode')
[ "$got" = "claude,codex,grok,opencode" ] && ok "an inherited PANEL_CFG_* is not a precedence layer" ||
  bad "PANEL_CFG_REVIEWERS from the environment won — got '$got'"

# ...and it must not survive a load that DOES find a file either, for a key that file omits.
got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" PANEL_CFG_MODEL_claude=ghost \
  bash -c 'printf "REVIEWERS=claude\n" > "$2"; . "$0"; panel_config_load 2>/dev/null; panel_resolve NOPE MODEL_claude opus' "$LIB" x "$CFG")
[ "$got" = "opus" ] && ok "an inherited PANEL_CFG_* is dropped for a key the file omits" ||
  bad "stale PANEL_CFG_MODEL_claude survived the load — got '$got'"

# Sourced from a shell that is not bash. The reset that stops an inherited PANEL_CFG_* from acting
# as a precedence layer used `${!PANEL_CFG_@}`, a bash-only expansion: under zsh it was a
# `bad substitution` that aborted panel_config_load mid-way. The first fix returned early on a
# non-bash shell — which SKIPPED the reset, so PANEL_CFG_REVIEWERS=cursor still won while the
# warning claimed nothing was loaded. Three reviewers caught that. The reset is now bounded and
# portable, and it runs before every return.
ZCFG="$WORK/other-shell.cfg" # never the shared $CFG: later cases reuse that file
if command -v zsh >/dev/null 2>&1; then
  printf 'REVIEWERS=from-file\nMODEL_grok=g46\n' >"$ZCFG"

  # THE FINDING: an inherited PANEL_CFG_* must not survive, on the shell where the sweep cannot run.
  got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$WORK/absent" PANEL_CFG_REVIEWERS=cursor \
    zsh -c '. "$0"; panel_config_load 2>/dev/null; panel_resolve NOPE REVIEWERS "$1"' "$LIB" 'claude,codex,grok,opencode')
  [ "$got" = "claude,codex,grok,opencode" ] && ok "zsh: an inherited PANEL_CFG_* is cleared, not honoured" ||
    bad "zsh: PANEL_CFG_REVIEWERS survived — got '$got'"

  # ...and a real file still loads there, rather than aborting on a bash expansion.
  got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$ZCFG" PANEL_CFG_REVIEWERS=cursor \
    zsh -c '. "$0"; panel_config_load 2>/dev/null; printf "%s|%s" "$(panel_resolve NOPE REVIEWERS d)" "$(panel_resolve NOPE MODEL_grok grok-4.5)"' "$LIB")
  [ "$got" = "from-file|g46" ] && ok "zsh: the config file loads (no bash-only expansion on the path)" ||
    bad "zsh: file did not load — got '$got'"

  err=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$ZCFG" \
    zsh -c '. "$0"; panel_config_load' "$LIB" 2>&1 >/dev/null)
  case "$err" in
    *"bad substitution"*) bad "zsh: still aborts on a bash expansion — got: $err" ;;
    *) ok "zsh: loading is silent, with no bad substitution" ;;
  esac
else
  echo "  skip [-] zsh not installed"
fi

# A SECOND load must not leave the first one's values behind — including a key for a seat this
# repo does not know, which is stored on purpose (ship-feature may know it) and therefore has to be
# cleared on purpose. The bounded reset cannot see such a key by construction, and the bash sweep
# is not available on every shell, so PANEL_CFG_KEYS from the previous load is what closes it.
for _sh in bash zsh; do
  command -v "$_sh" >/dev/null 2>&1 || {
    echo "  skip [-] $_sh not installed"
    continue
  }
  printf 'MODEL_future=old\nREVIEWERS=first\n' >"$WORK/load-a.cfg"
  printf 'REVIEWERS=second\n' >"$WORK/load-b.cfg"
  got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin "$_sh" -c '. "$0"
    PR_RELAY_CONFIG="$1" panel_config_load 2>/dev/null
    PR_RELAY_CONFIG="$2" panel_config_load 2>/dev/null
    printf "%s|%s" "$(panel_resolve NOPE MODEL_future none)" "$(panel_resolve NOPE REVIEWERS d)"' \
    "$LIB" "$WORK/load-a.cfg" "$WORK/load-b.cfg")
  [ "$got" = "none|second" ] && ok "$_sh: a second load clears the first one's unknown-seat key" ||
    bad "$_sh: stale key survived a reload — got '$got'"
done
unset _sh

# A bash parent EXPORTS BASH_VERSION, so a zsh or dash child inherits it. Any guard that reads
# that name to mean "this is bash" then runs the bash-only expansion in the wrong shell: under zsh
# a `bad substitution`, under dash an abort that takes the whole load with it. Every case above
# uses `env -i`, which scrubs the variable and hides this entirely — so it gets its own cases.
for _sh in zsh dash; do
  command -v "$_sh" >/dev/null 2>&1 || {
    echo "  skip [-] $_sh not installed"
    continue
  }
  got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$WORK/absent" \
    BASH_VERSION=5.2.0 PANEL_CFG_REVIEWERS=cursor \
    "$_sh" -c '. "$0"; panel_config_load 2>/dev/null; panel_resolve NOPE REVIEWERS "$1"' "$LIB" 'script-default')
  [ "$got" = "script-default" ] && ok "$_sh: an inherited BASH_VERSION does not trigger the bash-only sweep" ||
    bad "$_sh: inherited BASH_VERSION broke the load — got '$got'"

  err=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$WORK/absent" BASH_VERSION=5.2.0 \
    "$_sh" -c '. "$0"; panel_config_load' "$LIB" 2>&1 >/dev/null)
  case "$err" in
    *"ad substitution"*) bad "$_sh: inherited BASH_VERSION still causes a bad substitution — got: $err" ;;
    *) ok "$_sh: no bad substitution with BASH_VERSION inherited" ;;
  esac
done
unset _sh

# A shell with no `printf -v` at all — dash is the one that ships everywhere, so this case needs no
# extra dependency. Storing is impossible there, so the honest answer is to say so and load
# nothing; the reset has already run, so nothing inherited is left standing either.
if command -v dash >/dev/null 2>&1; then
  printf 'REVIEWERS=from-file\n' >"$ZCFG"
  err=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$ZCFG" PANEL_CFG_REVIEWERS=cursor \
    dash -c '. "$0"; panel_config_load' "$LIB" 2>&1 >/dev/null)
  printf '%s' "$err" | grep -q "printf -v" && ok "a shell without printf -v says so" ||
    bad "no printf -v, but no warning either — got: $err"

  got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$ZCFG" PANEL_CFG_REVIEWERS=cursor \
    dash -c '. "$0"; panel_config_load 2>/dev/null; panel_resolve NOPE REVIEWERS "$1"' "$LIB" 'script-default')
  [ "$got" = "script-default" ] && ok "a shell without printf -v still clears an inherited PANEL_CFG_*" ||
    bad "dash: inherited value survived the refusal — got '$got'"
else
  echo "  skip [-] dash not installed"
fi

# HOME unset — cron, systemd, containers. The relay supports it on purpose; a bare \$HOME under
# set -u would abort the whole run.
if env -u HOME -i PATH=/usr/bin:/bin bash -c 'set -u; . "$0"; panel_config_load; panel_resolve A B c' "$LIB" >/dev/null 2>&1; then
  ok "an unset HOME does not abort the loader"
else bad "unset HOME aborted panel_config_load"; fi

# --- review_looks_like_a_review ---------------------------------------------
# The relay used to fail closed only on an EMPTY review, so a stall or a fragment of
# garbage posted as a verdict and the round exited 0. Four such bodies were recovered
# byte-exact from ~/.cache/pr-review-relay on 2026-09-01 and are the fixtures below;
# they are the point of this helper, so they are quoted rather than paraphrased.
#
# NOT via resolve(): that runs under `env -i PATH=/usr/bin:/bin` for config-precedence
# reasons that do not apply here, and this helper needs the real PATH for grep/sed/tr.
# shellcheck source=relay/lib-panel.sh
. "$LIB"

# want: yes | no | stall  — "stall" pins the THREE-valued contract (0 a review,
# 1 no verdict, 2 a verdict then a stall). Collapsing every non-zero to "no" would
# leave the two rejection reasons interchangeable, and both callers now print a
# different sentence for each.
rlr() { # rlr <yes|no|stall> <label> <body>
  local want="$1" label="$2" body="$3" got
  review_looks_like_a_review "$body"
  case $? in 0) got=yes ;; 2) got=stall ;; *) got=no ;; esac
  # NO collapse: "no" means exit 1 (no verdict) and "stall" means exit 2. Rewriting
  # one into the other would let a fixture keep passing after its rejection REASON
  # changed, and the two reasons now print different sentences to the human.
  if [ "$got" = "$want" ]; then ok "review gate: $label"; else bad "review gate: $label — got $got, want $want"; fi
}

# The four recovered failures. All exited 0. All were posted as verdicts.
rlr no "recovered A — capped at line 1183" \
  'The diff is capped at line 1183 — I need the rest of it before I can verify the PR against the plan. Let me read the remaining chunks.'
# B is why the stall check exists at all: it NAMES a severity, at a word boundary, not
# echoed from any prompt — and it is an agent saying it has not finished.
rlr stall "recovered B — names Blocker, still a stall" \
  'Blocker
- None visible in the readable portion of the diff (lines 1–1182 of the attachment). Reading the remainder before concluding.'
rlr no "recovered C — reading the rest" 'Reading the rest of the diff before reviewing.'
rlr no "recovered D — mojibake tool-call fragment" \
  '៭Read"},{"filePath":"/tmp/tmp.L1BXCtTGcA/oc-diff.auQm5v","offset":1318'

# Real closing lines from this panel, verbatim. A gate that rejects the reviews this
# repo's own reviewers actually write is the wrong gate — two of these three contain
# no severity word at all, which is why the approval list exists.
rlr yes "real: codex closing #37" 'No findings. `bin/ci` passed: 355 tests, 0 failures.'
rlr yes "real: grok closing #36" 'Looks good: stdin redirect replaces `-f` as planned, prompt and tests match.'
rlr yes "real: opencode closing #37" '**LGTM** — the diff implements the plan exactly.'

# Markers, including the plural headings reviewers actually use. `## Blockers` and
# `Nits:` are ordinary style; rejecting a finished review over them would be this
# gate failing at its own job.
rlr yes "severity: Blocker heading" '## Blocker
- something real'
rlr yes "severity: Blockers plural" '## Blockers
- two of them'
rlr yes "severity: Nits: plural" 'Nits:
- naming'
rlr yes "severity: Nit alone" 'Nit: the naming.'
rlr yes "severity: Should-fix alone" 'Should-fix: the guard.'
rlr yes "severity: Should-fixes" 'Should-fixes: a couple.'
# A bare period is not a sentence boundary: it also ends a filename, a path or a
# version, and the bodies this guards cite them constantly. Splitting on `.` instead
# of `. ` made every one of these accepted — measured.
rlr stall "stall ending in a filename" 'Blocker: none yet. Let me read attachment.txt.'
rlr stall "stall ending in a path" 'Blocker: none. Reading the rest of /tmp/oc-diff.auQm5v.'
rlr stall "stall ending in a version" 'Blocker: none. I need the rest before I can verify v1.2.'
rlr yes "severity: Should fix, space" 'Should fix: the thing.'
rlr yes "severity: bold markdown" '**Blocker** — none'
# MID-SENTENCE, which the plan asked for and every other positive fixture missed:
# they are all sentence-initial or headings, and mid-sentence is exactly where the
# [^a-z0-9_] boundary classes would regress first.
rlr yes "severity: Nit mid-sentence" 'There is one more Nit buried in the guard.'
rlr yes "approval: LGTM mid-sentence" 'Read it twice and it is LGTM as far as I can tell.'
# grok and opencode both found this hole: a marked stall phrased only with the words
# an earlier pass dropped. Restoring `before concluding` closes it, and it fires on
# no valid fixture — measured phrase by phrase.
rlr stall "stall: phrased only with 'before concluding'" 'Blocker: none yet, I will stop before concluding.'
rlr yes "approval: nothing to flag" 'Nothing to flag.'
rlr yes "approval: none found" 'Blockers: none found.'
rlr yes "approval: No blockers." 'No blockers.'
# pi_grok's whole answer, twice, on 2026-10-16 (feedback-hub Brakeman bump). The gate
# benched the seat for it, and the round ran with two of three reviewers (Fizzy #1421).
rlr yes "real: pi_grok clean verdict, No issues found" 'No issues found'
rlr yes "approval: No issues found." 'No issues found.'
rlr yes "approval: bare No issues" 'No issues.'
rlr yes "approval: singular, No issue found" 'No issue found.'
rlr stall "stall: No issues found so far, then still reading" 'No issues found so far. Let me read the rest.'
# One sentence, the stall phrase first and the verdict after it: only the second copy of the
# phrase list (the verdict-after-stall check) can accept this.
rlr yes "order: reading first, then No issues found" 'Let me read the rest
No issues found'
rlr no "boundary: no issuesfound is not a marker" 'grep printed no issuesfound and no_issues and noissues'
# Underscores are word characters, not boundaries. A raw transcript full of
# identifiers is exactly what a broken agent emits, and `monitor_nit_state` read as a
# verdict until this was fixed — measured, not imagined.
rlr no "boundary: identifier with _nit_" 'monitor_nit_state pending and nothing else'
rlr no "boundary: _blocker_ as a name" 'setting _blocker_ = 1 and moving on'
rlr no "boundary: should-fixs is not a marker" 'should-fixs: whatever'
rlr yes "case: uppercase severity" 'BLOCKER: the guard is missing.'
rlr yes "approval: bare LGTM" 'LGTM'
rlr yes "approval: lowercase" 'lgtm'

# Word boundaries. `nit` lives inside unit/init/monitor/definitely, `blocker` inside
# unblocked; a substring match would call ordinary prose a verdict.
rlr no "boundary: unit test" 'I read the unit test and it seemed fine to me.'
rlr no "boundary: initial/monitor" 'The initial monitor definitely needs work here.'
rlr no "boundary: unblocked" 'This unblocked the pipeline nicely.'

# Prompt echo. Every prompt contains TWO marker-bearing sentences, and the pair is
# hard-wrapped five different ways across the five sites — review-local breaks inside
# "If it looks / good" — so these are the real wrappings, not a tidy one-liner.
rlr no "echo: relay prompt (wraps after Nit.)" \
  'Report missing tests as Should-fix, unless the untested path is itself a Blocker.
Be concise. Group findings by severity: Blocker / Should-fix / Nit.
If it looks good, say so in one line.'
rlr no "echo: review-local prompt (wraps inside looks/good)" \
  'Report missing tests as Should-fix, unless the untested path is itself a
Blocker. Be concise. Group findings by severity: Blocker / Should-fix / Nit. If it looks
good, say so in one line.'
rlr no "echo: opencode prompt (wraps before Blocker)" \
  'Report missing tests as Should-fix, unless the untested path is itself a
Blocker. Be concise. Group findings by severity:
Blocker / Should-fix / Nit. If it looks good, say so in one line.'
rlr no "echo: in CAPS" \
  'REPORT MISSING TESTS AS SHOULD-FIX, UNLESS THE UNTESTED PATH IS ITSELF A BLOCKER. BE CONCISE. GROUP FINDINGS BY SEVERITY: BLOCKER / SHOULD-FIX / NIT. IF IT LOOKS GOOD, SAY SO IN ONE LINE.'

# The stall check must not eat a real review. "let me read" is also what a SUCCESSFUL
# codex run says on its way to a verdict — it runs without --output-last-message, so
# its stdout is a raw transcript. Hence: only when there is no approval marker, and
# only in the closing sentence.
# The exemption for an approving review is checked on the CLOSING SENTENCE only.
# Exempting the whole body accepted "Looks good. Let me read the remainder before
# concluding." — a stall wearing an approval. Order is what separates them.
rlr yes "stall: read first, verdict last" 'After reading the rest of the diff, this looks good.'
rlr stall "stall: verdict first, then still reading" 'Looks good. Let me read the remainder before concluding.'
# The stall anchor is the closing sentence OF THE LAST NON-EMPTY LINE, and both halves
# were measured rejecting real reviews before they were added.
# Line: collapsing newlines merged narration into the review that followed it, which
# is the shape of a raw codex transcript.
rlr yes "anchor: raw transcript, review on later lines" 'Let me read the rest

Should-fix
- The guard is wrong'
# Verdict of EITHER kind immunises the closing sentence, not only approval: a finding
# may legitimately quote a stall phrase as its example.
# DELIBERATE COST OF THE ORDER RULE, and a change of position: grok asked for this
# to be accepted, and it was, until the order rule landed. It is not separable from
# `Blocker` + `Reading the remainder before concluding.` — both are a verdict
# followed by a stall phrase in one sentence, and no surface rule tells a quoted
# phrase from a real announcement.
#
# So the choice is which way to err. Rejecting this costs a failed round on a review
# that QUOTES a stall phrase — and the only body realistically doing that is a review
# of this very feature, which is how grok hit it. Accepting it costs the bug this
# whole change exists to close, silently. Fail closed.
#
# The rejected body is printed in full on stderr, so a human sees in one line that
# the gate was wrong rather than the reviewer.
rlr stall "cost: a finding that QUOTES a stall phrase is rejected" 'Nit: drop "let me read" from the comment.'
rlr yes "anchor: severity in the closing sentence" 'Should-fix: check this before I can merge.'
# "! " and "? " end sentences too, not only ". ".
rlr stall "anchor: question mark ends a sentence" 'Blocker: none. Should I read the remainder before concluding? Let me read the rest'
# Line wraps must not decide the verdict. Anchoring to the last physical LINE was
# tried and broke in BOTH directions, measured: the first of these was accepted
# because the closing line is "concluding.", and the second was rejected because
# its heading sat one line up. Normalising before anchoring is what fixes both.
rlr stall "wrap: a stall broken across a line" 'Blocker
- None visible yet. Let me read the remainder before
concluding.'
rlr yes "wrap: a finding whose heading is on the line above" 'Blocker
- Sanitize the path before I can approve this.'
rlr yes "wrap: the same finding written inline" 'Blocker: Sanitize the path before I can approve this.'
# Markdown emphasis is stripped before anything is matched. Without that the prompt
# strip is byte-literal while the marker matcher is not, so a bolded echo survived
# the strip and then satisfied the matcher.
rlr no "echo: prompt echoed in markdown emphasis" 'Report missing tests as **Should-fix**, unless the untested path is itself a **Blocker**. Be concise. Group findings by severity: **Blocker** / **Should-fix** / **Nit**. If it looks good, say so in one line.'
# ORDER, not presence. Both of the next two hold a marker and a stall phrase in the
# same closing sentence once whitespace is collapsed; only their order differs, and
# every anchoring rule tried before this one fixed one and broke the other in a loop.
# "I was reading, and here is my verdict" is a review; "here is my verdict, and I am
# still reading" is not.
rlr stall "order: verdict first, then still reading (no punctuation)" 'Blocker
Reading the remainder before concluding.'
rlr stall "order: approval first, then still reading (no punctuation)" 'Looks good
Let me read the remainder before concluding.'
rlr yes "order: reading first, verdict last" 'Let me read the rest

Should-fix
- The guard is wrong'
# Phrases that are ordinary review English were dropped, and that is what made the
# two bodies above separable at all. Measured: of the eight original phrases,
# `before i can` was the ONLY one firing on this valid finding, and it fired on NONE
# of the four recovered failures.
rlr yes "phrase: a finding that says 'before I can'" 'Blocker
- Sanitize the path before I can approve this.'
rlr yes "phrase: boundary, let me readjust" 'Blocker: the guard is wrong.

Let me readjust the retry timer.'
rlr yes "phrase: past tense, I read the remaining" 'Should-fix: add a case.

I read the remaining tests as well.'
rlr stall "stall: recovered B is reported AS a stall" 'Blocker
- None visible in the readable portion of the diff. Reading the remainder before concluding.'
rlr no "no verdict is reported as no verdict" 'Reading the rest of the diff before reviewing.'
rlr yes "stall: narration first, verdict last" \
  'Let me read the diff first. Now checking the tests. Should-fix: the helper needs a guard.'

# Known limit, asserted so it is deliberate rather than discovered: a negated approval
# still contains the approval marker.
rlr yes "known limit: negated approval passes" 'I do not think this looks good.'

# A closing VERDICT line. A clean review may name no severity and never say "looks good",
# so `VERDICT: clean` is the approval; a findings line names its severities.
rlr yes "VERDICT: clean is a verdict" 'No issues.
VERDICT: clean'
rlr yes "a VERDICT: findings line is a verdict" 'The guard is wrong.
VERDICT: findings blockers=1 should_fix=0'

# A large body must be handled at all — no argv limit, no truncation, no pipeline
# accident. This does NOT catch a `-q` regression: measured on GNU grep 3.11, `-q`
# returns 0 up to 5MB because grep drains its input, so swapping it back is
# behaviourally identical here. The helper avoids `-q` on portability grounds, not
# because this fixture would fail without it — said plainly, because a test that
# looks like it guards something it does not is worse than no test.
_rlr_big="LGTM — everything checks out.
$(head -c 200000 /dev/zero | tr '\0' 'x')"
rlr yes "pipefail: 200 KB body with a marker at the start" "$_rlr_big"

# Empty belongs to the callers' own empty branch, which has its own message and dumps
# stderr. The helper still says no, so ordering is the callers' responsibility.
rlr no "empty body" ''

# --- codex_no_mcp_args / codex_no_mcp_append ---------------------------------
# Every [mcp_servers.<name>] table header becomes one -c override, in config order, each name
# once: spaces around the parts, a trailing comment and a quoted plain name are all read. Tool
# sub-tables, array tables, other sections, an unsafe quoted name and a missing config add nothing.
_cx=$(mktemp -d)
cat >"$_cx/config.toml" <<'TOML'
model = "x"
[mcp_servers.buffer] # remote, OAuth
url = "https://mcp.buffer.com/mcp"
[mcp_servers.buffer.tools.create_post]
approval_mode = "approve"
  [ mcp_servers . app-tools ]
command = "node"
[mcp_servers."stripe"]
[mcp_servers."has.dot"]
[[mcp_servers.listed]]
[mcp_servers.buffer]
# [mcp_servers.commented]
[tui]
TOML
_want="mcp_servers.buffer.enabled=false mcp_servers.app-tools.enabled=false mcp_servers.stripe.enabled=false "
_got=$(CODEX_HOME="$_cx" codex_no_mcp_args | tr '\n' ' ')
if [ "$_got" = "$_want" ]; then ok "codex_no_mcp_args: one override per server, the TOML header forms"; else bad "codex_no_mcp_args: got '$_got', want '$_want'"; fi
# No external command: with nothing on PATH the result is the same (the relay calls it before
# its PATH guard, so a sed or sort from the checkout must never run).
_got=$(env -i CODEX_HOME="$_cx" PATH=/nonexistent "$BASH" -c '. "$1"; codex_no_mcp_args' _ "$LIB" | tr '\n' ' ')
if [ "$_got" = "$_want" ]; then ok "codex_no_mcp_args: runs no external command"; else bad "codex_no_mcp_args with an empty PATH: got '$_got'"; fi
_got=$(CODEX_HOME="$_cx/missing" codex_no_mcp_args)
if [ -z "$_got" ]; then ok "codex_no_mcp_args: no config, no overrides"; else bad "codex_no_mcp_args: missing config gave '$_got'"; fi
_arr=(-m pin)
CODEX_HOME="$_cx" codex_no_mcp_append _arr
_got="${_arr[*]}"
if [ "$_got" = "-m pin -c mcp_servers.buffer.enabled=false -c mcp_servers.app-tools.enabled=false -c mcp_servers.stripe.enabled=false" ]; then
  ok "codex_no_mcp_append: appends -c pairs after the existing items"
else bad "codex_no_mcp_append: got '$_got'"; fi
if codex_no_mcp_append 'x;y' 2>/dev/null; then bad "codex_no_mcp_append accepted a bad array name"; else ok "codex_no_mcp_append: refuses a bad array name"; fi
rm -rf "$_cx"

echo "-------------------------------------------"
echo "panel config tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
