#!/usr/bin/env bash
set -euo pipefail

psql -X -v ON_ERROR_STOP=1 \
  -v "role=$1" -v "password=$2" \
  -f /adapter/role.sql

psql -X -v ON_ERROR_STOP=1 \
  -v "database=$1" \
  -f /adapter/database.sql
