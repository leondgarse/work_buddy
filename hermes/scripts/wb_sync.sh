#!/usr/bin/env bash
# Hermes cron script: pull sources; the agent only wakes when something needs summarizing or triage.
# Install: cp this file to ~/.hermes/scripts/ (Hermes refuses scripts outside that folder, symlinks included).
set -euo pipefail
WB="${WB_BIN:-$HOME/.local/bin/wb}"
exec "$WB" sync --gate
