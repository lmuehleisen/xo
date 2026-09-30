#!/usr/bin/env bash
# bin/fm-composer-devin-lib.sh - fork-only Devin composer shape for the shared
# classifier. bin/fm-composer-lib.sh sources this file and stays the only
# caller: fm_composer_classify_screen and fm_composer_extract_selected_content
# try this selector first, so there is still one classifier with one set of
# rules. Nothing here classifies on its own.
#
#   _fm_composer_select_devin <plain-screen>
#       Selects Devin's full composer frame (top mode rule, `❭` input rows,
#       solid bottom rule, context footer, nothing below it) and sets
#       FM_COMPOSER_SELECTED_KIND/FIRST/LAST; returns 1 when the frame is absent.
#   _fm_composer_devin_verdict <screen> <styled>
#       The empty|pending|unknown verdict for the selected rows.
#
# Regression: tests/fm-composer-devin.test.sh.
# Re-sourcing is a cheap idempotent redefinition, so this file needs no
# include guard (matching bin/fm-composer-lib.sh).

# Devin's composer has top rule `──── (smart mode on) ─` (or mode on),
# prompt row opening with `❭` (U+276D), bottom solid `─` rule,
# and model / context footer row (e.g. `SWE-2 Max Context: 13k / 262k tokens (5%)`).
_fm_composer_select_devin() {  # <plain-screen>
  local plain=$1 total_rows r footer_row=-1 bottom_row=-1 first=-1 last=-1 top_row=-1
  local row_text bottom_text top_text below_text
  total_rows=$(printf '%s\n' "$plain" | wc -l | tr -d ' ')
  [ "$total_rows" -ge 4 ] || return 1

  # Find bottom-most footer matching Devin's Context / token usage footer
  r=$((total_rows - 1))
  while [ "$r" -ge 3 ]; do
    row_text=$(_fm_composer_screen_row "$r" "$plain")
    if printf '%s\n' "$row_text" | LC_ALL=C grep -qE 'Context:[[:space:]]*[0-9]+.*tokens'; then
      footer_row=$r
      break
    fi
    r=$((r - 1))
  done
  [ "$footer_row" -ge 3 ] || return 1

  # No later input or popup may hide behind the recognized footer
  below_text=$(printf '%s\n' "$plain" | tail -n "+$((footer_row + 2))")
  fm_composer_normalize_trim_var below_text
  [ -z "$below_text" ] || return 1

  # Directly above footer row is the solid bottom rule
  bottom_row=$((footer_row - 1))
  bottom_text=$(_fm_composer_screen_row "$bottom_row" "$plain")
  case "$bottom_text" in
    *────────*) ;;
    *) return 1 ;;
  esac

  # Directly above bottom rule are content rows, ending at last = bottom_row - 1
  last=$((bottom_row - 1))
  [ "$last" -ge 1 ] || return 1

  # Find the opening content row starting with `❭` (up to 8 rows above)
  r=$last
  while [ "$r" -ge 1 ] && [ "$r" -ge "$((last - 7))" ]; do
    row_text=$(_fm_composer_screen_row "$r" "$plain")
    case "$row_text" in
      '❭'|'❭'\ *)
        first=$r
        break
        ;;
    esac
    r=$((r - 1))
  done
  [ "$first" -ge 1 ] || return 1

  # Directly above first content row is the top rule
  top_row=$((first - 1))
  top_text=$(_fm_composer_screen_row "$top_row" "$plain")
  case "$top_text" in
    *─*\(?*mode\ on\)*─*|*────────*) ;;
    *) return 1 ;;
  esac

  # shellcheck disable=SC2034 # read by bin/fm-composer-lib.sh, which sources this file
  FM_COMPOSER_SELECTED_KIND=devin
  FM_COMPOSER_SELECTED_FIRST=$first
  FM_COMPOSER_SELECTED_LAST=$last
}

_fm_composer_devin_verdict() {  # <screen> <styled>
  local screen=$1 styled=$2
  _fm_composer_classify_rows "$screen" "$styled" 0 \
    "$FM_COMPOSER_SELECTED_FIRST" "$FM_COMPOSER_SELECTED_LAST"
}
