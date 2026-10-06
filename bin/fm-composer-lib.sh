#!/usr/bin/env bash
# bin/fm-composer-lib.sh - the ONE fleet-wide owner of composer classification:
# every shape a verified harness draws, every glyph, every container proof, and
# the empty|pending|pending-unproven|unknown verdict, shared by every
# session-provider adapter (tmux via bin/fm-tmux-lib.sh, and
# bin/backends/{herdr,orca,cmux,zellij}.sh) and by fm-spawn.sh's kimi
# launch-readiness check.
#
# WHY THIS EXISTS (tasks fm-composer-shellglyph-safety and
# fm-composer-thin-adapter-refactor-r1): the adapters each carried their own
# copy of composer shape knowledge, and every copy drifted. The audited result
# (data/fm-composer-consolidation-audit-s1) was a 5-adapter x 6-harness matrix
# in which no adapter was right about more than five harnesses, no two adapters
# were wrong in the same places, and one harness was unreadable everywhere.
# The consolidation rule that prevents a recurrence: an adapter CAPTURES a
# screen and DESCRIBES its capabilities; it never classifies. A new harness
# shape is taught to fm_composer_classify_screen below, once, and every backend
# that can capture a screen learns it in the same commit.
#
# THE CAPABILITY MODEL: adapters differ in what their capture primitive can
# see, and those differences enter here as DATA (the <caps> argument), never as
# adapter code. Capability differences change how CONFIDENTLY a shape can be
# judged; they never change what the shapes ARE:
#   styled=1    the capture preserves ANSI styling, so ghost/placeholder text
#               is detectable and can be stripped (tmux -e, herdr --format
#               ansi, zellij dump-screen --ansi). With styled=0 (cmux, orca)
#               ghost text is unreadable, so a bare glyph row or left-bar row
#               carrying trailing non-idle text degrades to `unknown` rather
#               than `pending`: the text may be the harness's own idle
#               suggestion, and a false `pending` blocks every safe caller.
#   cursor=1    a cursor row is supplied (tmux #{cursor_y} only). The cursor
#               anchors shape selection: the shape containing the cursor is the
#               composer. Without it, the bottom-most shape wins.
#   identity=1  a native agent identity/state probe exists (herdr `agent get`;
#               the tmux pi foreground-process probe). Identity is what makes
#               Pi's blank separated composer provable; with identity=0 that
#               shape stays `unknown`.
#   rows=<n>    the capture's bounded row count (informational).
#
# THE STRICT BLANK-ROW RULE (captain decision blank-row-injection-posture,
# 2026-08-09): a blank or otherwise unidentified input row with no positive
# container proof is `unknown` and callers defer. This replaced tmux's
# permissive "blank cursor row = empty = safe to inject" rule fleet-wide: a
# blank row under the cursor can be a modal dialog, a dead shell between
# transcript rules, or a mid-redraw pane, and the away-mode injector types
# escalations into whatever it calls empty. Positive container proof means one
# of the shapes in the catalogue below.
#
# THE SHAPE CATALOGUE (all verified against real harnesses; byte-level
# captures in data/fm-composer-consolidation-audit-s1/report.md and
# docs/verification/runtime-backends.md):
#   bordered   - a complete boxed composer: a top border, side-bordered content
#                rows of the same family, and a bottom border (grok, kimi,
#                older claude). The bottom border may carry a TITLE (grok
#                writes its model name there); a titled bottom border that
#                still starts and ends with the family's rule glyph is
#                tolerated, including Grok 1.0.5's three-column title overhang.
#   bare       - an agent prompt glyph row with no border at all (claude `❯`,
#                codex `›`, muse `⟩`, cursor `→`, devin `❭`). The agent glyph is itself the container
#                proof; a bare SHELL glyph (`>` `$` `%` `#`) never is.
#                A bare composer's WRAP region (typed input continuing on the
#                rows beneath the glyph row) is bounded by blank rows, by
#                structural edges, and by the FURNITURE rows a harness draws
#                directly below its composer - omp's status row and
#                braille-only animation rows (declared once below, next to
#                the idle placeholders) - none of which is ever typed input.
#   left-bar   - opencode: rows prefixed by a heavy left bar `┃` with no
#                closing border, holding the idle hint, blank rows, and a
#                mode/model footer line.
#   separated  - pi: content rows between two solid horizontal `─` rules, no
#                glyph and no side border. Provable only with a live agent
#                identity reporting an idle/done pi (herdr `agent
#                get`; the tmux foreground-process probe), because a blank
#                region between two transcript rules is otherwise exactly the
#                strict rule's unidentifiable blank row.
#                A separated pair that closes over a bare AGENT-GLYPH row is a
#                different, self-proving thing: real claude 2.x draws exactly
#                that (`─` rule, `❯`+NBSP, `─` rule), so the glyph inside the
#                pair carries the shape and no identity is needed.
#   agy        - a `>` row between solid rules, followed immediately by its
#                shortcuts/cancel footer and model cell. The full structure,
#                never a bare shell glyph, proves this input region. Agy's
#                accept-edits hint needs styling to distinguish it from text;
#                without that evidence a matching hint remains unknown.
#   devin      - a `❭` row between a top mode rule and a solid bottom rule,
#                followed immediately by its model/context footer. The full
#                structure proves this input region. Its selector lives in
#                fork-only bin/fm-composer-devin-lib.sh, sourced below; this
#                classifier stays the only caller.
#
# THE COMPOSER FOOTER ZONE (task firstmate-doorbell-vals-pending-p1): a
# harness draws its own furniture BELOW the composer - a user statusLine, a
# permission-mode hint - and the cursorless "bottom-most shape wins" rule
# looks exactly there. `→` (U+2192) is Cursor's prompt glyph but ordinary text
# everywhere else, so a statusLine opening with `→` was selected as a bare
# composer, swallowed the hint row under it as wrapped input, and answered
# `pending` on a visibly empty pane; `fm_task_inbox_ring` defers on exactly
# that verdict, so every steer to a claude worker on herdr was skipped
# (measured live 2026-09-20, claude 2.1.236 on herdr 0.8.0, three of five
# panes). The rule is owned once, by the cursorless selection boundary: an
# ENVELOPE that CLOSED over an agent prompt glyph is a proven composer
# container, so a BARE candidate among the contiguous non-blank rows below its
# closing row is that composer's own footer furniture and not a composer. The
# proven envelope is selected instead; when its proving glyph row is itself
# borderless, that row is the bare candidate it stood for, and the envelope's
# staleness probe resumes past the zone.
#
# THE ASYMMETRY that bounds it: `empty` is the one verdict that authorizes
# fm-send to type into a pane, so this rule may move a verdict only toward
# REFUSING, never toward `empty`. A false refusal costs one undelivered
# message; a false `empty` overwrites a visible draft or types into a working
# agent. So the zone counts only when EVERY row in it is demonstrably furniture
# (_fm_composer_row_is_composer_furniture): one unclaimed activity row
# (`Working on request...`) makes the whole run activity and the envelope above
# it stale, and a row leading with the SAME glyph the envelope was proven by
# (`❯ my typed draft`) is a live composer that keeps winning. Where a shape
# cannot demonstrate which it is, the refusal is the answer. The zone is
# bounded further by a blank row, and an envelope that closed over no glyph row
# (codex's `permissions: YOLO mode` startup banner) proves nothing and demotes
# nothing.
#
# COVERAGE: this is exercised for the bordered box and the pi separator pair,
# the two shapes claude 2.x renders. The opencode left bar is wired in for the
# same treatment but is UNEXERCISED - every left-bar row this repo records
# leads with plain text, and opencode's own prompt character is `>`, a SHELL
# glyph deliberately outside the agent set, so no opencode shape recorded here
# can prove a left-bar envelope and open a zone under it.
#
# THE SAFETY RULE for glyphs: a bare shell prompt glyph (`>` `$` `%` `#`) -
# what a pane shows once its agent has exited to a plain login shell - is a
# genuine empty agent composer ONLY inside a bordered container. On a bare row
# it is a dead-shell prompt and classifies `unknown` (never a safe injection
# target). A `$` followed immediately by a digit is Pi's cost footer, not this
# prompt (`FM_COMPOSER_PI_STATUS_RE_DEFAULT`).
# The AGENT glyphs `❯` (claude), `›` (codex), `⟩` (U+27E9, muse),
# `→` (U+2192, cursor), and `❭` (U+276D, devin) are a genuine empty agent
# composer either way.
# Both glyph sets are declared
# exactly once below; every decision reaches them through the declarations.
#
# GHOST/PLACEHOLDER TEXT (task afk-herdr-false-pending): a harness fills an
# otherwise-empty composer with de-emphasized ghost text - claude's rotating
# prompt suggestion, codex's idle suggestion, grok's placeholder, or cursor's
# idle placeholder - which a
# plain capture cannot tell apart from text a human typed. codex-cli 0.154.0
# draws its `Ask Codex to do anything` placeholder as SGR-2 dim text after the
# bare `›` glyph, which fm_composer_strip_ghost removes.
# fm_composer_strip_ghost is the ONE ANSI-aware extractor of "real typed
# content": by default it drops every de-emphasized run - dim/faint (SGR 2) AND
# a dark/muted TRUECOLOR foreground - and keeps only normal-intensity,
# normally-coloured text. Its `codex-animation` mode instead normalizes an
# exact styled three-row region as documented on the function.
# Ghost stripping is a STYLE test, so it cannot see furniture a harness draws
# at normal intensity: codex-cli 0.154.0 animates a braille "starfield" around
# its idle composer in greys on both sides of the ghost luminance ceiling, so
# the brighter cells survive the strip and used to read as typed input. Those
# cells are recognised by SHAPE instead (fm_composer_strip_braille, declared
# next to the idle placeholders below), and only
# where a bare composer's furniture can sit: behind the glyph row's content
# and on the rows that bound its wrap region.
#
# UNICODE WHITESPACE (issue #1988; open PRs #1995/#2047 target the same
# defect and #1995's naming is adopted here so the implementations converge):
# a harness may separate its prompt glyph from composer content with a
# non-ASCII space. Real claude 2.x draws its EMPTY composer as exactly `❯`
# followed by U+00A0 NO-BREAK SPACE. POSIX `[[:space:]]` includes U+00A0 only
# under some locales, so every trim used to be locale-dependent: the same live
# pane read `empty` under a UTF-8 shell and `pending` under LC_ALL=C (a
# daemon, launchd, or ssh context), deferring every away-mode escalation.
# fm_composer_normalize_trim_var is the one fix: it maps every code point
# Unicode gives the property White_Space=Yes outside ASCII onto a plain ASCII
# space before any trim or comparison, byte-exactly, so the verdict cannot
# depend on the ambient locale. Glyph strips use literal byte-exact pattern
# removal for the same reason: `${v#?}` removes one BYTE under LC_ALL=C and
# one CHARACTER under UTF-8, which used to leave partial multibyte residue.
#
# Re-sourcing is a cheap idempotent redefinition, so this file needs no
# include guard (matching bin/fm-tmux-lib.sh).

# shellcheck source=bin/fm-composer-devin-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-composer-devin-lib.sh"

# fm_composer_strip_ansi: drop every CSI escape sequence, leaving plain text.
# Used for STRUCTURAL row/shape detection, where ghost text must be KEPT so the
# composer box border or bare prompt glyph is still visible; content extraction
# uses fm_composer_strip_ghost instead. Reads the styled text on stdin and prints
# plain text (stdin-only, matching fm_composer_strip_ghost). The character class
# includes ':' so an ITU colon-form SGR (38:2::r:g:b) is stripped whole, not left
# with a dangling tail.
fm_composer_strip_ansi() {
  local esc; esc=$(printf '\033')
  LC_ALL=C sed "s/${esc}\\[[0-9;:?]*[[:alpha:]]//g"
}

# Every code point Unicode gives the property White_Space=Yes that lies OUTSIDE
# ASCII, as UTF-8 byte sequences. Built from octal escapes rather than written
# literally so each entry stays reviewable in source instead of being an
# invisible character:
#   U+0085 NEXT LINE                  U+00A0 NO-BREAK SPACE
#   U+1680 OGHAM SPACE MARK           U+2000..U+200A EN QUAD..HAIR SPACE
#   U+2028 LINE SEPARATOR             U+2029 PARAGRAPH SEPARATOR
#   U+202F NARROW NO-BREAK SPACE      U+205F MEDIUM MATHEMATICAL SPACE
#   U+3000 IDEOGRAPHIC SPACE
# ASCII whitespace is absent because POSIX `[[:space:]]` already covers it.
# U+200B ZERO WIDTH SPACE is deliberately absent: Unicode gives it
# White_Space=No (a format character), so listing it would substitute this
# owner's own guess for the property it claims to follow. The live harness
# guard (bin/fm-test-run.sh, live-harness-optin) is what catches a harness
# that starts drawing its composer with a character outside this property.
FM_COMPOSER_UNICODE_SPACES=()
for _fm_composer_space_octal in \
  '\0302\0205' '\0302\0240' '\0341\0232\0200' \
  '\0342\0200\0200' '\0342\0200\0201' '\0342\0200\0202' '\0342\0200\0203' \
  '\0342\0200\0204' '\0342\0200\0205' '\0342\0200\0206' '\0342\0200\0207' \
  '\0342\0200\0210' '\0342\0200\0211' '\0342\0200\0212' \
  '\0342\0200\0250' '\0342\0200\0251' '\0342\0200\0257' \
  '\0342\0201\0237' '\0343\0200\0200'; do
  printf -v _fm_composer_space_utf8 '%b' "$_fm_composer_space_octal"
  FM_COMPOSER_UNICODE_SPACES+=("$_fm_composer_space_utf8")
done
unset -v _fm_composer_space_octal _fm_composer_space_utf8

# fm_composer_normalize_spaces_var: the ONE Unicode-whitespace mapping.
# Replaces in place through the named variable so no caller needs a subshell.
# Substitution, never deletion: deleting would silently join "foo<NBSP>bar"
# into one token, while a space preserves the separation the harness drew.
fm_composer_normalize_spaces_var() {  # <varname>
  local __fmns_name=$1 __fmns_text=${!1} __fmns_space
  for __fmns_space in "${FM_COMPOSER_UNICODE_SPACES[@]}"; do
    __fmns_text=${__fmns_text//"$__fmns_space"/ }
  done
  printf -v "$__fmns_name" '%s' "$__fmns_text"
}

# fm_composer_normalize_trim_var: the one whitespace-normalizing trim shared by
# this owner and every structural row scan - map Unicode whitespace onto ASCII
# space, then strip leading and trailing whitespace, in place through the named
# variable. Idempotent, locale-independent.
fm_composer_normalize_trim_var() {  # <varname>
  local __fmnt_name=$1 __fmnt_text
  fm_composer_normalize_spaces_var "$__fmnt_name"
  __fmnt_text=${!__fmnt_name}
  __fmnt_text="${__fmnt_text#"${__fmnt_text%%[![:space:]]*}"}"
  __fmnt_text="${__fmnt_text%"${__fmnt_text##*[![:space:]]}"}"
  printf -v "$__fmnt_name" '%s' "$__fmnt_text"
}

# fm_composer_holds_owned_text: 0 when a composer's <rows>, as
# fm_composer_extract_selected_content prints them with a U+001F separator,
# show exactly the sender's <text>. Each row must continue the text where the
# previous row stopped, and only the whitespace a row break swallowed may be
# skipped between rows, so a draft whose words or spacing changed inside a row
# is not the sender's. U+2063, the operational mark Claude Code removes from
# its composer, is ignored. With `residue`, rows that show a non-empty leading
# part of <text> also match: Ctrl+U deletes one wrapped row per press from the
# end of a Claude draft, so a cleanup in progress leaves a prefix.
fm_composer_holds_owned_text() {  # <text> <rows> [residue]
  local text=$1 rows=$2 row rest matched=0
  local -a parts=()
  text=${text//$'\xE2\x81\xA3'/}
  rows=${rows//$'\xE2\x81\xA3'/}
  fm_composer_normalize_spaces_var text
  rest="${text#"${text%%[![:space:]]*}"}"
  [ -n "$rows" ] || return 1
  IFS=$'\x1f' read -r -a parts <<< "$rows" || true
  for row in "${parts[@]}"; do
    [ -n "$row" ] || continue
    case "$rest" in
      "$row"*) rest=${rest#"$row"} ;;
      *) return 1 ;;
    esac
    matched=1
    rest="${rest#"${rest%%[![:space:]]*}"}"
  done
  [ "$matched" = 1 ] || return 1
  [ -z "$rest" ] || [ "${3:-}" = residue ]
}

# fm_composer_strip_ghost [codex-animation]: the ONE fleet-wide ANSI-aware
# extractor of "real typed content" from a styled capture. With no argument it
# reads styled rows on stdin (from `tmux capture-pane -e`, `herdr pane read
# --format ansi`, or `zellij action dump-screen --ansi`) and prints their plain,
# non-ghost text on stdout, dropping:
#   - dim/faint runs (SGR 2): how claude and codex render ghost/suggestion text.
#     A reset (SGR 0) or normal-intensity (SGR 22) ends a dim run.
#   - dark/muted TRUECOLOR foreground runs (SGR 38;2;r;g;b or the colon form
#     38:2::r:g:b) whose perceived luminance (0.299R + 0.587G + 0.114B) is below
#     FM_COMPOSER_GHOST_LUMA_MAX (default 128): how grok renders its placeholder
#     and hint text. A reset (SGR 0), a default-foreground (SGR 39), any base
#     foreground colour (30-37 / 90-97), or a lighter 38;2 foreground ends the
#     dark-foreground run. This assumes a DARK terminal theme, the firstmate
#     fleet reality, where real typed input is bright and only de-emphasised UI
#     is dark; the SGR-2 signal above stays theme-independent. A 256-colour
#     foreground (38;5;n) is NOT luminance-tested - it is palette-dependent and
#     no fleet harness uses it for ghost text, so it is kept (real text wins:
#     under-stripping merely defers, which the max-defer alarm surfaces, while
#     over-stripping would inject over real input).
# Raising FM_COMPOSER_GHOST_LUMA_MAX is not free: muse draws its `⟩` prompt glyph
# in truecolor 38;2;90;160;255, luminance ~149.9 (verified, muse 0.1.0-R708.1),
# the tightest margin over the 128 default in the fleet. Above ~150 that glyph is
# stripped as ghost text, which is why the bare-glyph fallback below must also
# recognise every agent glyph from the UNSTRIPPED plain row.
# In default mode the dim/faint and dark-foreground states are tracked together
# as "de-emphasis"; codes are processed left to right within a sequence, so
# "ESC[0;2m" reads as dim. LC_ALL=C makes awk walk bytes, so multibyte glyphs
# (e.g. ❯) and de-emphasised runs alike pass through or drop intact without
# locale-dependent classes.
#
# `codex-animation` requires exactly three rows sharing one TRUECOLOR background:
# decoration-only outer rows around a Codex prompt row. Any dim middle-row text
# must be the exact placeholder; when it is absent, the row must contain real
# input. A match strips only padding, the placeholder, and separately RGB-painted
# single-dot braille while preserving normal input, including typed braille. A
# mismatch exits nonzero without output so the caller retains the original screen
# for conservative classification.
fm_composer_strip_ghost() {
  LC_ALL=C awk -v codex_animation="${1:-}" \
    -v codex_prompt="$FM_COMPOSER_CODEX_PROMPT_GLYPH" \
    -v codex_prompt_alt='»' \
    -v lumamax="${FM_COMPOSER_GHOST_LUMA_MAX:-128}" '
    function sgr_code(v, b) {
      b = v
      sub(/:.*/, "", b)
      if (b == "") b = "0"
      return b
    }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode = a[p + 1]
      code = sgr_code(mode)
      if (index(mode, ":") > 0) return p + 1
      if (code == "5") return p + 2
      if (code == "2") return p + 4
      return p + 1
    }
    # fg38_is_dark: 1 when the SGR 38 foreground starting at param p is a
    # TRUECOLOR (38;2 / 38:2) whose luminance is below lumamax; 0 otherwise
    # (a 38;5 palette colour, a bright truecolor, or a malformed run).
    function fg38_is_dark(a, p, k, lumamax,   spec, nf, f, r, g, b) {
      spec = a[p]
      if (index(spec, ":") > 0) {           # colon form: whole colour in a[p]
        nf = split(spec, f, ":")
        if (f[2] != "2" || nf < 5) return 0
        r = f[nf - 2] + 0; g = f[nf - 1] + 0; b = f[nf] + 0
        return ((299*r + 587*g + 114*b) / 1000 < lumamax) ? 1 : 0
      }
      if (p + 1 > k || a[p + 1] != "2" || p + 4 > k) return 0
      r = a[p + 2] + 0; g = a[p + 3] + 0; b = a[p + 4] + 0
      return ((299*r + 587*g + 114*b) / 1000 < lumamax) ? 1 : 0
    }
    function codex_animation_decoration_width(line, pos, n, rgbfg, bg,   glyph) {
      if (substr(line, pos, 1) == " " && bg != "") return 1
      if (!rgbfg || bg == "" || pos + 2 > n) return 0
      glyph = substr(line, pos, 3)
      if (glyph == "⠁" || glyph == "⠂" || glyph == "⠄" || glyph == "⠈" ||
          glyph == "⠐" || glyph == "⠠" || glyph == "⡀" || glyph == "⢀") return 3
      return 0
    }
    {
      line = $0; if (codex_animation == "codex-animation") sub(/\r$/, "", line)
      out = ""; dim = 0; darkfg = 0; rgbfg = 0; bg = ""; ghost = ""; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {            # ESC: consume a CSI ... final-byte sequence
          j = i + 1
          if (substr(line, j, 1) == "[") {
            j++; params = ""
            while (j <= n) {
              cc = substr(line, j, 1)
              if (cc ~ /[@-~]/) break
              params = params cc; j++
            }
            if (j <= n && substr(line, j, 1) == "m") {   # SGR: update de-emphasis
              if (params == "") params = "0"
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38") {
                  rgbfg = (a[p + 1] == "2" && p + 4 <= k)
                  darkfg = fg38_is_dark(a, p, k, lumamax)
                  p = skip_color_payload(a, p, k)
                } else if (code == "48") {
                  if (a[p + 1] == "2" && p + 4 <= k)
                    bg = a[p + 2] "," a[p + 3] "," a[p + 4]
                  else bg = ""
                  p = skip_color_payload(a, p, k)
                } else if (code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") dim = 1
                else if (code == "0") { dim = 0; darkfg = 0; rgbfg = 0; bg = "" }
                else if (code == "22") dim = 0
                else if (code == "39") { darkfg = 0; rgbfg = 0 }
                else if (code == "49") bg = ""
                else if (code + 0 >= 30 && code + 0 <= 37) { darkfg = 0; rgbfg = 0 }
                else if (code + 0 >= 90 && code + 0 <= 97) { darkfg = 0; rgbfg = 0 }
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue          # lone/other ESC: drop the ESC byte only
        }
        if (codex_animation == "codex-animation") {
          # Every cell must share the placeholder background; the padding must
          # contain only coloured decoration, never normal-intensity input.
          if (bg == "") invalid = 1
          if (background == "") background = bg
          if (bg != background) invalid = 1
          if (dim) {
            ghost = ghost c
          } else {
            decoration = codex_animation_decoration_width(line, i, n, rgbfg, bg)
            if (decoration > 0) {
              if (c == " ") out = out c
              i += decoration - 1
            }
            else out = out c
          }
        } else if (dim == 0 && darkfg == 0) out = out c
        i++
      }
      if (codex_animation == "codex-animation") {
        gsub(/^[ \t]+|[ \t]+$/, "", out)
        clean[NR] = out
        if (NR == 2) {
          prompt_width = length(codex_prompt)
          if (substr(out, 1, prompt_width) != codex_prompt) {
            prompt_width = length(codex_prompt_alt)
            if (substr(out, 1, prompt_width) != codex_prompt_alt) invalid = 1
          }
          real = substr(out, prompt_width + 1)
          gsub(/^[ \t]+|[ \t]+$/, "", real)
          if (ghost == "Ask Codex to do anything") placeholder = 1
          else if (ghost != "") invalid = 1
          if (!placeholder && real == "") invalid = 1
        } else if (out != "" || ghost != "") invalid = 1
      } else print out
    }
    END {
      if (codex_animation == "codex-animation") {
        if (NR != 3 || invalid) exit 1
        print " "
        print clean[2]
        print " "
      }
    }
  '
}


# --- Delivery-only rendered busy footers (backend-agnostic) -------------------
#
# These live here, in the ONE shared composer/delivery owner, rather than in any
# single backend adapter, because every backend needs them for the SAME job:
# proving a submitted Enter actually landed. Keeping them in bin/fm-tmux-lib.sh
# made cursor's signature reachable only from tmux, even though herdr, zellij,
# cmux, and orca run the same harnesses and face the same acknowledgement
# problem.
#
# This is a DELIVERY guard, deliberately NOT a worker-state source. The semantic
# busy contract - what firstmate records and supervises on - is owned by
# bin/fm-busy-lib.sh, which forbids classifying a harness from rendered text.
# Matching a footer to confirm a keystroke landed is a different question from
# asking what a worker is doing, and the two must not be conflated.
# Delivery-only rendered busy footers per harness. claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working..."; omp: "Working…"; grok: "Ctrl+c:cancel"; agy: "esc to cancel";
# devin: "esc twice to interrupt" and its "❭ Guide Devin while it works" working composer.
# Claude's current spinner has a rotating glyph and word, but every active-turn
# line has an ellipsis followed by a parenthesized elapsed duration. Keep this
# signature separate from the shared default because that shape is not generic
# enough to classify arbitrary harness output safely.
# Kimi's anchored moon-phase spinner is separate because bare moon glyphs in
# ordinary output must not classify another harness as busy. Leading whitespace is
# OPTIONAL; whitespace on both sides of the separator is REQUIRED because every
# captured spinner row had it. A zero-whitespace form has NEVER been observed and
# is deliberately not matched. The line end is intentionally unanchored because
# rotating tip text follows and is not required to be present. The idle status
# bar's lowercase `thinking` label and independently rotating tip text are not
# busy signals on their own.
# The full moon-phase set remains locale- and emoji-font-sensitive because Kimi
# exposes no stable ASCII busy token.
# The harness-less default is the UNION of the per-harness tokens below, used
# when a caller has no recorded harness for the pane (the submit cores read the
# baseline and the post-Enter transition this way). cursor's `ctrl+c to stop` is
# part of that union for the same reason the others are: without it a cursor
# submit could never be acknowledged, because cursor parks its terminal cursor
# outside its composer and the composer verdict is therefore always `unknown`.
# agy's `esc to cancel` is part of the union for the same delivery reason: an
# explicit tmux agy endpoint reaches the submit core with no recorded harness,
# and when its composer becomes unreadable during a turn the idle-to-busy footer
# transition must acknowledge the submit so callers do not retry an already
# accepted command.
FM_DELIVERY_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working(\.\.\.|…)|Ctrl\+c:cancel|ctrl\+c to stop|esc[[:space:]]+to[[:space:]]+cancel|esc (twice|again) to interrupt|^[[:space:]]*❭ Guide Devin while it works$'
FM_DELIVERY_CLAUDE_BUSY_REGEX_DEFAULT='esc to interrupt|…[[:space:]]+\([0-9]+[smh]'
# Devin 3000.11.1: the working composer and interrupt hint are independent
# delivery signals. Neither is used as semantic worker-state evidence. Devin
# 3000.10.21 rendered the hint in parentheses, and after one Escape as `esc
# again to interrupt`; both spellings match.
FM_DELIVERY_DEVIN_BUSY_REGEX_DEFAULT='esc (twice|again) to interrupt|^[[:space:]]*❭ Guide Devin while it works$'
FM_DELIVERY_CODEX_BUSY_REGEX_DEFAULT='esc to interrupt'
FM_DELIVERY_OPENCODE_BUSY_REGEX_DEFAULT='esc interrupt'
FM_DELIVERY_PI_BUSY_REGEX_DEFAULT='Working\.\.\.'
# omp (Oh My Pi) renders its TUI busy line as `Working…` with U+2026 HORIZONTAL
# ELLIPSIS, not Pi's three ASCII dots (verified byte-level on omp 18.1.2,
# re-verified live on 18.1.11 through the Herdr backend). Only the TUI form is
# accepted: every supervised omp pane is the TUI, and the three-dot spelling its
# headless -p mode writes to stderr never reaches a pane. The status row's
# leading braille spinner plus elapsed cell (`⠧ 11s`) is the second, independent
# busy signal, so no single vendor string is load-bearing; its idle form is a
# static identity glyph with no elapsed time.
# The spinner is an alternation of omp 18.1.11's unicode-preset frames (its
# `status` set ⣾⣽⣻⢿⡿⣟⣯⣷ and `activity` set ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏, read from the
# build that rendered the live `⠧`), declared once for the busy regex and the
# status-row furniture rule below. It is deliberately NOT a bracket range over
# the braille block: GNU grep rejects a range between multibyte endpoints
# ("Invalid collation character"), so `[⠁-⣿]` compiled on macOS and failed
# every omp busy and furniture read on Linux CI.
FM_OMP_SPINNER_FRAMES_RE='(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|⣾|⣽|⣻|⢿|⡿|⣟|⣯|⣷)'
FM_DELIVERY_OMP_BUSY_REGEX_DEFAULT='Working…|^[[:space:]]*'"$FM_OMP_SPINNER_FRAMES_RE"'[[:space:]]+[0-9]+[smh]'
FM_DELIVERY_GROK_BUSY_REGEX_DEFAULT='Ctrl\+c:cancel'
# cursor-agent's busy footer. The TOKEN is matched, not the spinner verb: the
# same version rendered both `Working` and `Running` beside its braille spinner
# in two consecutive turns, while `ctrl+c to stop` was present for the whole
# turn and absent the instant it ended (verified live, 2026.08.11-e8db854).
# This is a DELIVERY guard only - it acknowledges a submit and gates away-mode
# injection. Cursor's recorded worker state comes from its transcript fold in
# bin/fm-busy-lib.sh, never from this row.
FM_DELIVERY_CURSOR_BUSY_REGEX_DEFAULT='ctrl\+c to stop'
# agy (Antigravity CLI) renders a pinned status row while a turn runs: the
# `esc to cancel` token on the left and the model cell on the right (verified
# live, agy 1.2.0; the idle row shows `? for shortcuts` instead). The
# `Generating...` spinner word beside it is a free-floating output line and is
# deliberately not matched, so echoed worker output cannot fake an
# acknowledgement. Delivery guard only; recorded worker state comes from the
# native agy hooks through bin/fm-busy-lib.sh.
FM_DELIVERY_AGY_BUSY_REGEX_DEFAULT='esc[[:space:]]+to[[:space:]]+cancel'
FM_DELIVERY_KIMI_BUSY_REGEX_DEFAULT='^[[:space:]]*(🌑|🌒|🌓|🌔|🌕|🌖|🌗|🌘)[[:space:]]+·[[:space:]]+'

fm_busy_lines_match() {  # [harness]
  local harness=${1:-} lines regex
  IFS= read -r -d '' lines || true
  if [ -n "${FM_BUSY_REGEX:-}" ]; then
    regex=$FM_BUSY_REGEX
  else
    case "$harness" in
      claude) regex=$FM_DELIVERY_CLAUDE_BUSY_REGEX_DEFAULT ;;
      devin) regex=$FM_DELIVERY_DEVIN_BUSY_REGEX_DEFAULT ;;
      codex) regex=$FM_DELIVERY_CODEX_BUSY_REGEX_DEFAULT ;;
      opencode) regex=$FM_DELIVERY_OPENCODE_BUSY_REGEX_DEFAULT ;;
      pi|pi-signed) regex=$FM_DELIVERY_PI_BUSY_REGEX_DEFAULT ;;
      omp) regex=$FM_DELIVERY_OMP_BUSY_REGEX_DEFAULT ;;
      grok) regex=$FM_DELIVERY_GROK_BUSY_REGEX_DEFAULT ;;
      agy) regex=$FM_DELIVERY_AGY_BUSY_REGEX_DEFAULT ;;
      kimi) regex=$FM_DELIVERY_KIMI_BUSY_REGEX_DEFAULT ;;
      cursor) regex=$FM_DELIVERY_CURSOR_BUSY_REGEX_DEFAULT ;;
      '') regex=$FM_DELIVERY_BUSY_REGEX_DEFAULT ;;
      *)
        # A supplied harness must never borrow another harness's signature.
        # Register its verified signature explicitly before classifying it busy.
        regex=
        ;;
    esac
  fi
  [ -n "$regex" ] && printf '%s' "$lines" | grep -qiE "$regex"
}

# The prompt glyphs, each declared exactly once (see THE SAFETY RULE above).
# AGENT glyphs are a genuine empty agent composer on any row, bordered or bare.
# SHELL glyphs are one only INSIDE a composer container; on a bare row they are
# a dead-shell prompt and must never read `empty`. Newline-separated and
# consumed by `read` rather than word splitting, so `$`, `%`, and `#` stay
# literal and no entry is ever exposed to pathname expansion.
FM_COMPOSER_CODEX_PROMPT_GLYPH='›'
# Codex 0.160.0 uses » for the live composer and › in the transcript.
FM_COMPOSER_AGENT_PROMPT_GLYPHS=$(printf '%s\n' '❯' "$FM_COMPOSER_CODEX_PROMPT_GLYPH" '»' '⟩' '→' '❭')
FM_COMPOSER_SHELL_PROMPT_GLYPHS=$(printf '%s\n' '>' '$' '%' '#')

# The ONE fleet-wide idle-placeholder set: composer text a harness renders in
# an EMPTY composer that a plain capture cannot tell from typed text. Grok's
# bordered placeholder and opencode's left-bar hint (which uses either three
# ASCII periods or U+2026 and continues with a rotating quoted suggestion,
# hence the unanchored tail). cursor-agent renders
# two, both anchored: `Plan, search, build anything` in a fresh session and
# `Add a follow-up` once a turn has completed (verified live on cursor-agent
# 2026.08.11-e8db854). Devin renders the anchored `Ask Devin to build features,
# fix bugs, or work on your code` as dim text after its `❭` glyph (verified
# live, devin 3000.11.1). FM_COMPOSER_IDLE_RE overrides for an unverified harness;
# matching is case-insensitive.
FM_COMPOSER_IDLE_RE_DEFAULT='^Type a message\.\.\.$|^Ask anything(\.\.\.|…)|^Plan, search, build anything$|^Add a follow-up$|^Ask Devin to build features, fix bugs, or work on your code$|^Guide Devin while it works$'
FM_COMPOSER_AGY_HINT='Accept-edits mode: file edits auto-approved (shift+tab to cycle)'
# Agy 1.2.0 renders this one hint in SGR 90, not dim/truecolor. Remove only
# this exact styled hint within the proven Agy shape; palette colours in any
# other text or harness retain the generic stripper's conservative handling.
FM_COMPOSER_AGY_HINT_STYLED=$(printf '\033[90m%s\033[39m' "$FM_COMPOSER_AGY_HINT")

# Opencode draws a mode/model footer line INSIDE its left-bar composer
# ("Build · GPT-5.5 Fast OpenAI · high"). It is composer furniture, not typed
# text, and only the run's LAST row is ever matched against it.
FM_COMPOSER_LEFTBAR_FOOTER_RE_DEFAULT='^(Build|Plan)([[:space:]]+auto)?[[:space:]]+·[[:space:]]+'
# Claude draws its permission-mode hint on its own row directly below the
# composer (` ⏵⏵ bypass permissions on (shift+tab to cycle)`, ` ⏵⏵ accept edits
# on`, ` ⏸ plan mode on`; verified live through Herdr on claude 2.1.236). The
# leading mode marker is the whole test - the trailing wording is free text and
# is deliberately not matched - and the marker is quantifier-free so the same
# bytes match under LC_ALL=C as under a UTF-8 locale.
FM_COMPOSER_MODE_HINT_RE_DEFAULT='^[[:space:]]*(⏵|⏸)'
# omp (Oh My Pi) draws a one-row status line directly BELOW its borderless
# composer: an identity or spinner cell, then middle-dot separated model, path,
# git, and context cells. Verified live through Herdr on omp 18.1.11:
# ` π  · ◔ GPT-6-Astra · 🌳 …-workspace · ⑂ detached · ◫ 15.4%/272K ⟲ · (sub)`
# idle under the unicode preset, ` 󰵗  ·  qwen3:8b ·  … ·  36.7%/41K` under
# nerd, and ` ⠧ 11s  · …` while busy. Without this rule the bare composer's
# wrap region walks straight into that row and an idle omp pane reads
# `pending`, the false verdict that skipped the doorbell on the first live omp
# worker. A row is omp status furniture when it opens with omp's identity cell
# then a middle dot (`π` under the unicode preset, `󰵗` under nerd: the
# `icon.omp` of those omp 18.1.11 presets, never an arbitrary short token, so
# a wrapped typed row such as `fix · tests` stays composer input; the ascii
# preset's `pi` is deliberately absent because that preset's `sep.dot` is
# ` - `, so its status row never carries a middle dot and a `pi ·` alternative
# could only ever match typed text), when it opens with one of omp's spinner
# frames then an elapsed cell, or when it carries the context-usage cell after
# a middle dot. It is consulted only as the boundary BELOW a bare composer,
# never on the composer row itself.
FM_COMPOSER_OMP_STATUS_RE_DEFAULT='^[[:space:]]*(π|󰵗)[[:space:]]+·[[:space:]]|^[[:space:]]*'"$FM_OMP_SPINNER_FRAMES_RE"'[[:space:]]+[0-9]+[smh]([[:space:]]|$)|[[:space:]]·[[:space:]].*[0-9]+(\.[0-9]+)?%/[0-9]+K'
# Pi's footer stats row opens at column 0 with the session cost when every
# token counter is zero (`$0.000 (sub) 5.4%/272k (auto)` on pi 0.85.1).
# That leading `$` is a cost cell, not a dead-shell prompt, only when a digit
# follows it immediately; `$` then whitespace stays a prompt.
# Consulted only as the dead-shell exception below, never as composer content,
# so the same string typed between the separator pair still reads pending.
FM_COMPOSER_PI_STATUS_RE_DEFAULT='^\$[0-9]+(\.[0-9]+)?([[:space:]]|$)'
# Braille-pattern cells (U+2800..U+28FF) are animation furniture: codex-cli
# 0.154.0 draws an idle "starfield" of them on the row above its `›` prompt
# row, on the `›` row itself after the dim `Ask Codex to do anything`
# placeholder, and on the row below it (verified live through Herdr on
# codex-cli 0.154.0, gpt-6-astra, fast mode). The cells are truecolor greys
# whose luminance straddles FM_COMPOSER_GHOST_LUMA_MAX, so the brighter ones
# survive ghost stripping. The rule, applied by shape rather than style:
#   - a row whose non-whitespace content is entirely braille cells is screen
#     furniture; it never counts as wrapped typed content and it bounds a bare
#     composer's wrap region exactly as the status rows above do;
#   - braille cells behind the glyph row's content are stripped before that
#     row's emptiness decision only when NOTHING else follows the glyph AND
#     the capture is styled AND every one of those cells carries its own
#     truecolor foreground (fm_composer_strip_painted_braille below) - the
#     animation's positive signature, because typed input renders in the
#     default foreground, so a braille-only draft such as `❯ ⠁⠂` stays input;
#   - a row that mixes braille with any other non-whitespace text stays typed
#     content, because a human can type a braille character.
# fm_composer_strip_braille is the ONE byte-exact remover: under LC_ALL=C awk
# walks bytes and drops every UTF-8 sequence E2 A0..A3 80..BF. It is
# deliberately not a grep bracket range over the block, for the reason
# FM_OMP_SPINNER_FRAMES_RE records (GNU grep rejects a range between multibyte
# endpoints). Reads stdin, prints the line with its braille cells removed.
fm_composer_strip_braille() {
  LC_ALL=C awk '
    {
      line = $0; out = ""; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\342" && i + 2 <= n) {
          c2 = substr(line, i + 1, 1); c3 = substr(line, i + 2, 1)
          if (c2 >= "\240" && c2 <= "\243" && c3 >= "\200" && c3 <= "\277") {
            i += 3; continue
          }
        }
        out = out c; i++
      }
      print out
    }
  '
}

# fm_composer_strip_painted_braille: drop only the braille cells painted with a
# truecolor foreground (SGR 38;2;R;G;B still active when the cell is drawn),
# keeping every other byte, escapes included. A braille cell in the default or
# a palette foreground survives, so feeding the result through
# fm_composer_strip_ansi and fm_composer_strip_braille distinguishes animation
# cells from typed ones. Reads stdin, prints each line.
fm_composer_strip_painted_braille() {
  LC_ALL=C awk '
    {
      line = $0; out = ""; n = length(line); i = 1; painted = 0
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033" && substr(line, i + 1, 1) == "[") {
          j = i + 2
          while (j <= n && substr(line, j, 1) ~ /[0-9;:?]/) j++
          if (j <= n && substr(line, j, 1) == "m") {
            np = split(substr(line, i + 2, j - i - 2), p, /[;:]/)
            if (np == 0) painted = 0
            for (k = 1; k <= np; k++) {
              if (p[k] == "" || p[k] + 0 == 0 || p[k] + 0 == 39) painted = 0
              else if (p[k] + 0 == 38 && p[k + 1] + 0 == 2) { painted = 1; k += 4 }
              else if (p[k] + 0 == 38 && p[k + 1] + 0 == 5) { painted = 0; k += 2 }
              else if ((p[k] + 0 >= 30 && p[k] + 0 <= 37) || (p[k] + 0 >= 90 && p[k] + 0 <= 97)) painted = 0
              else if (p[k] + 0 == 48 && p[k + 1] + 0 == 2) k += 4
              else if (p[k] + 0 == 48 && p[k + 1] + 0 == 5) k += 2
            }
          }
          out = out substr(line, i, j - i + 1); i = j + 1; continue
        }
        if (painted && c == "\342" && i + 2 <= n) {
          c2 = substr(line, i + 1, 1); c3 = substr(line, i + 2, 1)
          if (c2 >= "\240" && c2 <= "\243" && c3 >= "\200" && c3 <= "\277") {
            i += 3; continue
          }
        }
        out = out c; i++
      }
      print out
    }
  '
}

# The bounded row window for adapters that use tail-capture composer reads and
# for the shared inbox confirmation read. One shared policy (previously three
# per-backend variables that had drifted to 20/20/200) keeps stale scrollback
# (startup banners, old transcript boxes) out of those candidate sets. tmux
# and Herdr adapter composer reads use their visible viewports instead; Herdr
# also uses this value as the minimum Ctrl+U clear budget after a refused proof.
FM_COMPOSER_CAPTURE_LINES=${FM_COMPOSER_CAPTURE_LINES:-20}

# Pi allows a multi-line composer between its horizontal separators. Bound the
# structural candidate so two unrelated transcript rules with an arbitrarily
# large region between them can never be promoted into a composer.
FM_COMPOSER_PI_MAX_LINES=${FM_COMPOSER_PI_MAX_LINES:-8}

# Column overhang of Grok 1.0.5's titled bottom border over its aligned top
# and content rows, captured live in issue #3436's 2026-09-14 idle repro
# (see docs/verification/runtime-backends.md). Not re-verified against a live
# Grok install since; may need to change if a future Grok release renders a
# different overhang or scales it with title/model-name length.
FM_COMPOSER_GROK_TITLE_OVERHANG=3

# 0 when <content> is exactly one glyph drawn from <glyph-list>.
_fm_composer_is_prompt_glyph() {  # <content> <glyph-list>
  local content=$1 glyph
  while IFS= read -r glyph; do
    [ -n "$glyph" ] || continue
    [ "$content" = "$glyph" ] && return 0
  done <<EOF
$2
EOF
  return 1
}

# fm_composer_leading_prompt_glyph_var: set <out-varname> to the ONE prompt
# glyph <content> begins with once its leading whitespace is ignored, or to the
# empty string (returning 1) when it begins with none. Both glyph lists are
# reached here, so no caller can respell them and drift. Returning the matched
# glyph as a LITERAL string lets every caller remove it byte-exactly with
# `${v#"$glyph"}`, which is correct in every locale.
fm_composer_leading_prompt_glyph_var() {  # <out-varname> <content>
  local __fmpg_out=$1 __fmpg_text=$2 __fmpg_glyph
  __fmpg_text="${__fmpg_text#"${__fmpg_text%%[![:space:]]*}"}"
  while IFS= read -r __fmpg_glyph; do
    [ -n "$__fmpg_glyph" ] || continue
    case "$__fmpg_text" in
      "$__fmpg_glyph"*) printf -v "$__fmpg_out" '%s' "$__fmpg_glyph"; return 0 ;;
    esac
  done <<EOF
$FM_COMPOSER_AGENT_PROMPT_GLYPHS
$FM_COMPOSER_SHELL_PROMPT_GLYPHS
EOF
  printf -v "$__fmpg_out" '%s' ''
  return 1
}

# fm_composer_leading_agent_glyph_var: like the above but AGENT glyphs only.
# The bare-row shape must never be anchored by a shell glyph (dead-shell rule).
fm_composer_leading_agent_glyph_var() {  # <out-varname> <content>
  local __fmag_out=$1 __fmag_text=$2 __fmag_glyph
  __fmag_text="${__fmag_text#"${__fmag_text%%[![:space:]]*}"}"
  while IFS= read -r __fmag_glyph; do
    [ -n "$__fmag_glyph" ] || continue
    case "$__fmag_text" in
      "$__fmag_glyph"*) printf -v "$__fmag_out" '%s' "$__fmag_glyph"; return 0 ;;
    esac
  done <<EOF
$FM_COMPOSER_AGENT_PROMPT_GLYPHS
EOF
  printf -v "$__fmag_out" '%s' ''
  return 1
}

fm_composer_leading_shell_glyph_var() {  # <out-varname> <content>
  local __fmsg_out=$1 __fmsg_text=$2 __fmsg_glyph
  __fmsg_text="${__fmsg_text#"${__fmsg_text%%[![:space:]]*}"}"
  while IFS= read -r __fmsg_glyph; do
    [ -n "$__fmsg_glyph" ] || continue
    case "$__fmsg_text" in
      "$__fmsg_glyph"*) printf -v "$__fmsg_out" '%s' "$__fmsg_glyph"; return 0 ;;
    esac
  done <<EOF
$FM_COMPOSER_SHELL_PROMPT_GLYPHS
EOF
  printf -v "$__fmsg_out" '%s' ''
  return 1
}

fm_composer_idle_matches() {
  local content=$1 idle_re=$2 idle_case=$3
  [ -n "$idle_re" ] || return 1
  case "$idle_case" in
    insensitive) printf '%s' "$content" | grep -qiE "$idle_re" ;;
    *) printf '%s' "$content" | grep -qE "$idle_re" ;;
  esac
}

# fm_composer_classify_content: the single shared composer-content verdict.
#   <bordered> 1 when <content> came from a genuine agent-composer container (a
#              bordered composer box, an identity-proven separated composer, or
#              a structurally-identified left-bar row); 0 for a bare
#              agent-glyph row, where only the agent glyph itself is proof.
#   <content>  the candidate composer content, border-stripped by the caller.
#   [idle_re]  optional idle-placeholder regex; empty means no idle matching.
#              The screen classifier below passes the resolved fleet-wide idle
#              set; this parameter stays pure so a direct caller's semantics
#              cannot shift underneath it.
#   [idle_case] `sensitive` (default) or `insensitive`.
#   [plain_content] the UNSTRIPPED plain row, consulted when ghost stripping
#              emptied an unbordered row: muse's `⟩` sits at luminance ~150,
#              close enough to the ghost threshold that a raised threshold
#              strips it, and the plain row is what keeps that pane readable.
# Content and plain_content are normalized and re-trimmed on entry, so the
# verdict never depends on which whitespace alphabet the calling adapter
# trimmed with.
fm_composer_classify_content() {  # <bordered> <content> [idle_re] [idle_case] [plain_content] [placeholder-position] [styled]
  local bordered=$1 idle_re=${3:-} idle_case=${4:-sensitive} content plain_content glyph=''
  local placeholder_position=${6:-0} styled=${7:-1} idle_collision=0
  content=$2
  fm_composer_normalize_trim_var content
  plain_content=${5:-$2}
  fm_composer_normalize_trim_var plain_content
  if [ "$bordered" != 1 ] && [ -z "$content" ] && [ -n "$plain_content" ]; then
    if _fm_composer_is_prompt_glyph "$plain_content" "$FM_COMPOSER_AGENT_PROMPT_GLYPHS"; then
      printf 'empty'; return 0
    fi
    printf 'unknown'; return 0
  fi
  if _fm_composer_is_prompt_glyph "$content" "$FM_COMPOSER_AGENT_PROMPT_GLYPHS"; then
    printf 'empty'; return 0
  fi
  if _fm_composer_is_prompt_glyph "$content" "$FM_COMPOSER_SHELL_PROMPT_GLYPHS"; then
    if [ "$bordered" = 1 ]; then printf 'empty'; else printf 'unknown'; fi
    return 0
  fi
  [ -n "$content" ] || { printf 'empty'; return 0; }
  fm_composer_idle_matches "$content" "$idle_re" "$idle_case" && idle_collision=1
  if fm_composer_leading_prompt_glyph_var glyph "$content"; then
    content=${content#*"$glyph"}
  fi
  fm_composer_normalize_trim_var content
  [ -n "$content" ] || { printf 'empty'; return 0; }
  fm_composer_idle_matches "$content" "$idle_re" "$idle_case" && idle_collision=1
  # Ghost stripping can leave a REMNANT of an idle placeholder rather than
  # emptying it, because a terminal draws the cell under its cursor in reverse
  # video (SGR 7) - neither dim/faint nor a dark foreground, so that one
  # character survives a stripper built for the other two. cursor-agent renders
  # exactly this shape: a dim `Plan, search, build anything` whose first
  # character is reverse-video, leaving a lone `P` (verified live on
  # cursor-agent 2026.08.11-e8db854). Judging that remnant on its own reads
  # `pending` on a genuinely idle pane.
  # The plain row is the styling-independent signal, so consult it here. This
  # stays safe in the false-EMPTY direction because it demands the remnant be a
  # PROPER, strictly shorter substring of a plain row that matches a full
  # anchored placeholder: real typed text is uniformly bright, so stripping
  # leaves it EQUAL to the plain row and it falls through to `pending` below.
  # Typing a strict substring of a placeholder is equally safe - the plain row
  # is then that substring, which the anchored placeholder pattern cannot match.
  if [ "$idle_collision" != 1 ] && [ "$styled" = 1 ] && [ -n "$plain_content" ]; then
    local plain_body=$plain_content plain_glyph=''
    if fm_composer_leading_prompt_glyph_var plain_glyph "$plain_body"; then
      plain_body=${plain_body#*"$plain_glyph"}
    fi
    fm_composer_normalize_trim_var plain_body
    if [ "${#content}" -lt "${#plain_body}" ] \
       && fm_composer_idle_matches "$plain_body" "$idle_re" "$idle_case"; then
      case "$plain_body" in
        *"$content"*) printf 'empty'; return 0 ;;
      esac
    fi
  fi
  if [ "$idle_collision" = 1 ]; then
    if [ "$placeholder_position" = 1 ] && [ "$bordered" = 1 ] && [ "$styled" != 1 ]; then
      printf 'empty'; return 0
    fi
    if [ "$styled" != 1 ]; then
      printf 'unknown'; return 0
    fi
  fi
  printf 'pending'; return 0
}

# --- The screen classifier ---------------------------------------------------
#
# fm_composer_classify_screen <caps> <screen> [cursor_row] [identity]
#   <caps>       newline-separated key=value capability facts (see header).
#   <screen>     the captured screen: ANSI-preserving when styled=1, plain
#                otherwise.
#   [cursor_row] zero-based row index of the cursor within <screen>, only
#                meaningful when caps carry cursor=1.
#   [identity]   "<agent>\t<status>" from the backend's native identity probe,
#                or `probe-absent` when the probe found no live identity; only
#                meaningful when caps carry identity=1.
# Prints exactly one verdict: empty | pending | pending-unproven | unknown,
# or the internal sentinel `need-identity` when caps declare identity=1, no
# identity result was supplied, and the verdict depends on it. Adapters answer
# `need-identity` by running their identity probe once and re-calling with
# either its result or `probe-absent`; the sentinel never escapes an adapter.
# Identity stays a lazy second pass so the common non-pi read never pays for
# the probe.
#
# Consumers that can overwrite input or confirm delivery must accept only the
# exact positive proof they require (`empty`), so unrecognized future verdicts
# fail safe by default.

# _fm_composer_pi_separator_row: a solid pi separator - nothing but `─`, at
# least 8 columns wide. The width floor is a literal substring test so it is
# byte-exact in every locale.
_fm_composer_pi_separator_row() {  # <trimmed-row>
  local row=$1
  [ -n "$row" ] || return 1
  [ -z "${row//─/}" ] || return 1
  case "$row" in
    *────────*) return 0 ;;
  esac
  return 1
}

# _fm_composer_titled_rule_row: Claude Code's composer top rule for a named
# session, which carries the name near its right end: `──── name ─`. Claude
# gives the name the whole width before truncating it with `…`, so the leading
# run shrinks to any length and disappears for a long name, leaving
# ` long-name-trunc… ─` with a single pad column. The shape is therefore the
# single-dash tail after one space, a name with no rule or border glyph and no
# prompt glyph, and either a leading `─` run or exactly that one pad column.
# The scan lets this row OPEN a pair but never close one; Claude's bottom rule
# is always plain.
_fm_composer_titled_rule_row() {  # <trimmed-row> <indent>
  local row=$1 indent=$2 body lead title glyph
  case "$row" in *?' ─') ;; *) return 1 ;; esac
  body=${row% ─}
  lead=${body%%' '*}
  if [ -n "$lead" ] && [ -z "${lead//─/}" ]; then
    title=${body#"$lead"}
    case "$title" in ' '[!' ']*) title=${title# } ;; *) return 1 ;; esac
  else
    [ "$indent" = ' ' ] || return 1
    title=$body
  fi
  case "$title" in *─*|*' ') return 1 ;; esac
  fm_composer_row_has_edge "$title" && return 1
  fm_composer_leading_prompt_glyph_var glyph "$title" && return 1
  return 0
}

# Row-scan results are returned through FM_COMPOSER_SCAN_* globals (bash 3.2
# has no nameref); they are internal to this owner.
_fm_composer_scan_screen() {  # <plain-screen> <cursor-or-empty> [extract-wrap]
  local pane=$1 cy=${2:-}
  local line indent left_stripped trimmed kind family side_family
  local top_inner top_spaces='' geometry_check=0 geometry_ambiguous=0
  local content_inner content_spaces bottom_inner bottom_spaces glyph
  local current_indent='' current_family='' row=0 top=-1 valid=0 content_rows=0
  # Complete-box results: the box containing the cursor (cursor mode) or the
  # bottom-most complete box (no cursor).
  FM_COMPOSER_SCAN_BOX_TOP=-1
  FM_COMPOSER_SCAN_BOX_BOTTOM=-1
  FM_COMPOSER_SCAN_BOX_AMBIG=0
  FM_COMPOSER_SCAN_INCOMPLETE_BOX_FROM=-1
  FM_COMPOSER_SCAN_UNSAFE=0
  FM_COMPOSER_SCAN_CURSOR_EDGE=0
  FM_COMPOSER_SCAN_BARE_ROW=-1
  FM_COMPOSER_SCAN_SHELL_ROW=-1
  FM_COMPOSER_SCAN_LEFTBAR_START=-1
  FM_COMPOSER_SCAN_LEFTBAR_END=-1
  FM_COMPOSER_SCAN_PI_PAIR_FOUND=0
  FM_COMPOSER_SCAN_PI_PAIR_VALID=0
  FM_COMPOSER_SCAN_PI_TITLE_INVALID=0
  FM_COMPOSER_SCAN_PI_OPEN=-1
  FM_COMPOSER_SCAN_PI_CLOSE=-1
  FM_COMPOSER_SCAN_PI_LAST_SEPARATOR=-1
  # The glyph PROOF of each envelope: the first row strictly inside it whose
  # content leads with an agent prompt glyph once its side borders are
  # stripped, and that glyph. This is what tells a composer container from a
  # decorative banner; it is recorded here, on the one pass that already walks
  # and trims every row, so the footer zone never re-reads the screen.
  FM_COMPOSER_SCAN_BOX_GLYPH_ROW=-1
  FM_COMPOSER_SCAN_BOX_GLYPH=
  FM_COMPOSER_SCAN_PI_GLYPH_ROW=-1
  FM_COMPOSER_SCAN_PI_GLYPH=
  FM_COMPOSER_SCAN_LEFTBAR_GLYPH_ROW=-1
  FM_COMPOSER_SCAN_LEFTBAR_GLYPH=
  local leftbar_start=-1 pi_open=-1 pi_lines=0 pi_max pi_title_spaces='' pi_close_spaces
  local probe row_glyph row_glyph_row
  local box_glyph_row=-1 box_glyph='' pi_glyph_row=-1 pi_glyph=''
  pi_max=$FM_COMPOSER_PI_MAX_LINES
  case "$pi_max" in ''|*[!0-9]*|0) pi_max=8 ;; esac
  while IFS= read -r line; do
    indent=${line%%[![:space:]]*}
    left_stripped="${line#"${line%%[![:space:]]*}"}"
    trimmed=$left_stripped
    fm_composer_normalize_trim_var trimmed
    kind=
    family=
    case "$trimmed" in
      '╭'*'╮') kind=top; family=rounded ;;
      '┌'*'┐') kind=top; family=light ;;
      '╔'*'╗') kind=top; family=double ;;
      '┏'*'┓') kind=top; family=heavy ;;
      '╰'*'╯') kind=bottom; family=rounded ;;
      '└'*'┘') kind=bottom; family=light ;;
      '╚'*'╝') kind=bottom; family=double ;;
      '┗'*'┛') kind=bottom; family=heavy ;;
      '+'*'+') kind=ascii; family=ascii ;;
    esac
    # This row's glyph proof, computed once for every envelope that contains
    # it: the same side-border strip _fm_composer_row_content performs, then
    # the agent-glyph test. A border row never carries a proof.
    row_glyph=''
    row_glyph_row=-1
    if [ -z "$kind" ]; then
      probe=$trimmed
      case "$probe" in
        '│'*'│') probe=${probe#│}; probe=${probe%│} ;;
        '┃'*'┃') probe=${probe#┃}; probe=${probe%┃} ;;
        '║'*'║') probe=${probe#║}; probe=${probe%║} ;;
        '|'*'|') probe=${probe#|}; probe=${probe%|} ;;
        '┃'*) probe=${probe#┃} ;;
      esac
      fm_composer_normalize_trim_var probe
      if fm_composer_leading_agent_glyph_var glyph "$probe"; then
        row_glyph=$glyph
        row_glyph_row=$row
      fi
    fi
    # Pi separator rows: a solid `─` rule at least 8 columns wide. A separator
    # closes the preceding candidate and immediately opens the next, so an
    # earlier transcript rule can never outrank the live bottom composer pair.
    if _fm_composer_pi_separator_row "$trimmed"; then
      FM_COMPOSER_SCAN_PI_LAST_SEPARATOR=$row
      if [ "$pi_open" -ge 0 ]; then
        FM_COMPOSER_SCAN_PI_PAIR_FOUND=1
        FM_COMPOSER_SCAN_PI_TITLE_INVALID=0
        if [ -n "$pi_title_spaces" ]; then
          pi_close_spaces="$indent${trimmed//─/ }"
          if [ "$pi_title_spaces" != "$pi_close_spaces" ]; then
            FM_COMPOSER_SCAN_PI_TITLE_INVALID=1
          fi
        fi
        FM_COMPOSER_SCAN_PI_OPEN=$pi_open
        FM_COMPOSER_SCAN_PI_CLOSE=$row
        if [ "$pi_lines" -le "$pi_max" ] && [ "$FM_COMPOSER_SCAN_PI_TITLE_INVALID" = 0 ]; then
          FM_COMPOSER_SCAN_PI_PAIR_VALID=1
        else
          FM_COMPOSER_SCAN_PI_PAIR_VALID=0
        fi
        FM_COMPOSER_SCAN_PI_GLYPH_ROW=$pi_glyph_row
        FM_COMPOSER_SCAN_PI_GLYPH=$pi_glyph
      fi
      pi_open=$row
      pi_title_spaces=''
      pi_lines=0
      pi_glyph_row=-1
      pi_glyph=''
    elif _fm_composer_titled_rule_row "$trimmed" "$indent"; then
      # Prove the named rule's width against its closing rule. The truncation
      # ellipsis is one column; other non-ASCII titles remain unproved rather
      # than guessing their terminal width. Retain the one-column title pad.
      pi_title_spaces="$indent${trimmed//─/ }"
      pi_title_spaces=${pi_title_spaces//…/ }
      pi_title_spaces=$(printf '%s' "$pi_title_spaces" | LC_ALL=C sed 's/[!-~]/ /g')
      FM_COMPOSER_SCAN_PI_LAST_SEPARATOR=$row
      pi_open=$row
      pi_lines=0
      pi_glyph_row=-1
      pi_glyph=''
    else
      if [ "$pi_open" -ge 0 ]; then
        pi_lines=$((pi_lines + 1))
        if [ "$pi_glyph_row" -lt 0 ] && [ "$row_glyph_row" -ge 0 ]; then
          pi_glyph_row=$row_glyph_row
          pi_glyph=$row_glyph
        fi
      fi
    fi
    # Left-bar rows (opencode): a heavy left bar `┃` opening the row with no
    # closing side border. A `┃…┃` row is a bordered box row, not a left bar.
    case "$trimmed" in
      '┃'*'┃') leftbar_start=-1 ;;
      '┃'*)
        if [ "$leftbar_start" -lt 0 ]; then
          leftbar_start=$row
          FM_COMPOSER_SCAN_LEFTBAR_GLYPH_ROW=-1
          FM_COMPOSER_SCAN_LEFTBAR_GLYPH=
        fi
        FM_COMPOSER_SCAN_LEFTBAR_START=$leftbar_start
        FM_COMPOSER_SCAN_LEFTBAR_END=$row
        if [ "$FM_COMPOSER_SCAN_LEFTBAR_GLYPH_ROW" -lt 0 ] && [ "$row_glyph_row" -ge 0 ]; then
          FM_COMPOSER_SCAN_LEFTBAR_GLYPH_ROW=$row_glyph_row
          FM_COMPOSER_SCAN_LEFTBAR_GLYPH=$row_glyph
        fi
        ;;
      *) leftbar_start=-1 ;;
    esac
    # Bare agent-glyph rows: the glyph itself is the container proof. Bare
    # shell glyphs are deliberately not candidates (dead-shell rule). Keep
    # lower shell prompts as staleness evidence for cursorless selection.
    # Pi's cost footer can open with `$0.000`; that is furniture, not a prompt.
    if [ "$top" -lt 0 ] && fm_composer_leading_shell_glyph_var glyph "$trimmed" \
       && ! _fm_composer_row_is_pi_status "$trimmed"; then
      FM_COMPOSER_SCAN_SHELL_ROW=$row
    elif fm_composer_leading_agent_glyph_var glyph "$trimmed"; then
      FM_COMPOSER_SCAN_BARE_ROW=$row
    fi
    # Cursor safety: a cursor sitting on a structural edge row is never an
    # input row.
    if [ -n "$cy" ] && [ "$row" -eq "$cy" ] && fm_composer_row_has_edge "$trimmed"; then
      FM_COMPOSER_SCAN_CURSOR_EDGE=1
    fi
    # Complete-box state machine (all border families, geometry, ambiguity).
    if [ "$kind" = top ] || { [ "$kind" = ascii ] && [ "$top" -lt 0 ]; }; then
      if [ -n "$cy" ] && [ "$top" -ge 0 ] && [ "$top" -lt "$cy" ] && [ "$cy" -le "$row" ]; then
        FM_COMPOSER_SCAN_UNSAFE=1
      fi
      top=$row
      FM_COMPOSER_SCAN_INCOMPLETE_BOX_FROM=$row
      current_family=$family
      current_indent=$indent
      valid=1
      content_rows=0
      box_glyph_row=-1
      box_glyph=''
      geometry_ambiguous=0
      geometry_check=1
      top_inner=$trimmed
      case "$family" in
        rounded) top_inner=${top_inner#╭}; top_inner=${top_inner%╮}; top_spaces=${top_inner//─/ } ;;
        light) top_inner=${top_inner#┌}; top_inner=${top_inner%┐}; top_spaces=${top_inner//─/ } ;;
        double) top_inner=${top_inner#╔}; top_inner=${top_inner%╗}; top_spaces=${top_inner//═/ } ;;
        heavy) top_inner=${top_inner#┏}; top_inner=${top_inner%┓}; top_spaces=${top_inner//━/ } ;;
        ascii) top_inner=${top_inner#+}; top_inner=${top_inner%+}; top_spaces=${top_inner//-/ } ;;
      esac
      case "$top_spaces" in
        *[![:space:]]*) geometry_check=0; geometry_ambiguous=1 ;;
      esac
    elif [ "$kind" = bottom ] || { [ "$kind" = ascii ] && [ "$top" -ge 0 ]; }; then
      if [ "$top" -ge 0 ] && [ "$family" = "$current_family" ] \
         && [ "$valid" = 1 ] && [ "$content_rows" -gt 0 ]; then
        [ "$indent" = "$current_indent" ] || geometry_ambiguous=1
        if [ "$geometry_check" = 1 ]; then
          bottom_inner=$trimmed
          case "$family" in
            rounded) bottom_inner=${bottom_inner#╰}; bottom_inner=${bottom_inner%╯}; bottom_spaces=${bottom_inner//─/ } ;;
            light) bottom_inner=${bottom_inner#└}; bottom_inner=${bottom_inner%┘}; bottom_spaces=${bottom_inner//─/ } ;;
            double) bottom_inner=${bottom_inner#╚}; bottom_inner=${bottom_inner%╝}; bottom_spaces=${bottom_inner//═/ } ;;
            heavy) bottom_inner=${bottom_inner#┗}; bottom_inner=${bottom_inner%┛}; bottom_spaces=${bottom_inner//━/ } ;;
            ascii) bottom_inner=${bottom_inner#+}; bottom_inner=${bottom_inner%+}; bottom_spaces=${bottom_inner//-/ } ;;
          esac
          if [ "$bottom_spaces" != "$top_spaces" ]; then
            # A TITLED bottom border (grok writes its model name there) is
            # tolerated when the inner still starts and ends with the family's
            # own rule glyph: the corners, family, indent, and every content
            # row's geometry were already proven. Anything else is ambiguity.
            if ! _fm_composer_titled_bottom_ok "$family" "$bottom_inner" "$top_spaces"; then
              geometry_ambiguous=1
            fi
          fi
        fi
        if [ -n "$cy" ]; then
          if [ "$top" -lt "$cy" ] && [ "$cy" -le "$row" ]; then
            FM_COMPOSER_SCAN_BOX_TOP=$top
            FM_COMPOSER_SCAN_BOX_BOTTOM=$row
            FM_COMPOSER_SCAN_BOX_AMBIG=$geometry_ambiguous
            FM_COMPOSER_SCAN_BOX_GLYPH_ROW=$box_glyph_row
            FM_COMPOSER_SCAN_BOX_GLYPH=$box_glyph
          fi
        else
          FM_COMPOSER_SCAN_BOX_TOP=$top
          FM_COMPOSER_SCAN_BOX_BOTTOM=$row
          FM_COMPOSER_SCAN_BOX_AMBIG=$geometry_ambiguous
          FM_COMPOSER_SCAN_BOX_GLYPH_ROW=$box_glyph_row
          FM_COMPOSER_SCAN_BOX_GLYPH=$box_glyph
        fi
        FM_COMPOSER_SCAN_INCOMPLETE_BOX_FROM=-1
      else
        if [ "$FM_COMPOSER_SCAN_INCOMPLETE_BOX_FROM" -lt 0 ]; then
          FM_COMPOSER_SCAN_INCOMPLETE_BOX_FROM=$row
        fi
        if [ -n "$cy" ]; then
          if { [ "$top" -ge 0 ] && [ "$top" -lt "$cy" ] && [ "$cy" -le "$row" ]; } \
             || [ "$row" -eq "$cy" ]; then
            FM_COMPOSER_SCAN_UNSAFE=1
          fi
        fi
      fi
      top=-1
      current_family=
      current_indent=
      valid=0
      content_rows=0
    elif [ "$top" -ge 0 ]; then
      side_family=
      case "$trimmed" in
        '│'*'│') side_family=single ;;
        '┃'*'┃') side_family=heavy ;;
        '║'*'║') side_family=double ;;
        '|'*'|') side_family=ascii ;;
      esac
      case "$current_family:$side_family" in
        rounded:single|light:single|heavy:heavy|double:double|ascii:ascii)
          content_rows=$((content_rows + 1))
          if [ "$box_glyph_row" -lt 0 ] && [ "$row_glyph_row" -ge 0 ]; then
            box_glyph_row=$row_glyph_row
            box_glyph=$row_glyph
          fi
          [ "$indent" = "$current_indent" ] || geometry_ambiguous=1
          if [ "$geometry_check" = 1 ]; then
            content_inner=$trimmed
            case "$side_family" in
              single) content_inner=${content_inner#│}; content_inner=${content_inner%│} ;;
              heavy) content_inner=${content_inner#┃}; content_inner=${content_inner%┃} ;;
              double) content_inner=${content_inner#║}; content_inner=${content_inner%║} ;;
              ascii) content_inner=${content_inner#|}; content_inner=${content_inner%|} ;;
            esac
            if content_spaces=$(fm_composer_geometry_spaces "$content_inner"); then
              [ "$content_spaces" = "$top_spaces" ] || geometry_ambiguous=1
            else
              geometry_ambiguous=1
            fi
          fi
          ;;
        *) valid=0 ;;
      esac
    fi
    row=$((row + 1))
  done <<EOF
$pane
EOF
  if [ -n "$cy" ] && [ "$top" -ge 0 ] && [ "$top" -lt "$cy" ]; then
    FM_COMPOSER_SCAN_UNSAFE=1
  fi
}

# 0 when a mismatched bottom border reads as a legitimate TITLE: the trimmed
# inner (corners already stripped) still starts and ends with the family's own
# rule glyph, so the title is embedded IN the rule rather than replacing it.
_fm_composer_titled_bottom_ok() {  # <family> <bottom-inner> <top-spaces>
  local family=$1 inner=$2 expected=$3 dash spaces title effort model
  fm_composer_normalize_trim_var inner
  case "$family" in
    rounded|light) dash='─' ;;
    double) dash='═' ;;
    heavy) dash='━' ;;
    ascii) dash='-' ;;
    *) return 1 ;;
  esac
  case "$inner" in
    "$dash"*"$dash") ;;
    *) return 1 ;;
  esac
  spaces=${inner//"$dash"/ }
  spaces=$(printf '%s' "$spaces" | LC_ALL=C sed 's/[!-~]/ /g')
  case "$spaces" in
    *[![:space:]]*) return 1 ;;
  esac
  [ "$spaces" = "$expected" ] && return 0

  # Grok 1.0.5 renders its real model title FM_COMPOSER_GROK_TITLE_OVERHANG
  # columns wider than the otherwise aligned top and content rows (issue
  # #3436; see the constant's definition for provenance and caveats). Accept
  # only that exact overhang and only the typed Grok model/effort title
  # shape. This keeps arbitrary malformed bottoms ambiguous while preserving
  # the complete-box proof around a genuinely idle or pending Grok composer.
  local overhang
  overhang=$(printf '%*s' "$FM_COMPOSER_GROK_TITLE_OVERHANG" '')
  [ "$spaces" = "$expected$overhang" ] || return 1
  title=${inner//"$dash"/}
  fm_composer_normalize_trim_var title
  case "$title" in
    'Grok '*\ \(low\)) effort=low ;;
    'Grok '*\ \(medium\)) effort=medium ;;
    'Grok '*\ \(high\)) effort=high ;;
    'Grok '*\ \(xhigh\)) effort=xhigh ;;
    *) return 1 ;;
  esac
  model=${title#Grok }
  model=${model%" ($effort)"}
  [ -n "$model" ] || return 1
  case "$model" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# fm_composer_row_has_edge: 0 when the trimmed row starts or ends with a
# box-drawing/edge glyph - a structural row, never an input row.
# The half-block glyphs are edges too. Herdr draws a composer's top and bottom
# rules with ▄ and ▀ instead of the box-drawing family, so without them a bare
# composer's WRAP region walks straight through its own closing rule and
# swallows the footer below it - which reads as real typed text and turns an
# idle pane into a false `pending`. Measured live on a herdr cursor pane, where
# the wrap region ran from the composer row through the model and path rows.
fm_composer_row_has_edge() {  # <trimmed-row>
  local row=$1
  fm_composer_normalize_trim_var row
  case "$row" in
    '│'*|*'│'|'┃'*|*'┃'|'║'*|*'║'|'╭'*|*'╭'|'╮'*|*'╮'|\
    '┌'*|*'┌'|'┐'*|*'┐'|'╔'*|*'╔'|'╗'*|*'╗'|'┏'*|*'┏'|'┓'*|*'┓'|\
    '╰'*|*'╰'|'╯'*|*'╯'|'└'*|*'└'|'┘'*|*'┘'|'╚'*|*'╚'|'╝'*|*'╝'|\
    '┗'*|*'┗'|'┛'*|*'┛'|'─'*|*'─'|'━'*|*'━'|'═'*|*'═'|'|'*|*'|'|'+'*|*'+'|\
    '▀'*|*'▀'|'▄'*|*'▄'|'▁'*|*'▁'|'▔'*|*'▔')
      return 0
      ;;
  esac
  return 1
}

# fm_composer_geometry_spaces: prove a box content row blank to the same width
# as its border. One leading prompt glyph is blanked (every prompt glyph
# occupies one column), the content is normalized so a Unicode space cannot
# defeat the blankness proof, then every remaining ASCII-printable is mapped to
# a space; any other residue fails the proof.
fm_composer_geometry_spaces() {  # <content-inner> -> spaces
  local content=$1 glyph
  fm_composer_normalize_spaces_var content
  if fm_composer_leading_prompt_glyph_var glyph "$content"; then
    content=${content/"$glyph"/ }
  fi
  content=$(printf '%s' "$content" | LC_ALL=C sed 's/[!-~]/ /g')
  case "$content" in
    *[![:space:]]*) return 1 ;;
  esac
  printf '%s' "$content"
}

# _fm_composer_screen_row: print row <n> (zero-based) of <screen>.
_fm_composer_screen_row() {  # <n> <screen>
  printf '%s\n' "$2" | sed -n "$(($1 + 1))p"
}

# _fm_composer_row_content: extract the classification content of one raw row:
# ghost-strip when styled, plain otherwise, normalize-trim, and strip one
# matching pair of side border glyphs.
_fm_composer_row_content() {  # <raw-row> <styled> -> content on stdout
  local raw=$1 styled=$2 stripped
  if [ "$styled" = 1 ]; then
    stripped=$(printf '%s\n' "$raw" | fm_composer_strip_ghost)
  else
    stripped=$(printf '%s\n' "$raw" | fm_composer_strip_ansi)
  fi
  fm_composer_normalize_trim_var stripped
  case "$stripped" in
    '│'*'│') stripped=${stripped#│}; stripped=${stripped%│} ;;
    '┃'*'┃') stripped=${stripped#┃}; stripped=${stripped%┃} ;;
    '║'*'║') stripped=${stripped#║}; stripped=${stripped%║} ;;
    '|'*'|') stripped=${stripped#|}; stripped=${stripped%|} ;;
  esac
  fm_composer_normalize_trim_var stripped
  printf '%s' "$stripped"
}

# _fm_composer_classify_rows: shared multi-row container verdict for the box
# and separated shapes: pending beats empty, an unreadable row is unknown, and
# geometry ambiguity turns pending into pending-unproven and empty into
# unknown (an ambiguous container is not positive proof).
_fm_composer_classify_rows() {  # <screen> <styled> <ambiguous> <first-row> <last-row>
  local screen=$1 styled=$2 ambiguous=$3 first=$4 last=$5
  local row raw content plain state unknown_seen=0
  row=$first
  while [ "$row" -le "$last" ]; do
    raw=$(_fm_composer_screen_row "$row" "$screen")
    content=$(_fm_composer_row_content "$raw" "$styled")
    plain=$(_fm_composer_row_content "$raw" 0)
    state=$(fm_composer_classify_content 1 "$content" \
      "${FM_COMPOSER_IDLE_RE:-$FM_COMPOSER_IDLE_RE_DEFAULT}" insensitive "$plain" 1 "$styled")
    case "$state" in
      pending)
        if [ "$ambiguous" = 1 ]; then printf 'pending-unproven'; else printf 'pending'; fi
        return 0
        ;;
      unknown) unknown_seen=1 ;;
    esac
    row=$((row + 1))
  done
  if [ "$unknown_seen" = 1 ] || [ "$ambiguous" = 1 ]; then
    printf 'unknown'
  else
    printf 'empty'
  fi
}

# _fm_composer_classify_bare_row: the bare agent-glyph row verdict, including
# the styled=0 degradation: without styling, trailing text after the glyph may
# be the harness's own idle suggestion (claude's rotating dim hint, codex's
# `Use /skills ...`), so it must read `unknown` rather than a false `pending`.
_fm_composer_classify_bare_row() {  # <screen> <styled> <row>
  local screen=$1 styled=$2 row=$3 raw content plain state
  raw=$(_fm_composer_screen_row "$row" "$screen")
  content=$(_fm_composer_row_content "$raw" "$styled")
  plain=$(_fm_composer_row_content "$raw" 0)
  _fm_composer_bare_row_strip_furniture_var content "$raw" "$styled"
  _fm_composer_bare_row_strip_furniture_var plain "$raw" "$styled"
  state=$(fm_composer_classify_content 0 "$content" \
    "${FM_COMPOSER_IDLE_RE:-$FM_COMPOSER_IDLE_RE_DEFAULT}" insensitive "$plain" 0 "$styled")
  if [ "$styled" != 1 ] && [ "$state" = pending ]; then
    printf 'unknown'
    return 0
  fi
  printf '%s' "$state"
}

# _fm_composer_row_is_omp_status: 0 when the trimmed row is omp's status line
# (FM_COMPOSER_OMP_STATUS_RE_DEFAULT above) - composer furniture that sits
# below a bare composer and must bound its wrap region exactly as an edge does.
_fm_composer_row_is_omp_status() {  # <trimmed-row>
  fm_composer_idle_matches "$1" "${FM_COMPOSER_OMP_STATUS_RE:-$FM_COMPOSER_OMP_STATUS_RE_DEFAULT}" sensitive
}

# _fm_composer_row_is_pi_status: 0 when the trimmed row is Pi's dollar-first
# footer stats row (FM_COMPOSER_PI_STATUS_RE_DEFAULT above). Furniture below
# the separated pair; a `$` cost cell must not count as a dead-shell prompt.
_fm_composer_row_is_pi_status() {  # <trimmed-row>
  fm_composer_idle_matches "$1" "$FM_COMPOSER_PI_STATUS_RE_DEFAULT" sensitive
}

# _fm_composer_row_is_braille_furniture: 0 when the row is non-blank and its
# non-whitespace content is entirely braille cells (fm_composer_strip_braille
# above) - an animation row that never counts as typed content and bounds a
# bare composer's wrap region. A blank row is not furniture (the blank-row
# rules own it), and a row mixing braille with anything else is not either.
_fm_composer_row_is_braille_furniture() {  # <row>
  local row=$1 rest
  fm_composer_normalize_trim_var row
  [ -n "$row" ] || return 1
  rest=$(printf '%s\n' "$row" | fm_composer_strip_braille)
  fm_composer_normalize_trim_var rest
  [ -z "$rest" ]
}

# _fm_composer_bare_row_strip_furniture_var: on a bare agent-glyph row, reduce
# the row to its glyph when everything behind the glyph is braille furniture,
# in place through the named variable; a row whose tail carries anything else,
# and a row with no agent glyph, are left untouched. This is the glyph-row half
# of the braille rule: codex 0.154's starfield cells behind its (stripped)
# placeholder must not stand in for typed input. Furniture needs positive
# animation evidence from the raw row: a styled capture whose every braille
# cell is truecolor-painted. An unstyled capture, or any default-foreground
# braille, keeps the tail as a possible braille-only draft.
_fm_composer_bare_row_strip_furniture_var() {  # <varname> <raw-row> <styled>
  local __fmbf_name=$1 __fmbf_text=${!1} __fmbf_raw=$2 __fmbf_glyph='' __fmbf_body __fmbf_rest
  [ "$FM_COMPOSER_CODEX_ANIMATION_NORMALIZED" != 1 ] || return 0
  [ "$3" = 1 ] || return 0
  fm_composer_leading_agent_glyph_var __fmbf_glyph "$__fmbf_text" || return 0
  __fmbf_body=${__fmbf_text#*"$__fmbf_glyph"}
  _fm_composer_row_is_braille_furniture "$__fmbf_body" || return 0
  __fmbf_rest=$(printf '%s\n' "$__fmbf_raw" | fm_composer_strip_painted_braille | fm_composer_strip_ansi)
  [ "$__fmbf_rest" = "$(printf '%s\n' "$__fmbf_rest" | fm_composer_strip_braille)" ] || return 0
  printf -v "$__fmbf_name" '%s' "$__fmbf_glyph"
}

# _fm_composer_wrap_region_ok: 0 when every row STRICTLY BELOW <glyph-row>
# through <cursor-row> is non-blank and carries no structural edge - the
# contiguity proof that those rows are the bare composer's wrapped input
# rather than unrelated screen content.
_fm_composer_wrap_region_ok() {  # <plain-screen> <glyph-row> <cursor-row>
  local plain=$1 g=$2 cy=$3 row line trimmed glyph
  row=$((g + 1))
  while [ "$row" -le "$cy" ]; do
    line=$(_fm_composer_screen_row "$row" "$plain")
    trimmed=$line
    fm_composer_normalize_trim_var trimmed
    [ -n "$trimmed" ] || return 1
    if fm_composer_row_has_edge "$trimmed"; then return 1; fi
    if _fm_composer_row_is_omp_status "$trimmed"; then return 1; fi
    if _fm_composer_row_is_braille_furniture "$trimmed"; then return 1; fi
    if fm_composer_leading_shell_glyph_var glyph "$trimmed"; then return 1; fi
    row=$((row + 1))
  done
  return 0
}

# _fm_composer_classify_bare_wrap: the bare composer plus its wrap region.
# Content is the glyph row (glyph stripped) plus every continuation row down
# to the cursor. Ghost-stripped-to-nothing rows are an empty composer whose
# suggestion happened to wrap; any surviving text is pending when styling can
# prove it real and unknown otherwise (the same styled=0 degradation as the
# glyph row itself).
_fm_composer_classify_bare_wrap() {  # <screen> <styled> <glyph-row> <cursor-row>
  local screen=$1 styled=$2 g=$3 cy=$4 row raw content glyph='' text_seen=0
  row=$g
  while [ "$row" -le "$cy" ]; do
    raw=$(_fm_composer_screen_row "$row" "$screen")
    content=$(_fm_composer_row_content "$raw" "$styled")
    if [ "$row" -eq "$g" ]; then
      _fm_composer_bare_row_strip_furniture_var content "$raw" "$styled"
      if fm_composer_leading_agent_glyph_var glyph "$content"; then
        content=${content#*"$glyph"}
      fi
    fi
    fm_composer_normalize_trim_var content
    [ -z "$content" ] || text_seen=1
    row=$((row + 1))
  done
  if [ "$text_seen" = 0 ]; then
    printf 'empty'
    return 0
  fi
  if [ "$styled" = 1 ]; then printf 'pending'; else printf 'unknown'; fi
}

# _fm_composer_classify_leftbar: opencode's left-bar composer. Blank rows and
# the idle hint read empty; the run's LAST row may be the mode/model footer
# (composer furniture, never typed text). Real content is pending when styling
# can prove it real, unknown otherwise.
_fm_composer_classify_leftbar() {  # <screen> <styled> <first-row> <last-row>
  local screen=$1 styled=$2 first=$3 last=$4
  local row raw content pending_seen=0 footer_re leading_blank=1 placeholder_position=0 floor width=0
  footer_re=${FM_COMPOSER_LEFTBAR_FOOTER_RE:-$FM_COMPOSER_LEFTBAR_FOOTER_RE_DEFAULT}
  floor=$(_fm_composer_screen_row "$((last + 1))" "$screen")
  floor=$(printf '%s\n' "$floor" | fm_composer_strip_ansi)
  fm_composer_normalize_trim_var floor
  # The full-width half-block floor bounds V2's composer independently of its
  # sidebar. Short legacy fixture floors cannot establish a column boundary.
  if _fm_composer_leftbar_floor_row "$floor"; then
    # Count terminal cells without depending on the caller's multibyte locale.
    floor=${floor//▀/ }
    floor=${floor//╹/ }
    [ "${#floor}" -lt 40 ] || width=${#floor}
  fi
  row=$first
  while [ "$row" -le "$last" ]; do
    raw=$(_fm_composer_screen_row "$row" "$screen")
    content=$(_fm_composer_row_content "$raw" "$styled")
    case "$content" in
      '┃'*) content=${content#┃} ;;
    esac
    [ "$width" -eq 0 ] || content=${content:0:$((width - 1))}
    fm_composer_normalize_trim_var content
    if [ -z "$content" ]; then row=$((row + 1)); continue; fi
    if [ "$leading_blank" = 1 ] && [ "$row" -gt "$first" ]; then
      placeholder_position=1
    else
      placeholder_position=0
    fi
    leading_blank=0
    if [ "$placeholder_position" = 1 ] \
       && fm_composer_idle_matches "$content" "${FM_COMPOSER_IDLE_RE:-$FM_COMPOSER_IDLE_RE_DEFAULT}" insensitive; then
      row=$((row + 1)); continue
    fi
    if [ "$row" -eq "$last" ] \
       && fm_composer_idle_matches "$content" "$footer_re" sensitive; then
      row=$((row + 1)); continue
    fi
    pending_seen=1
    row=$((row + 1))
  done
  if [ "$pending_seen" = 1 ]; then
    if [ "$styled" = 1 ]; then printf 'pending'; else printf 'unknown'; fi
  else
    printf 'empty'
  fi
}

_fm_composer_leftbar_floor_row() {  # <trimmed-row>
  local row=$1 blocks
  case "$row" in
    '╹▀'*) blocks=${row#╹} ;;
    *) return 1 ;;
  esac
  [ -z "${blocks//▀/}" ]
}

# V2 home-screen tail after the proven location strip: blanks, optionally
# ending in one indented version label. A contiguous row is never furniture.
_fm_composer_leftbar_tail_is_furniture() {  # <tail>
  local tail=$1 trimmed nonblank first
  trimmed=$tail
  fm_composer_normalize_trim_var trimmed
  [ -n "$trimmed" ] || return 0
  first=${tail%%$'\n'*}
  fm_composer_normalize_trim_var first
  [ -z "$first" ] || return 1
  nonblank=$(printf '%s\n' "$tail" | LC_ALL=C grep -vE '^[[:space:]]*$')
  case "$nonblank" in *$'\n'*) return 1 ;; esac
  printf '%s\n' "$nonblank" | LC_ALL=C grep -qE '^[[:space:]]{8,}[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$'
}

# _fm_composer_row_is_composer_furniture: 0 when <trimmed-row> is DEMONSTRABLY
# a harness's own furniture drawn below its composer, given <proof-glyph> - the
# agent glyph that proved the envelope above it. Exactly four things qualify,
# every one of them already owned elsewhere in this file:
#   - omp's status row and braille-only animation rows, the two furniture rows
#     that already bound a bare composer's wrap region;
#   - claude's permission-mode hint row (FM_COMPOSER_MODE_HINT_RE_DEFAULT);
#   - a row leading with an agent glyph OTHER than the one that proved the
#     envelope. One pane runs one harness, so a foreign prompt glyph is never
#     that harness's second composer - this is the `→` statusLine that started
#     the whole task, `→` being Cursor's glyph on a claude pane.
# Everything else - unclaimed activity (`Working on request...`), and above all
# a row leading with the SAME glyph the envelope was proven by (`❯ my typed
# draft`, which is a live composer) - is NOT furniture, so the envelope above
# it stays stale and the verdict stays a refusal.
_fm_composer_row_is_composer_furniture() {  # <trimmed-row> <proof-glyph>
  local row=$1 proof=$2 glyph=''
  [ -n "$row" ] || return 1
  _fm_composer_row_is_omp_status "$row" && return 0
  _fm_composer_row_is_braille_furniture "$row" && return 0
  fm_composer_idle_matches "$row" \
    "${FM_COMPOSER_MODE_HINT_RE:-$FM_COMPOSER_MODE_HINT_RE_DEFAULT}" sensitive && return 0
  fm_composer_leading_agent_glyph_var glyph "$row" || return 1
  [ -n "$proof" ] && [ "$glyph" != "$proof" ]
}

# _fm_composer_locate_footer_zone: THE composer footer zone of <plain> (see THE
# COMPOSER FOOTER ZONE in this file's header). Records the bottom-most
# glyph-PROVEN envelope in FM_COMPOSER_FOOTER_AFTER (its closing row, including
# the opencode left bar's half-block floor), FM_COMPOSER_FOOTER_GLYPH (the
# proving row) and FM_COMPOSER_FOOTER_LAST (the contiguous non-blank run below
# the closing row). The proof itself is read from the row scan, which already
# recorded it on its single pass.
#
# The zone is furniture only if EVERY row in it is: one non-furniture row makes
# the whole run unclaimed activity, the envelope above it stale, and this
# function return 1. That is the asymmetry this rule is held to - it may only
# ever move a verdict toward refusing, never toward `empty`, because `empty` is
# the one verdict that authorizes fm-send to type into the pane. Returns 1 too
# when no envelope is glyph-proven, when a blank row sits directly beneath it,
# or when the run holds no bare candidate at all (nothing to demote).
_fm_composer_locate_footer_zone() {  # <plain>
  local plain=$1 close next trimmed proof=''
  FM_COMPOSER_FOOTER_AFTER=-1
  FM_COMPOSER_FOOTER_GLYPH=-1
  FM_COMPOSER_FOOTER_LAST=-1
  if [ "$FM_COMPOSER_SCAN_BOX_BOTTOM" -gt "$FM_COMPOSER_FOOTER_AFTER" ] \
     && [ "$FM_COMPOSER_SCAN_BOX_GLYPH_ROW" -ge 0 ]; then
    FM_COMPOSER_FOOTER_AFTER=$FM_COMPOSER_SCAN_BOX_BOTTOM
    FM_COMPOSER_FOOTER_GLYPH=$FM_COMPOSER_SCAN_BOX_GLYPH_ROW
    proof=$FM_COMPOSER_SCAN_BOX_GLYPH
  fi
  if [ "$FM_COMPOSER_SCAN_LEFTBAR_END" -ge 0 ] \
     && [ "$FM_COMPOSER_SCAN_LEFTBAR_GLYPH_ROW" -ge 0 ]; then
    close=$FM_COMPOSER_SCAN_LEFTBAR_END
    next=$((close + 1))
    trimmed=$(_fm_composer_screen_row "$next" "$plain")
    fm_composer_normalize_trim_var trimmed
    if _fm_composer_leftbar_floor_row "$trimmed"; then close=$next; fi
    if [ "$close" -gt "$FM_COMPOSER_FOOTER_AFTER" ]; then
      FM_COMPOSER_FOOTER_AFTER=$close
      FM_COMPOSER_FOOTER_GLYPH=$FM_COMPOSER_SCAN_LEFTBAR_GLYPH_ROW
      proof=$FM_COMPOSER_SCAN_LEFTBAR_GLYPH
    fi
  fi
  if [ "$FM_COMPOSER_SCAN_PI_PAIR_FOUND" = 1 ] \
     && [ "$FM_COMPOSER_SCAN_PI_CLOSE" -gt "$FM_COMPOSER_FOOTER_AFTER" ] \
     && [ "$FM_COMPOSER_SCAN_PI_GLYPH_ROW" -ge 0 ]; then
    FM_COMPOSER_FOOTER_AFTER=$FM_COMPOSER_SCAN_PI_CLOSE
    FM_COMPOSER_FOOTER_GLYPH=$FM_COMPOSER_SCAN_PI_GLYPH_ROW
    proof=$FM_COMPOSER_SCAN_PI_GLYPH
  fi
  [ "$FM_COMPOSER_FOOTER_AFTER" -ge 0 ] || return 1
  # Nothing below the envelope can be demoted unless a bare candidate sits
  # there, so settle that from the scan's own record before walking any rows.
  [ "$FM_COMPOSER_SCAN_BARE_ROW" -gt "$FM_COMPOSER_FOOTER_AFTER" ] || return 1
  FM_COMPOSER_FOOTER_LAST=$FM_COMPOSER_FOOTER_AFTER
  next=$((FM_COMPOSER_FOOTER_AFTER + 1))
  while :; do
    trimmed=$(_fm_composer_screen_row "$next" "$plain")
    fm_composer_normalize_trim_var trimmed
    [ -n "$trimmed" ] || break
    _fm_composer_row_is_composer_furniture "$trimmed" "$proof" || return 1
    FM_COMPOSER_FOOTER_LAST=$next
    next=$((next + 1))
  done
  [ "$FM_COMPOSER_SCAN_BARE_ROW" -gt "$FM_COMPOSER_FOOTER_AFTER" ] \
    && [ "$FM_COMPOSER_SCAN_BARE_ROW" -le "$FM_COMPOSER_FOOTER_LAST" ]
}

_fm_composer_select_cursorless() {
  local plain=$1 generic=-1 next boundary raw trimmed glyph bare footer=0
  FM_COMPOSER_SELECTED_KIND=
  FM_COMPOSER_SELECTED_FIRST=-1
  FM_COMPOSER_SELECTED_LAST=-1
  FM_COMPOSER_SELECTED_AMBIG=0
  if _fm_composer_locate_footer_zone "$plain"; then footer=1; fi
  if [ "$FM_COMPOSER_SCAN_BOX_BOTTOM" -ge 0 ]; then
    generic=$FM_COMPOSER_SCAN_BOX_BOTTOM
    FM_COMPOSER_SELECTED_KIND=box
    FM_COMPOSER_SELECTED_FIRST=$((FM_COMPOSER_SCAN_BOX_TOP + 1))
    FM_COMPOSER_SELECTED_LAST=$((FM_COMPOSER_SCAN_BOX_BOTTOM - 1))
    FM_COMPOSER_SELECTED_AMBIG=$FM_COMPOSER_SCAN_BOX_AMBIG
  fi
  # A bare candidate standing in a proven envelope's footer zone is that
  # harness's own furniture, never a composer. The envelope it sits under is
  # what the screen actually shows, so when that envelope's proving glyph row
  # is itself borderless, the bare candidate moves UP to it; otherwise the
  # envelope (box, left bar) stays selected on its own.
  bare=$FM_COMPOSER_SCAN_BARE_ROW
  if [ "$footer" = 1 ]; then
    trimmed=$(_fm_composer_screen_row "$FM_COMPOSER_FOOTER_GLYPH" "$plain")
    fm_composer_normalize_trim_var trimmed
    if fm_composer_leading_agent_glyph_var glyph "$trimmed"; then
      bare=$FM_COMPOSER_FOOTER_GLYPH
    else
      bare=-1
    fi
  fi
  if [ "$bare" -gt "$generic" ]; then
    generic=$bare
    FM_COMPOSER_SELECTED_KIND=bare
    FM_COMPOSER_SELECTED_FIRST=$bare
    FM_COMPOSER_SELECTED_LAST=$bare
  fi
  if [ "$FM_COMPOSER_SCAN_LEFTBAR_END" -gt "$generic" ]; then
    generic=$FM_COMPOSER_SCAN_LEFTBAR_END
    FM_COMPOSER_SELECTED_KIND=leftbar
    FM_COMPOSER_SELECTED_FIRST=$FM_COMPOSER_SCAN_LEFTBAR_START
    FM_COMPOSER_SELECTED_LAST=$FM_COMPOSER_SCAN_LEFTBAR_END
  fi
  if [ "$FM_COMPOSER_SCAN_INCOMPLETE_BOX_FROM" -gt "$generic" ]; then
    FM_COMPOSER_SELECTED_KIND=
    return 1
  fi
  if [ "$FM_COMPOSER_SCAN_PI_TITLE_INVALID" = 1 ] \
     && [ "$generic" -gt "$FM_COMPOSER_SCAN_PI_OPEN" ] \
     && [ "$generic" -lt "$FM_COMPOSER_SCAN_PI_CLOSE" ]; then
    FM_COMPOSER_SELECTED_KIND=
    return 1
  fi
  if [ "$FM_COMPOSER_SCAN_PI_PAIR_FOUND" = 1 ] \
     && [ "$FM_COMPOSER_SCAN_PI_CLOSE" -gt "$generic" ] \
     && [ "$generic" -lt "$FM_COMPOSER_SCAN_PI_OPEN" ]; then
    generic=$FM_COMPOSER_SCAN_PI_CLOSE
    FM_COMPOSER_SELECTED_KIND=pi
    FM_COMPOSER_SELECTED_FIRST=$((FM_COMPOSER_SCAN_PI_OPEN + 1))
    FM_COMPOSER_SELECTED_LAST=$((FM_COMPOSER_SCAN_PI_CLOSE - 1))
  fi
  if [ "$FM_COMPOSER_SCAN_PI_PAIR_FOUND" = 0 ] \
     && [ "$FM_COMPOSER_SCAN_PI_LAST_SEPARATOR" -gt "$generic" ]; then
    FM_COMPOSER_SELECTED_KIND=
    return 1
  fi
  if [ "$FM_COMPOSER_SCAN_SHELL_ROW" -gt "$generic" ]; then
    FM_COMPOSER_SELECTED_KIND=
    return 1
  fi
  if [ "$FM_COMPOSER_SELECTED_KIND" = bare ]; then
    next=$((FM_COMPOSER_SELECTED_LAST + 1))
    while :; do
      raw=$(_fm_composer_screen_row "$next" "$plain")
      trimmed=$raw
      fm_composer_normalize_trim_var trimmed
      [ -n "$trimmed" ] || break
      fm_composer_row_has_edge "$trimmed" && break
      _fm_composer_row_is_omp_status "$trimmed" && break
      _fm_composer_row_is_braille_furniture "$trimmed" && break
      FM_COMPOSER_SELECTED_LAST=$next
      next=$((next + 1))
    done
  fi
  if [ "$FM_COMPOSER_SELECTED_KIND" = box ] \
     || [ "$FM_COMPOSER_SELECTED_KIND" = leftbar ]; then
    boundary=$FM_COMPOSER_SELECTED_LAST
    if [ "$FM_COMPOSER_SELECTED_KIND" = box ]; then
      boundary=$FM_COMPOSER_SCAN_BOX_BOTTOM
    else
      next=$((boundary + 1))
      raw=$(_fm_composer_screen_row "$next" "$plain")
      trimmed=$raw
      fm_composer_normalize_trim_var trimmed
      if _fm_composer_leftbar_floor_row "$trimmed"; then
        boundary=$next
      fi
    fi
    # The same footer zone, read from the other side: rows this envelope's own
    # glyph proved to be its furniture are not the lower live shape that makes
    # the envelope stale, so the staleness probe resumes past them.
    next=$((boundary + 1))
    if [ "$footer" = 1 ] && [ "$FM_COMPOSER_FOOTER_AFTER" = "$boundary" ]; then
      next=$((FM_COMPOSER_FOOTER_LAST + 1))
    fi
    raw=$(_fm_composer_screen_row "$next" "$plain")
    trimmed=$raw
    fm_composer_normalize_trim_var trimmed
    if [ -n "$trimmed" ] && ! fm_composer_row_has_edge "$trimmed"; then
      # V2 draws its location/shortcut strip directly below the half-block
      # floor, with a path or the running-turn interrupt hint beside the
      # command shortcut.
      # Require both the mode/model footer and the bounded floor before
      # treating this exact strip as furniture; later text still invalidates it.
      if [ "$FM_COMPOSER_SELECTED_KIND" = leftbar ] && [ "$boundary" -eq "$((FM_COMPOSER_SELECTED_LAST + 1))" ] &&
        printf '%s\n' "$trimmed" | LC_ALL=C grep -qE '^(/.+[[:space:]]{2,}.*ctrl\+p commands|.*[[:space:]]{2,}ctrl\+p commands[[:space:]]{2,}/[^[:cntrl:]]+|.*esc interrupt[[:space:]]{2,}.*ctrl\+p commands)$'; then
        raw=$(_fm_composer_screen_row "$FM_COMPOSER_SELECTED_LAST" "$plain")
        trimmed=$(_fm_composer_row_content "$raw" 0)
        trimmed=${trimmed#┃}
        fm_composer_normalize_trim_var trimmed
        fm_composer_idle_matches "$trimmed" "${FM_COMPOSER_LEFTBAR_FOOTER_RE:-$FM_COMPOSER_LEFTBAR_FOOTER_RE_DEFAULT}" sensitive || {
          FM_COMPOSER_SELECTED_KIND=; return 1;
        }
        # The fresh V2 home screen leaves a right-aligned version label at
        # the viewport bottom, separated from the location strip by blank
        # rows. It is furniture only behind this proven composer and strip;
        # arbitrary later output, including another version row, refuses.
        raw=$(printf '%s\n' "$plain" | tail -n "+$((next + 2))")
        _fm_composer_leftbar_tail_is_furniture "$raw" || {
          FM_COMPOSER_SELECTED_KIND=; return 1;
        }
      else
        FM_COMPOSER_SELECTED_KIND=
        return 1
      fi
    fi
  fi
  [ -n "$FM_COMPOSER_SELECTED_KIND" ]
}

# Agy's separated prompt needs its own footer proof; the same `>` between
# transcript rules without that footer can be an exited shell, never empty.
_fm_composer_select_agy() {  # <plain-screen>
  local plain=$1 first last row text footer
  [ "$FM_COMPOSER_SCAN_PI_PAIR_VALID" = 1 ] || return 1
  first=$((FM_COMPOSER_SCAN_PI_OPEN + 1))
  last=$((FM_COMPOSER_SCAN_PI_CLOSE - 1))
  text=$(_fm_composer_screen_row "$first" "$plain")
  case "$text" in '>'|'>'\ *) ;; *) return 1 ;; esac
  footer=$(_fm_composer_screen_row "$((last + 2))" "$plain")
  # Typing hides the shortcut hint; accept-edits keeps its right-aligned mode
  # cell. A model name alone cannot prove the manual-mode input container.
  printf '%s\n' "$footer" | LC_ALL=C grep -qE '^(\? for shortcuts|esc to cancel)[[:space:]]{2,}[^[:space:]]|^[[:space:]]{8,}accept-edits[[:space:]]+·[[:space:]]+' || return 1
  # No later input or popup may hide behind the recognized footer.
  row=$((last + 3))
  text=$(printf '%s\n' "$plain" | tail -n "+$((row + 1))")
  fm_composer_normalize_trim_var text
  [ -z "$text" ] || return 1
  FM_COMPOSER_SELECTED_KIND=agy
  FM_COMPOSER_SELECTED_FIRST=$first
  FM_COMPOSER_SELECTED_LAST=$last
}

_fm_composer_agy_verdict() {  # <screen> <styled>
  local screen=$1 styled=$2 row raw content plain body
  if [ "$styled" = 1 ]; then screen=${screen//"$FM_COMPOSER_AGY_HINT_STYLED"/}; fi
  row=$FM_COMPOSER_SELECTED_FIRST
  raw=$(_fm_composer_screen_row "$row" "$screen")
  plain=$(printf '%s\n' "$raw" | fm_composer_strip_ansi)
  body=${plain#>}
  fm_composer_normalize_trim_var body
  content=$(_fm_composer_row_content "$raw" "$styled")
  if [ "$body" = "$FM_COMPOSER_AGY_HINT" ] && [ "$content" = "$plain" ]; then
    printf 'unknown'
    return 0
  fi
  _fm_composer_classify_rows "$screen" "$styled" 0 \
    "$FM_COMPOSER_SELECTED_FIRST" "$FM_COMPOSER_SELECTED_LAST"
}

# Normalize the exact animated region around the bottom-most bare prompt.
# Leave unstyled or nonmatching screens unchanged so classification stays conservative.
# FM_COMPOSER_CODEX_ANIMATION_NORMALIZED is 1 only after this call normalized
# the exact styled region; the braille furniture rule then leaves the glyph row
# alone, because any braille still on it was typed rather than animated.
FM_COMPOSER_CODEX_ANIMATION_NORMALIZED=0
_fm_composer_normalize_codex_animation_screen_var() {  # <varname> <styled> [cursor-row]
  local __fmc_name=$1 __fmc_styled=$2 __fmc_cy=${3:-} __fmc_screen=${!1}
  local __fmc_plain __fmc_g __fmc_candidate
  FM_COMPOSER_CODEX_ANIMATION_NORMALIZED=0
  [ "$__fmc_styled" = 1 ] || return 0
  __fmc_plain=$(printf '%s\n' "$__fmc_screen" | fm_composer_strip_ansi)
  _fm_composer_scan_screen "$__fmc_plain" "$__fmc_cy"
  [ "$FM_COMPOSER_SCAN_BARE_ROW" -ge 1 ] || return 0
  __fmc_g=$FM_COMPOSER_SCAN_BARE_ROW
  __fmc_candidate=$(printf '%s\n' "$__fmc_screen" | sed -n "$((__fmc_g)), $((__fmc_g + 2))p" |
    fm_composer_strip_ghost codex-animation) || return 0
  __fmc_screen=$(
    if [ "$__fmc_g" -gt 1 ]; then
      printf '%s\n' "$__fmc_screen" | sed -n "1,$((__fmc_g - 1))p"
    fi
    printf '%s\n' "$__fmc_candidate"
    printf '%s\n' "$__fmc_screen" | sed -n "$((__fmc_g + 3)),\$p"
  )
  printf -v "$__fmc_name" '%s' "$__fmc_screen"
  FM_COMPOSER_CODEX_ANIMATION_NORMALIZED=1
}

fm_composer_extract_selected_content() {  # <caps> <screen> [row-separator]
  local caps=$1 screen=$2 separator=${3:-} styled=0 kv plain row raw content glyph joined='' footer_re prompt_row=-1
  local leading_blank=1 placeholder_position=0 prompt_is_shell=0
  footer_re=${FM_COMPOSER_LEFTBAR_FOOTER_RE:-$FM_COMPOSER_LEFTBAR_FOOTER_RE_DEFAULT}
  while IFS= read -r kv; do
    [ "$kv" = styled=1 ] && styled=1
  done <<EOF
$caps
EOF
  _fm_composer_normalize_codex_animation_screen_var screen "$styled"
  plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
  _fm_composer_scan_screen "$plain" '' 1
  _fm_composer_select_devin "$plain" || _fm_composer_select_agy "$plain" || _fm_composer_select_cursorless "$plain" || return 1
  if [ "$FM_COMPOSER_SELECTED_KIND" = agy ] && [ "$styled" = 1 ]; then
    screen=${screen//"$FM_COMPOSER_AGY_HINT_STYLED"/}
  fi
  row=$FM_COMPOSER_SELECTED_FIRST
  while [ "$row" -le "$FM_COMPOSER_SELECTED_LAST" ]; do
    raw=$(_fm_composer_screen_row "$row" "$screen")
    content=$(_fm_composer_row_content "$raw" "$styled")
    placeholder_position=0
    case "$FM_COMPOSER_SELECTED_KIND" in
      bare)
        if [ "$row" -eq "$FM_COMPOSER_SELECTED_FIRST" ] \
           && fm_composer_leading_agent_glyph_var glyph "$content"; then
          content=${content#*"$glyph"}
        fi
        ;;
      leftbar)
        case "$content" in '┃'*) content=${content#┃} ;; esac
        fm_composer_normalize_trim_var content
        if [ -z "$content" ]; then
          :
        elif [ "$leading_blank" = 1 ] && [ "$row" -gt "$FM_COMPOSER_SELECTED_FIRST" ]; then
          placeholder_position=1
          leading_blank=0
        else
          leading_blank=0
        fi
        ;;
      box|agy|devin)
        if [ "$prompt_row" -lt 0 ] \
           && fm_composer_leading_prompt_glyph_var glyph "$content"; then
          prompt_row=$row
          placeholder_position=1
          if _fm_composer_is_prompt_glyph "$glyph" "$FM_COMPOSER_SHELL_PROMPT_GLYPHS"; then
            prompt_is_shell=1
          fi
          content=${content#*"$glyph"}
        elif [ "$prompt_row" -lt 0 ]; then
          placeholder_position=1
        fi
        ;;
    esac
    fm_composer_normalize_spaces_var content
    fm_composer_normalize_trim_var content
    # A styled agent-glyph placeholder disappears above when ghost stripping
    # proves it is furniture. If the same placeholder-looking bytes survive
    # styling, they are real user input and must remain in the extracted content
    # (the zellij paste proof depends on observing exactly what was typed).
    # OpenCode's left-bar hint and legacy shell-glyph boxed placeholders have no
    # such styling proof, so their structurally fixed positions remain the two
    # idle-regex exceptions here.
    if [ -z "$content" ] \
       || { { [ "$FM_COMPOSER_SELECTED_KIND" = leftbar ] \
              || { [ "$FM_COMPOSER_SELECTED_KIND" = box ] && [ "$prompt_is_shell" = 1 ]; } \
              || [ "$FM_COMPOSER_SELECTED_KIND" = devin ]; } \
            && [ "$placeholder_position" = 1 ] \
            && fm_composer_idle_matches "$content" "${FM_COMPOSER_IDLE_RE:-$FM_COMPOSER_IDLE_RE_DEFAULT}" insensitive; } \
       || { [ "$FM_COMPOSER_SELECTED_KIND" = leftbar ] \
            && [ "$row" -eq "$FM_COMPOSER_SELECTED_LAST" ] \
            && fm_composer_idle_matches "$content" "$footer_re" sensitive; }; then
      row=$((row + 1))
      continue
    fi
    if [ -n "$separator" ]; then
      joined="${joined}${joined:+$separator}$content"
    else
      joined="${joined}${joined:+ }$content"
    fi
    row=$((row + 1))
  done
  # A row separator keeps each row exactly as shown, for callers that compare
  # rows; otherwise whitespace runs collapse into the one joined line.
  if [ -n "$separator" ]; then
    printf '%s' "$joined"
    return 0
  fi
  printf '%s\n' "$joined" | LC_ALL=C awk '{$1=$1; printf "%s", $0}'
}

fm_composer_classify_screen() {  # <caps> <screen> [cursor_row] [identity]
  local caps=$1 screen=$2 cy=${3:-} identity=${4:-}
  local styled=0 cursor=0 has_identity=0 kv plain
  while IFS= read -r kv; do
    case "$kv" in
      styled=1) styled=1 ;;
      cursor=1) cursor=1 ;;
      identity=1) has_identity=1 ;;
    esac
  done <<EOF
$caps
EOF
  [ "$cursor" = 1 ] || cy=''
  if [ -n "$cy" ]; then
    case "$cy" in *[!0-9]*) printf 'unknown'; return 0 ;; esac
  fi
  _fm_composer_normalize_codex_animation_screen_var screen "$styled" "$cy"
  plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
  _fm_composer_scan_screen "$plain" "$cy"
  if _fm_composer_select_devin "$plain"; then
    if [ -n "$cy" ] && { [ "$cy" -lt "$FM_COMPOSER_SELECTED_FIRST" ] || [ "$cy" -gt "$FM_COMPOSER_SELECTED_LAST" ]; }; then
      printf 'unknown'
    else
      _fm_composer_devin_verdict "$screen" "$styled"
    fi
    return 0
  fi
  if _fm_composer_select_agy "$plain"; then
    if [ -n "$cy" ] && { [ "$cy" -lt "$FM_COMPOSER_SELECTED_FIRST" ] || [ "$cy" -gt "$FM_COMPOSER_SELECTED_LAST" ]; }; then
      printf 'unknown'
    else
      _fm_composer_agy_verdict "$screen" "$styled"
    fi
    return 0
  fi
  if [ -n "$cy" ]; then
    # Cursor mode (tmux): the shape CONTAINING the cursor is the composer.
    if [ "$FM_COMPOSER_SCAN_PI_TITLE_INVALID" = 1 ] \
       && [ "$cy" -gt "$FM_COMPOSER_SCAN_PI_OPEN" ] \
       && [ "$cy" -lt "$FM_COMPOSER_SCAN_PI_CLOSE" ]; then
      printf 'unknown'; return 0
    fi
    if [ "$FM_COMPOSER_SCAN_UNSAFE" = 1 ]; then
      printf 'unknown'; return 0
    fi
    if [ "$FM_COMPOSER_SCAN_BOX_TOP" -ge 0 ]; then
      _fm_composer_classify_rows "$screen" "$styled" "$FM_COMPOSER_SCAN_BOX_AMBIG" \
        "$((FM_COMPOSER_SCAN_BOX_TOP + 1))" "$((FM_COMPOSER_SCAN_BOX_BOTTOM - 1))"
      return 0
    fi
    if [ "$FM_COMPOSER_SCAN_LEFTBAR_START" -ge 0 ] \
       && [ "$cy" -ge "$FM_COMPOSER_SCAN_LEFTBAR_START" ] \
       && [ "$cy" -le "$FM_COMPOSER_SCAN_LEFTBAR_END" ]; then
      _fm_composer_classify_leftbar "$screen" "$styled" \
        "$FM_COMPOSER_SCAN_LEFTBAR_START" "$FM_COMPOSER_SCAN_LEFTBAR_END"
      return 0
    fi
    if [ "$FM_COMPOSER_SCAN_BARE_ROW" -ge 0 ] && [ "$cy" -eq "$FM_COMPOSER_SCAN_BARE_ROW" ]; then
      if [ "$FM_COMPOSER_SCAN_PI_PAIR_FOUND" = 1 ] \
         && [ "$cy" -gt "$FM_COMPOSER_SCAN_PI_OPEN" ] \
         && [ "$cy" -lt "$FM_COMPOSER_SCAN_PI_CLOSE" ]; then
        _fm_composer_classify_bare_pi_overlap "$screen" "$styled" "$has_identity" "$identity" "$cy"
      else
        _fm_composer_classify_bare_row "$screen" "$styled" "$cy"
      fi
      return 0
    fi
    # A bare composer's WRAP region: long typed input wraps below the glyph
    # row, and the cursor lands on a continuation row that carries no glyph of
    # its own. When every row from the glyph row down to the cursor is
    # non-blank and non-structural, the cursor is inside that composer's
    # wrapped input - an IDENTIFIED region, so the strict blank-row rule does
    # not apply and a swallowed Enter on a long message still reads pending
    # and earns its retry.
    if [ "$FM_COMPOSER_SCAN_BARE_ROW" -ge 0 ] && [ "$cy" -gt "$FM_COMPOSER_SCAN_BARE_ROW" ] \
       && _fm_composer_wrap_region_ok "$plain" "$FM_COMPOSER_SCAN_BARE_ROW" "$cy"; then
      _fm_composer_classify_bare_wrap "$screen" "$styled" "$FM_COMPOSER_SCAN_BARE_ROW" "$cy"
      return 0
    fi
    if [ "$FM_COMPOSER_SCAN_PI_PAIR_FOUND" = 1 ] \
       && [ "$cy" -gt "$FM_COMPOSER_SCAN_PI_OPEN" ] \
       && [ "$cy" -lt "$FM_COMPOSER_SCAN_PI_CLOSE" ]; then
      _fm_composer_pi_verdict "$screen" "$styled" "$has_identity" "$identity"
      return 0
    fi
    if [ "$FM_COMPOSER_SCAN_CURSOR_EDGE" = 1 ]; then
      printf 'unknown'; return 0
    fi
    # STRICT: a blank or otherwise unidentified cursor row has no positive
    # container proof. This replaced the permissive blank-cursor-row rule
    # (captain decision blank-row-injection-posture).
    printf 'unknown'
    return 0
  fi
  # No cursor: the bottom-most shape wins, with the pi-separator staleness
  # rules layered on (a live pi composer pair below the generic candidate
  # proves that candidate stale).
  if ! _fm_composer_select_cursorless "$plain"; then
    printf 'unknown'
    return 0
  fi
  case "$FM_COMPOSER_SELECTED_KIND" in
    pi)
      _fm_composer_pi_verdict "$screen" "$styled" "$has_identity" "$identity"
      ;;
    box)
      _fm_composer_classify_rows "$screen" "$styled" "$FM_COMPOSER_SELECTED_AMBIG" \
        "$FM_COMPOSER_SELECTED_FIRST" "$FM_COMPOSER_SELECTED_LAST"
      ;;
    bare)
      if [ "$FM_COMPOSER_SELECTED_LAST" -gt "$FM_COMPOSER_SELECTED_FIRST" ]; then
        _fm_composer_classify_bare_wrap "$screen" "$styled" \
          "$FM_COMPOSER_SELECTED_FIRST" "$FM_COMPOSER_SELECTED_LAST"
      elif [ "$FM_COMPOSER_SCAN_PI_PAIR_FOUND" = 1 ] \
         && [ "$FM_COMPOSER_SELECTED_FIRST" -gt "$FM_COMPOSER_SCAN_PI_OPEN" ] \
         && [ "$FM_COMPOSER_SELECTED_FIRST" -lt "$FM_COMPOSER_SCAN_PI_CLOSE" ]; then
        _fm_composer_classify_bare_pi_overlap "$screen" "$styled" "$has_identity" "$identity" \
          "$FM_COMPOSER_SELECTED_FIRST"
      else
        _fm_composer_classify_bare_row "$screen" "$styled" "$FM_COMPOSER_SELECTED_FIRST"
      fi
      ;;
    leftbar)
      _fm_composer_classify_leftbar "$screen" "$styled" \
        "$FM_COMPOSER_SELECTED_FIRST" "$FM_COMPOSER_SELECTED_LAST"
      ;;
  esac
}

# fm_composer_submit_retry_core: the ONE verify-and-retry-Enter submit loop
# for the cursor-less backends (cmux, orca, zellij), parameterised by the
# adapter's send-key and composer-state functions. The caller has already
# typed the text ONCE (send_literal) and settled; this loop submits with
# Enter, re-reading the composer verdict, and retries Enter ONLY - never
# retypes, because a swallowed Enter leaves the text in the composer and
# retyping would duplicate it. Proven pending (and pending-unproven) retries
# consume the budget; any other verdict returns immediately, so `unknown`
# stays a loud refusal rather than a blind retry into an unreadable pane.
# tmux and herdr keep richer cores that consume this same shared verdict plus
# fm_composer_queued_enter_verdict; no shape knowledge lives in any loop.
fm_composer_submit_retry_core() {  # <send-key-fn> <state-fn> <target> <retries> <enter-sleep> [expected-label]
  local send_key_fn=$1 state_fn=$2 target=$3 retries=$4 sleep_s=$5 expected_label=${6:-} i=0 state
  while :; do
    "$send_key_fn" "$target" Enter "$expected_label" || true
    sleep "$sleep_s"
    state=$("$state_fn" "$target" "$expected_label")
    case "$state" in
      pending|pending-unproven) ;;
      *) printf '%s' "$state"; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf '%s' "$state"; return 0; }
  done
}

# fm_composer_clear_owned_input <key-fn> <target> <text> <owned-fn> <clear-presses>
# Clear input the caller has just proven it owns with at most <clear-presses>
# Ctrl+U presses, stopping as soon as <owned-fn> finds nothing of it left.
# <key-fn> <target> <key> sends one named key on the caller's backend, and
# <owned-fn> <target> <text> [residue] answers ownership with 0 owned, 1 not
# held, 2 unreadable (fm_tmux_composer_owned_input's contract).
# Returns 0 when the cleanup is confirmed and 1 when it is not.
fm_composer_clear_owned_input() {
  local key=$1 target=$2 text=$3 owned=$4 presses=$5 press=0 pending_status=0
  while [ "$pending_status" = 0 ] && [ "$press" -lt "$presses" ]; do
    "$key" "$target" C-u || true
    press=$((press + 1))
    sleep 0.3
    pending_status=0
    "$owned" "$target" "$text" residue || pending_status=$?
  done
  [ "$pending_status" = 1 ]
}

# fm_composer_owned_submit_enter <key-fn> <target> <already-typed-text>
#   <owned-fn> <clear-presses> <label> <postcondition-function> [postcondition-args...]
# The one recovery owner for input a sender typed and must submit or remove,
# with <key-fn> and <owned-fn> as for fm_composer_clear_owned_input.
# At most three Enter attempts over 20 half-second polls. The first Enter is
# unconditional, so a caller resuming earlier input proves ownership first;
# subsequent keys require exact ownership. A failed send can still have
# executed, so always inspect the postcondition. On exhaustion, clear only
# proven owned input (fm_composer_clear_owned_input) and report whether cleanup
# could be confirmed. Returns 0 when the postcondition held, 1 when owned input
# was cleared, 2 when owned cleanup could not be confirmed, and 3 when
# ownership was unproven so no cleanup keys were sent.
# Callers must stop on failure, never append more input to uncertain input.
fm_composer_owned_submit_enter() {
  local key=$1 target=$2 text=$3 owned=$4 presses=$5 label=$6 verify=$7 poll attempt=1
  shift 7
  "$key" "$target" Enter || true
  for ((poll=0; poll<20; poll++)); do
    sleep 0.5
    "$verify" "$@" && return 0
    if [ "$attempt" -lt 3 ] && "$owned" "$target" "$text"; then
      "$key" "$target" Enter || true
      attempt=$((attempt + 1))
    fi
  done
  if ! "$owned" "$target" "$text"; then
    echo "error: $label execution unconfirmed in $target; input ownership is unproven, so no cleanup keys were sent" >&2
    return 3
  fi
  if fm_composer_clear_owned_input "$key" "$target" "$text" "$owned" "$presses"; then
    echo "error: $label did not run in $target after $attempt Enter attempts; cleared owned input" >&2
    return 1
  fi
  echo "error: $label did not run in $target after $attempt Enter attempts; owned input cleanup could not be confirmed" >&2
  return 2
}

# fm_composer_queued_enter_verdict: the ONE busy-queued-Enter policy.
# After Enter retries are spent, convert a structurally proven pending
# composer given a delivery-busy signal from the adapter:
#   pending + busy  -> empty   (Enter was accepted and queued; do not re-send)
#   pending + idle  -> pending (genuine swallow; caller must not assume delivery)
#   pending + unknown -> pending (unreadable busy is not proof of a queue)
# Every other composer verdict is returned unchanged, so pending-unproven,
# empty, and unknown never receive this conversion.
# Adapters supply their own busy primitive (tmux: fm_pane_is_busy; herdr:
# native agent_status=working, or a rendered busy footer on an idle native
# baseline). This function does not read a pane.
fm_composer_queued_enter_verdict() {  # <composer-state> <busy|idle|unknown>
  local state=$1 busy=${2:-}
  [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
  if [ "$busy" = busy ]; then
    printf 'empty'
  else
    printf 'pending'
  fi
}

_fm_composer_classify_pi_rows() {  # <screen> <styled>
  local screen=$1 styled=$2 row raw content
  row=$((FM_COMPOSER_SCAN_PI_OPEN + 1))
  while [ "$row" -lt "$FM_COMPOSER_SCAN_PI_CLOSE" ]; do
    raw=$(_fm_composer_screen_row "$row" "$screen")
    content=$(_fm_composer_row_content "$raw" "$styled")
    fm_composer_normalize_trim_var content
    if [ -n "$content" ]; then
      printf 'pending'
      return 0
    fi
    row=$((row + 1))
  done
  printf 'empty'
}

_fm_composer_classify_bare_pi_overlap() {  # <screen> <styled> <has-identity> <identity> <bare-row>
  local screen=$1 styled=$2 has_identity=$3 identity=$4 row=$5 agent
  if [ "$has_identity" != 1 ]; then
    _fm_composer_classify_bare_row "$screen" "$styled" "$row"
    return 0
  fi
  if [ -z "$identity" ]; then
    printf 'need-identity'
    return 0
  fi
  if [ "$identity" = probe-absent ]; then
    _fm_composer_classify_bare_row "$screen" "$styled" "$row"
    return 0
  fi
  agent=${identity%%$'\t'*}
  if [ "$agent" = pi ]; then
    _fm_composer_pi_verdict "$screen" "$styled" "$has_identity" "$identity"
  else
    _fm_composer_classify_bare_row "$screen" "$styled" "$row"
  fi
}

# The pi separated-shape verdict: identity + structure conjunction (herdr's
# rule, now fleet-wide). A missing identity capability keeps the shape
# unknown; an unfetched identity on an identity-capable backend asks the
# adapter to probe (lazily) and re-call. Proven input remains pending for every
# live pi state, while only an idle/done pi proves an empty composer. A blocked
# pi is parked on an interactive prompt waiting for a human keystroke: its menu
# is drawn above the separator pair, so the composer region looks free while the
# keys would answer the prompt instead of composing (issue #2797). Structure
# cannot disprove that, so a blocked pi defers rather than claiming empty.
_fm_composer_pi_verdict() {  # <screen> <styled> <has_identity> <identity>
  local screen=$1 styled=$2 has_identity=$3 identity=$4 agent agent_status state
  if [ "$has_identity" != 1 ]; then
    printf 'unknown'
    return 0
  fi
  if [ -z "$identity" ]; then
    printf 'need-identity'
    return 0
  fi
  if [ "$identity" = probe-absent ]; then
    printf 'unknown'
    return 0
  fi
  agent=${identity%%$'\t'*}
  agent_status=${identity#*$'\t'}
  if [ "$agent" != pi ] || [ "$FM_COMPOSER_SCAN_PI_PAIR_VALID" != 1 ]; then
    printf 'unknown'
    return 0
  fi
  state=$(_fm_composer_classify_pi_rows "$screen" "$styled")
  if [ "$state" = pending ]; then
    printf 'pending'
    return 0
  fi
  case "$agent_status" in
    idle|done) printf 'empty' ;;
    *) printf 'unknown' ;;
  esac
}
