#!/usr/bin/env bash
# The single supported proof: real Rebrand loop, real retrieval, real relay.
set -euo pipefail
exec bash "$(dirname "${BASH_SOURCE[0]}")/native/run.sh" "$@"
