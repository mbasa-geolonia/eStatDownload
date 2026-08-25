#!/bin/bash

# ------------------------------------------------------------------
# e-Stat 2020 Census Small Area Data: Polygon Boundary Downloader/Importer
# Downloads shapefiles for all 47 prefectures, extracts them, and imports
# them into a single PostGIS table (EPSG:4326).
# Source: e-Stat GIS statmap-search API, survey id A002005212020
# ------------------------------------------------------------------

DB_NAME="mapfan"
DB_USER="$(whoami)"
DB_HOST="localhost"
DB_PORT="5432"
SCHEMA_NAME="estat"
TABLE_NAME="small_area_2020"

SURVEY_ID="A002005212020"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/estat_2020_data"
BASE_URL="https://www.e-stat.go.jp/gis/statmap-search/data"
SRC_SRID="EPSG:6668"

set -euo pipefail

echo "=================================================================="
echo " e-Stat 2020 Polygon Downloader/Importer"
echo " DB: ${DB_NAME} | Schema: '${SCHEMA_NAME}' | Table: ${TABLE_NAME}"
echo "=================================================================="

mkdir -p "$OUT_DIR"

echo ""
echo "==> downloading shapefiles"
for code in $(seq -w 1 47); do
  zip_file="${OUT_DIR}/${SURVEY_ID}_${code}.zip"

  if [[ -s "$zip_file" ]]; then
    echo "skip ${code}: already downloaded"
    continue
  fi

  echo "downloading prefecture ${code}..."
  url="${BASE_URL}?dlserveyId=${SURVEY_ID}&code=${code}&coordSys=1&format=shape&downloadType=5"

  if curl -sSL -f -o "${zip_file}.part" "$url"; then
    mv "${zip_file}.part" "$zip_file"
  else
    echo "failed to download prefecture ${code}" >&2
    rm -f "${zip_file}.part"
    exit 1
  fi
done

echo ""
echo "==> extracting shapefiles"
for code in $(seq -w 1 47); do
  unzip -o -q "${OUT_DIR}/${SURVEY_ID}_${code}.zip" -d "$OUT_DIR"
done

echo ""
echo "==> ensuring database & schema exist"
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" | grep -q 1 || \
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "CREATE DATABASE ${DB_NAME};"

psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS postgis;" > /dev/null
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "CREATE SCHEMA IF NOT EXISTS ${SCHEMA_NAME};" > /dev/null

echo ""
echo "==> importing shapefiles into ${SCHEMA_NAME}.${TABLE_NAME}"
CONN="PG:host=${DB_HOST} port=${DB_PORT} user=${DB_USER} dbname=${DB_NAME} active_schema=${SCHEMA_NAME}"
first=1
for code in $(seq -w 1 47); do
  shp_file="${OUT_DIR}/r2ka${code}.shp"
  echo "importing ${shp_file}..."

  if [[ $first -eq 1 ]]; then
    ogr2ogr -f PostgreSQL -overwrite \
      -nln "${TABLE_NAME}" \
      -lco GEOMETRY_NAME=geom \
      -lco PRECISION=NO \
      -nlt PROMOTE_TO_MULTI \
      -a_srs "${SRC_SRID}" \
      "$CONN" "$shp_file"
    first=0
  else
    ogr2ogr -f PostgreSQL -update -append \
      -nln "${TABLE_NAME}" \
      -nlt PROMOTE_TO_MULTI \
      -a_srs "${SRC_SRID}" \
      "$CONN" "$shp_file"
  fi
done

echo ""
echo "==> import complete"
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT count(*) AS features FROM ${SCHEMA_NAME}.${TABLE_NAME};"

echo ""
echo "==> reprojecting geometry to EPSG:4326"
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "
  ALTER TABLE ${SCHEMA_NAME}.${TABLE_NAME}
    ALTER COLUMN geom TYPE geometry(MultiPolygon, 4326)
    USING ST_Transform(geom, 4326);
"

echo ""
echo "=================================================================="
echo " Done! Imported into '${SCHEMA_NAME}.${TABLE_NAME}' (EPSG:4326)."
echo "=================================================================="
