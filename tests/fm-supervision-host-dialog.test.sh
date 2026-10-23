#!/usr/bin/env bash
# Supervision host behavior: attended dialog mirror delivery.
# Shared fixtures and cases keep the same bounds across the serial suites.
# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

test_primary_without_a_verified_mirror_runs_away_only
test_attended_wake_carries_the_dialog_mirror
test_dialog_bearing_files_are_owner_only
test_undelivered_dialog_is_fed_again_on_the_next_turn
test_attended_wake_with_an_unreadable_mirror_reaches_main
