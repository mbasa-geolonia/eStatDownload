# e-Stat 2020年国勢調査 小地域（町丁・字等）データ自動取得＆PostgreSQLインポートツール

このリポジトリには、e-Stat（政府統計の総合窓口）から2020年国勢調査の小地域（町丁・字等）の統計データを全47都道府県分自動でダウンロードし、データ整形（UTF-8変換および秘匿値・該当なし記号の数値化）を行った上で、PostgreSQLデータベースへ自動インポートする一連のスクリプトが含まれています。

---

## 概要 (Overview)

1. データ自動取得 (`download_all_estat_tables_2020.sh`)
   - 日本全国（47都道府県）の2020年国勢調査小地域統計（テーブル `T001081` 〜 `T001087`）を全自動でダウンロードします。
   - ダウンロードしたZIPアーカイブを解凍し、文字コードをWindows標準の Shift-JIS (CP932) から UTF-8 に自動変換します。
   - テーブルIDごとのディレクトリ（`utf8_csvs/T001081/` など）に整頓して保存します。

2. データベース自動構築＆インポート (`import_to_postgres.sh`)
   - PostgreSQL内に `estat` スキーマを自動作成します。
   - 各統計テーブルのヘッダー1行目（コード名）と2行目（日本語/漢字項目名）を結合し、分析に使いやすい日本語カラム名を持つテーブル構造を動的に作成します。
   - 統計値カラム（2行目に日本語名がある列）を `BIGINT` 型、識別子コードや地域名などの列を `TEXT` 型として定義します。
   - e-Stat特有の非数値記号（秘匿値の `X` や 該当数字なしの `-`）を、Pythonを用いて高速かつ正確に `0` へ置き換え、PostgreSQLへ高速一括インポート（`\copy`）します。

---

## 提供される統計テーブル一覧 (`statsId`)

2020年国勢調査の小地域（町丁・字等）データでは、以下の7種類の主要統計テーブルを全件取得・インポートします。

| テーブルID (`statsId`) | テーブル名称 (日本語) | 主な収録データ項目 |
| :--- | :--- | :--- |
| T001081 | 男女別人口総数及び世帯総数 | 人口総数、男、女、世帯総数 |
| T001082 | 年齢（5歳階級、4区分）別、男女別人口 | 0〜4歳、5〜9歳 ... 85歳以上などの5歳階級別人口、15歳未満、15〜64歳、65歳以上などの年齢区分別人口 |
| T001083 | 配偶関係、年齢（5歳階級）、男女別15歳以上人口 | 未婚、有配偶、死別、離別などの配偶関係別人口 |
| T001084 | 世帯の種類・世帯人員別世帯数 | 一般世帯数、施設等の世帯数、単独世帯（1人世帯）、2人世帯〜6人以上世帯数 |
| T001085 | 産業（大分類）、男女別15歳以上就業者数 | 農業・林業、建設業、製造業、情報通信業、卸売・小売業、医療・福祉などの産業大分類別就業者数 |
| T001086 | 住宅の所有の関係別一般世帯数 | 持ち家、公営・官公庁借家、民営借家、給与住宅（社宅等）別の世帯数 |
| T001087 | 住居の種類・住宅の所有の関係別一般世帯数 | 一戸建、長屋建、共同住宅（エレベーターの有無・階数別）別の世帯数 |

---

## 動作環境・事前準備

- OS: macOS / Linux
- 依存ツール:
  - `curl`, `unzip`, `iconv` (標準でインストール済)
  - `python3` (標準でインストール済)
  - `postgresql` (`psql` コマンドが利用可能であること)

---

## 使い方

### 1. 統計データのダウンロードと解凍

chmod +x download_all_estat_tables_2020.sh
./download_all_estat_tables_2020.sh

### 2. PostgreSQLへのインポート

`import_to_postgres.sh` の先頭にあるデータベース接続情報（DB名、ユーザー名等）環境に合わせて確認・変更した後、実行します。

chmod +x import_to_postgres.sh
./import_to_postgres.sh

---
---

# e-Stat 2020 Census Small Area Data Downloader & PostgreSQL Importer

This repository contains automated bash and python workflows to download, clean, and import the 2020 Japan Population Census Small Area (町丁・字等 / Machi-cho/Aza) statistical data for all 47 prefectures from e-Stat into a PostgreSQL database.

---

## Overview

1. Automated Data Retrieval (`download_all_estat_tables_2020.sh`)
   - Downloads all major statistical tables (`T001081` through `T001087`) for all 47 prefectures in Japan.
   - Unzips the archives and automatically converts the character encoding from Windows Shift-JIS (CP932) to clean UTF-8.
   - Organizes CSV files into table-specific subdirectories (`utf8_csvs/T001081/`, etc.).

2. Database Schema Creation & Data Ingestion (`import_to_postgres.sh`)
   - Creates an `estat` database schema in PostgreSQL automatically.
   - Merges line 1 (metadata column codes) and line 2 (Japanese Kanji descriptive titles) of e-Stat CSV headers to build human-readable Japanese column names.
   - Dynamically assigns database types: `BIGINT` for metric values and `TEXT` for location IDs/names (preserving leading zeros in region codes).
   - Uses Python to cleanly sanitize non-numeric placeholders (`X` for confidential data suppression, `-` for non-applicable zero counts) into `0` without breaking CSV quote formatting, then streams data into PostgreSQL via high-speed `\copy`.

---

## Included e-Stat Statistical Tables (`statsId`)

The pipeline downloads and processes the 7 primary small area statistical datasets for the 2020 Census:

| Table ID (`statsId`) | Table Name (Japanese) | Key Metrics / Data Included |
| :--- | :--- | :--- |
| T001081 | 男女別人口総数及び世帯総数 | Total Population, Male, Female, Total Households |
| T001082 | 年齢（5歳階級、4区分）別、男女別人口 | Population by 5-Year Age Groups (0-4, 5-9 ... 85+) and Age Categories (Under 15, 15-64, 65+) |
| T001083 | 配偶関係、年齢（5歳階級）、男女別15歳以上人口 | Population aged 15+ by Marital Status (Single, Married, Widowed, Divorced) |
| T001084 | 世帯の種類・世帯人員別世帯数 | Private Households, Institutional Households, Household Sizes (1-person to 6+ persons) |
| T001085 | 産業（大分類）、男女別15歳以上就業者数 | Employed Population (15+) by Industry Classification (Agriculture, Construction, Manufacturing, IT, Retail, Healthcare, etc.) |
| T001086 | 住宅の所有の関係別一般世帯数 | Households by Housing Tenure (Owner-occupied, Public Rental, Private Rental, Company Housing) |
| T001087 | 住居の種類・住宅の所有の関係別一般世帯数 | Households by Dwelling Type (Detached house, Tenement, Apartment building, Stories/Elevator status) |

---

## Prerequisites

- OS: macOS or Linux
- Dependencies:
  - `curl`, `unzip`, `iconv` (Pre-installed on macOS/Linux)
  - `python3` (Pre-installed on macOS/Linux)
  - `postgresql` (`psql` CLI must be accessible)

---

## Usage Instructions

### Step 1: Download & Extract Datasets

chmod +x download_all_estat_tables_2020.sh
./download_all_estat_tables_2020.sh

### Step 2: Import into PostgreSQL

Verify your database credentials (DB Name, Username, Host, Port) inside `import_to_postgres.sh`, then execute:

chmod +x import_to_postgres.sh
./import_to_postgres.sh

