#!/usr/bin/env bash
# Fork-specific fm-watch-triage regression cases.
# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

fm_test_run \
  test_native_approval_poll_timeout_surfaces
