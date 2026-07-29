#!/bin/bash

# ------------------------------------------------------------------
# e-Stat 2020 Census Small Area Data: Python-Sanitized PostgreSQL Importer
# Schema: estat | Metrics = BIGINT | Codes/Metadata = TEXT
# ------------------------------------------------------------------

DB_NAME="mapfan"
DB_USER="$(whoami)"
DB_HOST="localhost"
DB_PORT="5432"
SCHEMA_NAME="estat"

BASE_DIR="estat_2020_all_tables"
UTF8_BASE_DIR="${BASE_DIR}/utf8_csvs"

TABLES=("T001081" "T001082" "T001083" "T001084" "T001085" "T001086" "T001087")

echo "=================================================================="
echo " PostgreSQL e-Stat Importer (Python-Sanitized BIGINT Metrics)"
echo " Schema: '${SCHEMA_NAME}' | DB: ${DB_NAME}"
echo "=================================================================="

# Ensure Database & Schema exist
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" | grep -q 1 || \
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "CREATE DATABASE ${DB_NAME};"

psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "CREATE SCHEMA IF NOT EXISTS ${SCHEMA_NAME};" > /dev/null

for TABLE_ID in "${TABLES[@]}"; do
    TABLE_DIR="${UTF8_BASE_DIR}/${TABLE_ID}"
    SQL_TABLE_NAME="${SCHEMA_NAME}.$(echo "$TABLE_ID" | tr '[:upper:]' '[:lower:]')"

    if [ ! -d "$TABLE_DIR" ]; then continue; fi

    FIRST_CSV=$(ls "$TABLE_DIR"/*.txt "$TABLE_DIR"/*.csv 2>/dev/null | head -n 1)
    if [ -z "$FIRST_CSV" ]; then continue; fi

    echo ""
    echo ">>> Building Table: ${SQL_TABLE_NAME} <<<"
    echo "------------------------------------------------------------------"

    # Extract Line 1 (Codes) and Line 2 (Kanji Names)
    LINE1=$(head -n 1 "$FIRST_CSV" | tr -d '\r' | tr -d '"')
    LINE2=$(sed -n '2p' "$FIRST_CSV" | tr -d '\r' | tr -d '"')

    IFS=',' read -ra COLS_L1 <<< "$LINE1"
    IFS=',' read -ra COLS_L2 <<< "$LINE2"

    COL_DEFS=""
    
    # Build column definition statement
    for idx in "${!COLS_L1[@]}"; do
        col1=$(echo "${COLS_L1[$idx]}" | xargs | tr '[:upper:]' '[:lower:]')
        col2=$(echo "${COLS_L2[$idx]}" | xargs)

        if [ -n "$COL_DEFS" ]; then COL_DEFS="${COL_DEFS}, "; fi

        if [ -n "$col2" ]; then
            COL_DEFS="${COL_DEFS}\"${col2}\" BIGINT"
        else
            COL_DEFS="${COL_DEFS}\"${col1}\" TEXT"
        fi
    done

    # Re-create database table
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "DROP TABLE IF EXISTS ${SQL_TABLE_NAME};" > /dev/null
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "CREATE TABLE ${SQL_TABLE_NAME} (${COL_DEFS});" > /dev/null

    echo "Created table structure for: ${SQL_TABLE_NAME}"
    echo "Importing CSVs..."

    for csv_file in "$TABLE_DIR"/*; do
        if [ -f "$csv_file" ]; then
            filename=$(basename "$csv_file")
            echo "  - Processing ${filename}..."
            
            # Python Stream Processor:
            # 1. Reads raw CSV with standard CSV parser
            # 2. Skips header rows (lines 1 & 2)
            # 3. Identifies metric columns (where line 2 had Kanji)
            # 4. Converts 'X', '-', empty, or non-numeric values in metric columns to '0'
            # 5. Outputs clean CSV to STDIN for PostgreSQL COPY
            python3 -c "
import sys, csv

file_path = '$csv_file'

with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
    reader = csv.reader(f)
    line1 = next(reader, None)
    line2 = next(reader, None)
    
    if not line1 or not line2:
        sys.exit(0)
        
    # Determine which column indices are numeric metrics
    is_metric = [bool(c.strip()) for c in line2]
    
    writer = csv.writer(sys.stdout)
    
    for row in reader:
        if not row:
            continue
        for i in range(len(row)):
            if i < len(is_metric) and is_metric[i]:
                val = row[i].strip()
                # If value is 'X', '-', empty, or non-digit, sanitize to '0'
                if val in ('X', 'x', '-', '—', '…', '') or not val.lstrip('-').isdigit():
                    row[i] = '0'
                else:
                    row[i] = val
        writer.writerow(row)
" | psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "\copy ${SQL_TABLE_NAME} FROM STDIN WITH (FORMAT csv, DELIMITER ',', ENCODING 'UTF8');" > /dev/null

        fi
    done
done

echo ""
echo "=================================================================="
echo " Done! All sanitized datasets imported into '${SCHEMA_NAME}' schema."
echo "=================================================================="
