# e-Stat 2020年国勢調査 小地域（町丁・字等）データ自動取得＆PostgreSQLインポートツール

<img width="1310" height="834" alt="Screenshot 2026-07-24 at 19 30 25" src="https://github.com/user-attachments/assets/bd1599ee-9cee-46ad-8e88-a5b5db8d7ff8" />

このリポジトリには、e-Stat（政府統計の総合窓口）から2020年国勢調査の小地域（町丁・字等）の統計データを全47都道府県分自動でダウンロードし、データ整形（UTF-8変換および秘匿値・該当なし記号の数値化）を行った上で、PostgreSQLデータベースへ自動インポートする一連のスクリプトが含まれています。

---

## 概要 (Overview)

1. データ自動取得 (`download_all_estat_tables_2020.sh`)
   - 日本全国（47都道府県）の2020年国勢調査小地域統計（テーブル `T001081` 〜 `T001087`）を全自動でダウンロードします。なお `T001087` は現時点で全都道府県ともZIPの中身が空のため、実際にPostgreSQLへインポートされるのは `T001081` 〜 `T001086` の6テーブルです。
   - ダウンロードしたZIPアーカイブを解凍し、文字コードをWindows標準の Shift-JIS (CP932) から UTF-8 に自動変換します。
   - テーブルIDごとのディレクトリ（`utf8_csvs/T001081/` など）に整頓して保存します。

2. データベース自動構築＆インポート (`import_to_postgres.sh`)
   - PostgreSQL内に `estat` スキーマを自動作成します。
   - 各統計テーブルのヘッダー1行目（コード名）と2行目（日本語/漢字項目名）を結合し、分析に使いやすい日本語カラム名を持つテーブル構造を動的に作成します。
   - 統計値カラム（2行目に日本語名がある列）を `BIGINT` 型、識別子コードや地域名などの列を `TEXT` 型として定義します。
   - e-Stat特有の非数値記号（秘匿値の `X` や 該当数字なしの `-`）を、Pythonを用いて高速かつ正確に `0` へ置き換え、PostgreSQLへ高速一括インポート（`\copy`）します。

3. e-Stat境界ポリゴンのダウンロード＆インポート (`download_estat_2020_polygon_data.sh`)
   - e-Stat GIS（統計地図・統計データダウンロードサイト、調査ID `A002005212020`）から全47都道府県分の2020年国勢調査小地域境界シェープファイルを自動ダウンロード・展開します。
   - `ogr2ogr` を用いて、展開したシェープファイルを1つのPostGISテーブル（既定で `estat.small_area_2020`）へ結合インポートします。
   - ジオメトリを元の座標系（EPSG:6668）からEPSG:4326へ再投影します。
   - ここでインポートしたポリゴンは、e-Stat公式境界のみでGIS用ジオメトリを用意したい場合の入力になるほか、下記4.のMapFan結合の入力データとしても使われます。

4. MapFanの `oaza_polygon` との結合（空間結合方式）
   - 従来の `install_mapfan_views.sh`（町丁字名の文字列突合による結合）は誤結合が発生しやすいため廃止しました。
   - 現在は、3.でインポートしたe-Stat境界ポリゴンとMapFanの `oaza_polygon` を空間的に突合（ポリゴン重心が属するMapFanの字ポリゴンを特定）し、e-Stat統計テーブル（`t001081`〜`t001086`）とMapFanの字ポリゴンを結合するビュー群をSQLで作成する方式に変更しています。
   - 手順の詳細は以下のWikiページを参照してください: [Attaching E‑Stat data into MapFan DB's oaza_polygon](https://github.com/mbasa-geolonia/eStatDownload/wiki/Attaching-E%E2%80%90Stat-data-into-MapFan-DB's-oaza_polygon)

---

## 提供される統計テーブル一覧 (`statsId`)

2020年国勢調査の小地域（町丁・字等）データでは、以下の6種類の主要統計テーブルを全件取得・インポートします。

| テーブルID (`statsId`) | テーブル名称 (日本語) | 主な収録データ項目 |
| :--- | :--- | :--- |
| T001081 | 男女別人口総数及び世帯総数 | 人口総数、男、女、世帯総数 |
| T001082 | 年齢（5歳階級）、男女別人口 | 総数・男・女別の0〜4歳、5〜9歳...70〜74歳の5歳階級別人口、および15歳未満、15〜64歳、65歳以上、75歳以上の年齢区分別人口（年齢「不詳」含む） |
| T001083 | 世帯人員別一般世帯数 | 一般世帯数（世帯人員6人以上含む）、世帯人員1人〜5人別世帯数、一般世帯人員、1世帯当たり人員 |
| T001084 | 世帯の家族類型別一般世帯数 | 一般世帯総数、親族のみの世帯、核家族世帯（うち夫婦のみ、うち夫婦と子供）、核家族以外の世帯、6歳未満・18歳未満・65歳以上の世帯員がいる一般世帯数 |
| T001085 | 住宅の所有の関係別一般世帯数 | 住宅に住む一般世帯数、持ち家、民営借家 |
| T001086 | 住居の建て方別一般世帯数（主世帯） | 主世帯数、一戸建、長屋建、共同住宅（1・2階建、3〜5階建、6〜10階建、11階建以上）、その他 |

---

## 動作環境・事前準備

- OS: macOS / Linux
- 依存ツール:
  - `curl`, `unzip`, `iconv` (標準でインストール済)
  - `python3` (標準でインストール済)
  - `postgresql` (`psql` コマンドが利用可能であること、PostGIS拡張が有効なこと)
  - `gdal`（`ogr2ogr` コマンド。`download_estat_2020_polygon_data.sh` 実行時のみ必要）
- MapFanの `oaza_polygon` を含むスキーマ（既定で `town_polygon`）が事前に用意されていること（MapFanとの結合ビュー作成時のみ必要。手順はWiki参照）

---

## 使い方

### 1. 統計データのダウンロードと解凍

chmod +x download_all_estat_tables_2020.sh
./download_all_estat_tables_2020.sh

### 2. PostgreSQLへのインポート

`import_to_postgres.sh` の先頭にあるデータベース接続情報（DB名、ユーザー名等）環境に合わせて確認・変更した後、実行します。

chmod +x import_to_postgres.sh
./import_to_postgres.sh

### 3. e-Stat境界ポリゴンのダウンロードとインポート

`download_estat_2020_polygon_data.sh` の先頭にあるデータベース接続情報とスキーマ・テーブル名（既定で `estat.small_area_2020`）を環境に合わせて確認・変更した後、実行します。

chmod +x download_estat_2020_polygon_data.sh
./download_estat_2020_polygon_data.sh

### 4. MapFanの oaza_polygon との結合

`install_mapfan_views.sh` は廃止されました。MapFanの `oaza_polygon` とe-Stat統計データを空間的に結合する手順は、以下のWikiページを参照してSQLを実行してください。

[Attaching E‑Stat data into MapFan DB's oaza_polygon](https://github.com/mbasa-geolonia/eStatDownload/wiki/Attaching-E%E2%80%90Stat-data-into-MapFan-DB's-oaza_polygon)

---
---

# e-Stat 2020 Census Small Area Data Downloader & PostgreSQL Importer

This repository contains automated bash and python workflows to download, clean, and import the 2020 Japan Population Census Small Area (町丁・字等 / Machi-cho/Aza) statistical data for all 47 prefectures from e-Stat into a PostgreSQL database.

---

## Overview

1. Automated Data Retrieval (`download_all_estat_tables_2020.sh`)
   - Downloads all major statistical tables (`T001081` through `T001087`) for all 47 prefectures in Japan. Note: `T001087` archives are currently empty for every prefecture, so only `T001081` through `T001086` (6 tables) end up imported into PostgreSQL.
   - Unzips the archives and automatically converts the character encoding from Windows Shift-JIS (CP932) to clean UTF-8.
   - Organizes CSV files into table-specific subdirectories (`utf8_csvs/T001081/`, etc.).

2. Database Schema Creation & Data Ingestion (`import_to_postgres.sh`)
   - Creates an `estat` database schema in PostgreSQL automatically.
   - Merges line 1 (metadata column codes) and line 2 (Japanese Kanji descriptive titles) of e-Stat CSV headers to build human-readable Japanese column names.
   - Dynamically assigns database types: `BIGINT` for metric values and `TEXT` for location IDs/names (preserving leading zeros in region codes).
   - Uses Python to cleanly sanitize non-numeric placeholders (`X` for confidential data suppression, `-` for non-applicable zero counts) into `0` without breaking CSV quote formatting, then streams data into PostgreSQL via high-speed `\copy`.

3. e-Stat Boundary Polygon Downloader/Importer (`download_estat_2020_polygon_data.sh`)
   - Downloads and extracts the official 2020 Census small-area boundary shapefiles for all 47 prefectures from e-Stat GIS (statmap-search, survey id `A002005212020`).
   - Uses `ogr2ogr` to import and merge the shapefiles into a single PostGIS table (default `estat.small_area_2020`).
   - Reprojects the geometry from its source CRS (EPSG:6668) to EPSG:4326.
   - The imported polygons serve both as standalone GIS geometry (when you don't want to depend on MapFan) and as the input data for the MapFan join described below.

4. Joining e-Stat Data to MapFan's `oaza_polygon` (Spatial Join Method)
   - The previous `install_mapfan_views.sh` script (which matched by parsing and comparing district name strings) has been retired — it was prone to mismatches.
   - The current method spatially matches the e-Stat boundary polygons imported in step 3 against MapFan's `oaza_polygon` (finding which MapFan oaza polygon contains each e-Stat polygon's centroid), then builds views joining the e-Stat statistical tables (`t001081`-`t001086`) to the matched MapFan oaza polygons via SQL.
   - See the full step-by-step procedure in the wiki: [Attaching E‑Stat data into MapFan DB's oaza_polygon](https://github.com/mbasa-geolonia/eStatDownload/wiki/Attaching-E%E2%80%90Stat-data-into-MapFan-DB's-oaza_polygon)

---

## Included e-Stat Statistical Tables (`statsId`)

The pipeline downloads and processes 6 primary small area statistical datasets for the 2020 Census:

| Table ID (`statsId`) | Table Name (Japanese) | Key Metrics / Data Included |
| :--- | :--- | :--- |
| T001081 | 男女別人口総数及び世帯総数 | Total Population, Male, Female, Total Households |
| T001082 | 年齢（5歳階級）、男女別人口 | Population by 5-Year Age Groups (0-4, 5-9 ... 70-74) for Total/Male/Female, plus Age Categories (Under 15, 15-64, 65+, 75+) |
| T001083 | 世帯人員別一般世帯数 | Private Households by Household Size (1-person to 5-person, 6+ persons included in total), Household Members, Average Persons per Household |
| T001084 | 世帯の家族類型別一般世帯数 | Private Households by Family Type (Relatives-only, Nuclear Family incl. Couple-only / Couple-with-children, Non-Nuclear Family), Households with Members Under 6, Under 18, or 65+ |
| T001085 | 住宅の所有の関係別一般世帯数 | Private Households Living in Housing, by Tenure (Owner-occupied, Private Rental) |
| T001086 | 住居の建て方別一般世帯数（主世帯） | Primary Households by Dwelling Type (Detached house, Tenement, Apartment Building by Stories 1-2/3-5/6-10/11+, Other) |

---

## Prerequisites

- OS: macOS or Linux
- Dependencies:
  - `curl`, `unzip`, `iconv` (Pre-installed on macOS/Linux)
  - `python3` (Pre-installed on macOS/Linux)
  - `postgresql` (`psql` CLI must be accessible, with the PostGIS extension enabled)
  - `gdal` (the `ogr2ogr` CLI; only required for `download_estat_2020_polygon_data.sh`)
- A schema containing MapFan's `oaza_polygon` table (default `town_polygon`) must already exist (only required for the MapFan join — see the wiki linked below)

---

## Usage Instructions

### Step 1: Download & Extract Datasets

chmod +x download_all_estat_tables_2020.sh
./download_all_estat_tables_2020.sh

### Step 2: Import into PostgreSQL

Verify your database credentials (DB Name, Username, Host, Port) inside `import_to_postgres.sh`, then execute:

chmod +x import_to_postgres.sh
./import_to_postgres.sh

### Step 3: Download & Import e-Stat Boundary Polygons

Verify the database credentials and schema/table names (default `estat.small_area_2020`) inside `download_estat_2020_polygon_data.sh`, then execute:

chmod +x download_estat_2020_polygon_data.sh
./download_estat_2020_polygon_data.sh

### Step 4: Join e-Stat Data to MapFan's oaza_polygon

`install_mapfan_views.sh` has been retired. To spatially join MapFan's `oaza_polygon` with the e-Stat statistical data, follow the SQL steps in the wiki:

[Attaching E‑Stat data into MapFan DB's oaza_polygon](https://github.com/mbasa-geolonia/eStatDownload/wiki/Attaching-E%E2%80%90Stat-data-into-MapFan-DB's-oaza_polygon)

