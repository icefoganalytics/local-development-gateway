#!/usr/bin/env bash
set -euo pipefail

if [[ ! "${CHECKOUT_NAME:-}" =~ ^[a-z][a-z0-9_]{0,31}$ ]]; then
  echo "Set CHECKOUT_NAME to the checkout's Compose project name" >&2
  exit 1
fi

for environment in development test; do
  name="app_${CHECKOUT_NAME}_$environment"
  bash /adapter/provision.sh "$name" "Example-$name-Only9!"
done
