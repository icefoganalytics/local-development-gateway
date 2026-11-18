#!/usr/bin/env bash
set -euo pipefail

/opt/mssql-tools18/bin/sqlcmd -S sqlserver -U sa -d master -C -b \
  -v "database=$1" "password=$2" \
  -i /adapter/login.sql

/opt/mssql-tools18/bin/sqlcmd -S sqlserver -U sa -d master -C -b \
  -v "database=$1" \
  -i /adapter/database.sql
