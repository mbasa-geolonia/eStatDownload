#!/bin/bash

# ------------------------------------------------------------------
# MapFan / e-Stat Oaza Views Installer
# 1. Installs the name-matching functions (and self-test) from
#    estat_mapfan_oaza_link.sql
# 2. Creates the join views from create_mapfan_views.sql
# ------------------------------------------------------------------

set -e

DB_NAME="mapfan"
DB_USER="$(whoami)"
DB_HOST="localhost"
DB_PORT="5432"

ESTAT_SCHEMA="estat"   # schema holding the imported e-Stat tables; functions and views are created here
TOWN_SCHEMA="town"     # read-only schema holding the MapFan reference tables (oaza_code, oaza_polygon)

FUNCTIONS_SQL="estat_mapfan_oaza_link.sql"
VIEWS_SQL="create_mapfan_views.sql"

PSQL=(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME")

echo "=================================================================="
echo " MapFan Oaza Views Installer"
echo " DB: ${DB_NAME} | e-Stat/functions/views schema: ${ESTAT_SCHEMA} | MapFan schema (read-only): ${TOWN_SCHEMA}"
echo "=================================================================="

"${PSQL[@]}" -v ON_ERROR_STOP=1 -c "CREATE SCHEMA IF NOT EXISTS ${ESTAT_SCHEMA};" > /dev/null

echo ""
echo ">>> Installing name-matching functions from ${FUNCTIONS_SQL} <<<"
# Only the first BEGIN;/COMMIT; block (sections 1-3: functions + self-test)
# is installed here; the views are supplied separately by create_mapfan_views.sql.
# town is read-only, so the functions (originally town.*) are installed into
# the e-Stat schema instead, alongside the views. Substitution goes through
# @@..@@ placeholders first so a schema name that itself contains "estat" or
# "town" (e.g. "myestat") can't be re-matched by a later rule in the same
# sed pass.
awk '/^BEGIN;$/{c++} c==1{print} /^COMMIT;$/{if (c==1) exit}' "$FUNCTIONS_SQL" \
    | sed -e "s/town\./@@ESTAT_SCHEMA@@./g" -e "s/estat\./@@ESTAT_SCHEMA@@./g" \
    | sed -e "s/@@ESTAT_SCHEMA@@/${ESTAT_SCHEMA}/g" \
    | "${PSQL[@]}" -v ON_ERROR_STOP=1

echo ""
echo ">>> Creating views from ${VIEWS_SQL} <<<"
# The views themselves (town.vN_view) belong alongside the e-Stat data, so
# "town.v" is rewritten to the e-Stat schema; the remaining "town." references
# (oaza_code, oaza_polygon) stay in the MapFan schema. Same placeholder trick
# as above to keep the two passes from re-matching each other's output.
sed -e "s/town\.v/@@ESTAT_SCHEMA@@.v/g" -e "s/town\./@@TOWN_SCHEMA@@./g" -e "s/estat\./@@ESTAT_SCHEMA@@./g" "$VIEWS_SQL" \
    | sed -e "s/@@TOWN_SCHEMA@@/${TOWN_SCHEMA}/g" -e "s/@@ESTAT_SCHEMA@@/${ESTAT_SCHEMA}/g" \
    | "${PSQL[@]}" -v ON_ERROR_STOP=1

echo ""
echo "=================================================================="
echo " Done! Functions and views created in schema '${ESTAT_SCHEMA}' (MapFan tables read from '${TOWN_SCHEMA}')."
echo "=================================================================="
