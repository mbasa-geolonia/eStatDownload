#!/bin/bash

# ------------------------------------------------------------------
# e-Stat 2020 Census Small Area Data: All Statistical Tables Downloader
# Downloads T001081 to T001087 for all 47 Prefectures
# Organizes output into table-specific subdirectories
# ------------------------------------------------------------------

# List of 2020 Census Small Area Statistical Table IDs
TABLES=("T001081" "T001082" "T001083" "T001084" "T001085" "T001086" "T001087")

BASE_DIR="estat_2020_all_tables"
ZIP_DIR="${BASE_DIR}/zips"
UTF8_BASE_DIR="${BASE_DIR}/utf8_csvs"

mkdir -p "$ZIP_DIR"

echo "=================================================================="
echo " Starting Download of All Tables for 47 Prefectures"
echo "=================================================================="

for TABLE_ID in "${TABLES[@]}"; do
    echo ""
    echo ">>> Processing Table ID: ${TABLE_ID} <<<"
    echo "------------------------------------------------------------------"

    # Create table-specific directory inside UTF8_DIR
    TABLE_OUTPUT_DIR="${UTF8_BASE_DIR}/${TABLE_ID}"
    mkdir -p "$TABLE_OUTPUT_DIR"

    for i in $(seq -w 1 47); do
        URL="https://www.e-stat.go.jp/gis/statmap-search/data?statsId=${TABLE_ID}&code=${i}&downloadType=2"
        ZIP_FILE="${ZIP_DIR}/${TABLE_ID}_pref_${i}.zip"

        echo "[${TABLE_ID}] Downloading Prefecture ${i} / 47..."
        curl -s -L "$URL" -o "$ZIP_FILE"

        # Create temporary working directory for unzipping
        TEMP_DIR=$(mktemp -d)
        unzip -q "$ZIP_FILE" -d "$TEMP_DIR" 2>/dev/null

        # Extract and convert files to UTF-8 in the table-specific folder
        for file in "$TEMP_DIR"/*; do
            if [ -f "$file" ]; then
                filename=$(basename "$file")
                # Prepend prefecture code to keep filenames clear and unique
                iconv -f CP932 -t UTF-8//IGNORE "$file" > "${TABLE_OUTPUT_DIR}/pref_${i}_${filename}"
            fi
        done

        rm -rf "$TEMP_DIR"
    done
done

echo ""
echo "=================================================================="
echo " Done! All files organized in table subdirectories under:"
echo " ./${UTF8_BASE_DIR}/"
echo "=================================================================="
