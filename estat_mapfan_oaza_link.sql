-- =============================================================================
--  estat_mapfan_oaza_link.sql
--  E-Stat 2020 小地域（町丁・字等） × MapFan DB oaza_polygon linkage
--  E-Stat 小地域統計と MapFan 大字ポリゴンの名称突合・ビュー生成
-- =============================================================================
--  Purpose / 目的
--    MapFan uses proprietary oaza/aza codes, so the link to E-Stat is made on
--    (prefcode || citycode) = SUBSTR(key_code,1,5) plus a fuzzy name match.
--    This script adds support for Hokkaido's 条-grid addresses, where MapFan
--    stores  伏古５ / 屯田２ / 北２４東  and E-Stat stores
--            伏古五条 / 屯田二条 / 北二十四条東.
--
--  Run order / 実行順序
--    Sections 1-3 install the functions, 4 builds the link table,
--    5 is QA (read-only), 6 creates the views, 7 is optional materialization.
--
--  Idempotent: safe to re-run. Section 4 drops and rebuilds the link table.
--  Requires: PostgreSQL 9.6+ (regexp_match). PostGIS for the shape column.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

-- =============================================================================
--  1. Kanji numeral parser / 漢数字パーサ
-- =============================================================================
--  '五'     -> 5
--  '十'     -> 10
--  '十二'   -> 12
--  '二十四' -> 24
--  '五十一' -> 51
--  Anything containing a non-numeral character returns NULL, which is the
--  safe outcome: NULL never equals anything, so the match branch cannot fire.
--
--  Deliberately does NOT handle 百/千 — no 条 grid in Japan reaches 100条,
--  and refusing them keeps the parser from silently accepting odd input.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION town.kanji_to_int(p text)
RETURNS integer
LANGUAGE plpgsql IMMUTABLE STRICT
AS $fn$
DECLARE
    ch  text;
    d   int;
    cur int := 0;   -- digit awaiting a multiplier
    tot int := 0;   -- accumulated total
    i   int;
BEGIN
    IF p = '' THEN
        RETURN NULL;
    END IF;

    FOR i IN 1..char_length(p) LOOP
        ch := substr(p, i, 1);
        d := CASE ch
               WHEN '一' THEN 1 WHEN '二' THEN 2 WHEN '三' THEN 3
               WHEN '四' THEN 4 WHEN '五' THEN 5 WHEN '六' THEN 6
               WHEN '七' THEN 7 WHEN '八' THEN 8 WHEN '九' THEN 9
             END;

        IF d IS NOT NULL THEN
            cur := d;
        ELSIF ch = '十' THEN
            IF cur = 0 THEN
                cur := 1;               -- bare 十 == 1x10
            END IF;
            tot := tot + cur * 10;
            cur := 0;
        ELSE
            RETURN NULL;                -- not a pure kanji numeral
        END IF;
    END LOOP;

    RETURN tot + cur;
END
$fn$;

COMMENT ON FUNCTION town.kanji_to_int(text) IS
'Parse a pure kanji numeral (一〜九, 十) to integer. NULL if any other char present. 漢数字→整数変換。';


-- =============================================================================
--  2. Canonical join keys / 突合キー生成
-- =============================================================================
--  Both sides decompose to  base | number | tail  so that the numeral is
--  compared as an integer and the surrounding text as-is:
--
--     MapFan 伏古５     -> '伏古|5|'      E-Stat 伏古五条       -> '伏古|5|'
--     MapFan 北２４東   -> '北|24|東'     E-Stat 北二十四条東   -> '北|24|東'
--
--  Written in LANGUAGE sql so the planner can inline them.
-- -----------------------------------------------------------------------------

-- MapFan side: loose. Any name containing a digit (half- or full-width) keys.
-- On its own this cannot cause a false match — the E-Stat side is the gate.
CREATE OR REPLACE FUNCTION town.jo_key_mapfan(p text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT
AS $fn$
    SELECT m[1] || '|' || (m[2])::int::text || '|' || m[3]
    FROM regexp_match(
             translate(p, '０１２３４５６７８９', '0123456789'),
             '^(.*?)([0-9]+)(.*)$'
         ) AS t(m);
$fn$;

COMMENT ON FUNCTION town.jo_key_mapfan(text) IS
'MapFan oaza_name -> "base|N|tail" key. NULL when the name contains no digit.';


-- E-Stat side: strict. Requires a literal 条 immediately after the numeral run.
-- That anchor is what keeps 四つ木 / 南四日町 / 四十日 / 十日町 / 二十四軒
-- out of this branch entirely (all return NULL).
--
-- The 丁目 component is stripped first so comparison happens at oaza level:
--   伏古五条１丁目 -> 伏古五条 -> '伏古|5|'
CREATE OR REPLACE FUNCTION town.jo_key_estat(p text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT
AS $fn$
    SELECT m[1] || '|' || town.kanji_to_int(m[2])::text || '|' || m[3]
    FROM regexp_match(
             regexp_replace(p, '[0-9０-９一二三四五六七八九十]+丁目.*$', ''),
             '^(.*?)([一二三四五六七八九十]+)条(.*)$'
         ) AS t(m);
$fn$;

COMMENT ON FUNCTION town.jo_key_estat(text) IS
'E-Stat name -> "base|N|tail" key, only for 条-grid names. NULL otherwise. 条丁目名称の正規化キー。';

-- NOTE on 條 (old form): 奈良県五條市 etc. are NOT matched by the regex above,
-- so they return NULL — the safe result. Only widen to [条條] if Hokkaido data
-- is found using 條, which it should not.


-- =============================================================================
--  3. Single match predicate / 突合判定関数
-- =============================================================================
--  All name-matching logic lives here so the link build and any ad-hoc
--  investigation use identical rules.
--
--  prefcode is passed in purely to fence the 条 branch to Hokkaido ('01').
--  The 条 grid exists only in Sapporo / Asahikawa / Obihiro / Kitami etc.,
--  and the guard removes a whole class of needless exposure such as
--  京都市下京区七条御所ノ内北町 -> '|7|御所ノ内北町' or 東京都北区上十条 -> '上|10|'.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION town.oaza_name_matches(
    estat_name  text,
    mapfan_name text,
    prefcode    text
)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $fn$
    SELECT estat_name = mapfan_name
        OR REPLACE(estat_name, '大字', '') = mapfan_name
        OR estat_name LIKE (mapfan_name || '%')
        OR ( prefcode = '01'
             AND town.jo_key_estat(estat_name) = town.jo_key_mapfan(mapfan_name) );
$fn$;

COMMENT ON FUNCTION town.oaza_name_matches(text, text, text) IS
'True when an E-Stat小地域 name corresponds to a MapFan oaza_name. 名称突合ルール一括判定。';


-- -----------------------------------------------------------------------------
--  3b. Self-test / 自己検証
--      Fails loudly at install time if the parser or keys regress.
-- -----------------------------------------------------------------------------
DO $test$
BEGIN
    -- kanji_to_int
    ASSERT town.kanji_to_int('五')      = 5,   'kanji_to_int 五';
    ASSERT town.kanji_to_int('十')      = 10,  'kanji_to_int 十';
    ASSERT town.kanji_to_int('十二')    = 12,  'kanji_to_int 十二';
    ASSERT town.kanji_to_int('二十四')  = 24,  'kanji_to_int 二十四';
    ASSERT town.kanji_to_int('五十一')  = 51,  'kanji_to_int 五十一';
    ASSERT town.kanji_to_int('五条')   IS NULL, 'kanji_to_int rejects non-numeral';

    -- 条 grid must match across numeral systems
    ASSERT town.jo_key_estat('伏古五条')       = town.jo_key_mapfan('伏古５'),   'jo 伏古五条';
    ASSERT town.jo_key_estat('屯田二条')       = town.jo_key_mapfan('屯田２'),   'jo 屯田二条';
    ASSERT town.jo_key_estat('北二十四条西')   = town.jo_key_mapfan('北２４西'), 'jo 北二十四条西';
    ASSERT town.jo_key_estat('伏古五条１丁目') = town.jo_key_mapfan('伏古５'),   'jo 丁目 strip';

    -- Names that merely contain a numeral must NOT key
    ASSERT town.jo_key_estat('四つ木')     IS NULL, 'false positive 四つ木';
    ASSERT town.jo_key_estat('四つ木一丁目') IS NULL, 'false positive 四つ木一丁目';
    ASSERT town.jo_key_estat('南四日町')   IS NULL, 'false positive 南四日町';
    ASSERT town.jo_key_estat('四十日')     IS NULL, 'false positive 四十日';
    ASSERT town.jo_key_estat('十日町')     IS NULL, 'false positive 十日町';
    ASSERT town.jo_key_estat('二十四軒')   IS NULL, 'false positive 二十四軒';
    ASSERT town.jo_key_estat('八丁目')     IS NULL, 'false positive 八丁目';  -- 福島市八丁目
    ASSERT town.jo_key_estat('五條')       IS NULL, 'old-form 條 not matched';

    -- The 条 branch must stay fenced to Hokkaido
    ASSERT town.oaza_name_matches('伏古五条', '伏古５', '01') IS TRUE,  'match hokkaido';
    ASSERT town.oaza_name_matches('伏古五条', '伏古５', '13') IS FALSE, 'match fenced off Tokyo';

    RAISE NOTICE 'town.* name-matching self-test passed.';
END
$test$;

COMMIT;


-- =============================================================================
--  4. Build the correspondence table / 対応表の構築
-- =============================================================================
--  Fuzzy matching is resolved ONCE here rather than inside the view. Three OR
--  branches with function calls in a join condition force a nested loop and
--  re-evaluate on every read; a materialized correspondence turns the view
--  into a plain equality join. It is also hand-patchable for stragglers.
--
--  match_rule records which branch fired, which is what makes the QA in
--  section 5 readable.
-- -----------------------------------------------------------------------------
BEGIN;

DROP TABLE IF EXISTS town.estat_oaza_link;

CREATE TABLE town.estat_oaza_link AS
SELECT DISTINCT
    a.key_code,
    a.name       AS estat_name,
    c.prefcode,
    c.citycode,
    c.oazacode,
    c.oaza_name,
    CASE
        WHEN a.name = c.oaza_name                          THEN 'exact'
        WHEN REPLACE(a.name, '大字', '') = c.oaza_name      THEN 'strip_oaza'
        WHEN c.prefcode = '01'
             AND town.jo_key_estat(a.name)
               = town.jo_key_mapfan(c.oaza_name)           THEN 'jo_grid'
        ELSE                                                    'like_prefix'
    END AS match_rule
FROM estat.t001081 a
JOIN town.oaza_code c
  ON c.prefcode || c.citycode = SUBSTR(a.key_code, 1, 5)
WHERE a.hyosyo IN ('2', '3')
  AND town.oaza_name_matches(a.name, c.oaza_name, c.prefcode);

CREATE INDEX estat_oaza_link_key_code_idx
    ON town.estat_oaza_link (key_code);
CREATE INDEX estat_oaza_link_oaza_idx
    ON town.estat_oaza_link (prefcode, citycode, oazacode);

ANALYZE town.estat_oaza_link;

COMMENT ON TABLE town.estat_oaza_link IS
'E-Stat key_code <-> MapFan (prefcode,citycode,oazacode) correspondence, built by name matching. Rebuild after any dataset swap. 名称突合による対応表。';

COMMIT;


-- =============================================================================
--  5. QA — run these before trusting the output / 検証クエリ
-- =============================================================================
--  Read-only. Nothing below this line modifies data.
--  Duplicates here silently multiply rows in the view, and the symptom is a
--  population sum that overshoots the published municipal total.
-- -----------------------------------------------------------------------------

-- 5.1 How many links, by rule. 'jo_grid' should be non-zero and Hokkaido-only.
-- SELECT match_rule, count(*) AS links, count(DISTINCT key_code) AS key_codes
-- FROM town.estat_oaza_link
-- GROUP BY 1 ORDER BY 2 DESC;

-- 5.2 FAN-OUT A: one key_code matched to several MapFan oaza.
--     Usually the LIKE branch: MapFan 屯田2 prefix-matches 屯田20条, 屯田21条…
--     and MapFan 南四日町 prefix-matches 南四日町一丁目, 南四日町二丁目…
-- SELECT key_code, estat_name, count(*) AS mapfan_oaza,
--        string_agg(oaza_name || ' [' || match_rule || ']', ', ' ORDER BY oazacode)
-- FROM town.estat_oaza_link
-- GROUP BY 1, 2 HAVING count(*) > 1
-- ORDER BY 3 DESC;

-- 5.3 FAN-OUT B: several key_codes stacked on one MapFan polygon.
--     Expected for the 条 grid, because jo_key_estat strips 丁目:
--     伏古五条１丁目 and 伏古五条２丁目 both reduce to 伏古|5| and both attach
--     to MapFan's single 伏古５ polygon -> overlapping identical geometries.
-- SELECT prefcode, citycode, oazacode, oaza_name, count(*) AS estat_rows,
--        string_agg(estat_name, ', ' ORDER BY key_code)
-- FROM town.estat_oaza_link
-- GROUP BY 1, 2, 3, 4 HAVING count(*) > 1
-- ORDER BY 5 DESC;

-- 5.4 Still unmatched in Hokkaido — the list that reveals the next pattern.
--     Usual remaining suspects: 通 (〜通N丁目), ヶ/ケ, 之/ノ, 舘/館, 甲/乙.
-- SELECT a.key_code, a.name
-- FROM estat.t001081 a
-- LEFT JOIN town.estat_oaza_link l USING (key_code)
-- WHERE a.hyosyo IN ('2','3')
--   AND a.key_code LIKE '01%'
--   AND l.key_code IS NULL
-- ORDER BY 1;

-- 5.5 Nationwide unmatched rate by prefecture.
-- SELECT SUBSTR(a.key_code,1,2) AS pref,
--        count(*) FILTER (WHERE l.key_code IS NULL) AS unmatched,
--        count(*) AS total,
--        round(100.0 * count(*) FILTER (WHERE l.key_code IS NULL) / count(*), 1) AS pct
-- FROM estat.t001081 a
-- LEFT JOIN town.estat_oaza_link l USING (key_code)
-- WHERE a.hyosyo IN ('2','3')
-- GROUP BY 1 ORDER BY 4 DESC;

-- 5.6 Bare-numeral guard: does MapFan store any oaza_name that is only digits?
--     If so it keys to '|N|' and could collide with a 三条-style E-Stat name.
-- SELECT DISTINCT prefcode, citycode, oaza_name
-- FROM town.oaza_code
-- WHERE oaza_name ~ '^[0-9０-９]+$';

-- 5.7 Eyeball the key generator against known edge cases.
-- SELECT n, town.jo_key_estat(n) AS estat_key, town.jo_key_mapfan(n) AS mapfan_key
-- FROM (VALUES ('四つ木'),('四つ木一丁目'),('南四日町'),('四十日'),('十日町'),
--              ('八丁目'),('二十四軒'),('五條'),
--              ('伏古五条'),('伏古五条１丁目'),('北二十四条西'),('上十条'),
--              ('伏古５'),('屯田２'),('北２４東')) v(n);


-- =============================================================================
--  6. The view / ビュー生成
-- =============================================================================
BEGIN;

-- -----------------------------------------------------------------------------
--  6a. Pass-through view: one row per (E-Stat row x matched polygon).
--      town.oaza_code no longer appears — estat_oaza_link already carries the
--      (prefcode, citycode, oazacode) triple, so the polygon join is unchanged.
--
--      ROW_NUMBER() needs a deterministic ORDER BY. Without one, gid changes
--      on every read and QGIS's feature-id cache makes identify/select behave
--      erratically after a refresh.
-- -----------------------------------------------------------------------------
--      CREATE OR REPLACE cannot be used here: it may only append columns to
--      an existing view, and this definition inserts the MapFan code columns
--      ahead of shape. The view must be dropped and recreated.
--      If DROP fails with a dependency error, something else is built on top
--      of v1_view (a materialized view, another view, a QGIS-created layer) —
--      identify it first rather than reaching for CASCADE:
--        SELECT dependent_ns.nspname, dependent_view.relname
--        FROM pg_depend d
--        JOIN pg_rewrite r ON r.oid = d.objid
--        JOIN pg_class dependent_view ON dependent_view.oid = r.ev_class
--        JOIN pg_namespace dependent_ns ON dependent_ns.oid = dependent_view.relnamespace
--        JOIN pg_class source ON source.oid = d.refobjid
--        JOIN pg_namespace source_ns ON source_ns.oid = source.relnamespace
--        WHERE source_ns.nspname = 'town' AND source.relname = 'v1_view'
--          AND dependent_view.relname <> 'v1_view';

DROP VIEW IF EXISTS town.v1_view;
CREATE VIEW town.v1_view AS
SELECT
    ROW_NUMBER() OVER (ORDER BY a.key_code,
                                l.prefcode, l.citycode, l.oazacode) AS gid,
    a.*,
    l.prefcode,
    l.citycode,
    l.oazacode,
    l.oaza_name,
    l.match_rule,
    p.shape
FROM estat.t001081 a
JOIN town.estat_oaza_link l
  ON l.key_code = a.key_code
JOIN town.oaza_polygon p
  ON  p.prefcode = l.prefcode
 AND  p.citycode = l.citycode
 AND  p.oazacode = l.oazacode
WHERE a.hyosyo IN ('2', '3');   -- redundant with the link build, but keeps the
                                -- view correct if the link table is ever
                                -- rebuilt under different criteria.


DROP VIEW IF EXISTS town.v2_view;
CREATE VIEW town.v2_view AS
SELECT
    ROW_NUMBER() OVER (ORDER BY a.key_code,
                                l.prefcode, l.citycode, l.oazacode) AS gid,
    a.*,
    l.prefcode,
    l.citycode,
    l.oazacode,
    l.oaza_name,
    l.match_rule,
    p.shape
FROM estat.t001082 a
JOIN town.estat_oaza_link l
  ON l.key_code = a.key_code
JOIN town.oaza_polygon p
  ON  p.prefcode = l.prefcode
 AND  p.citycode = l.citycode
 AND  p.oazacode = l.oazacode
WHERE a.hyosyo IN ('2', '3');   -- redundant with the link build, but keeps the
                                -- view correct if the link table is ever
                                -- rebuilt under different criteria.

DROP VIEW IF EXISTS town.v3_view;
CREATE VIEW town.v3_view AS
SELECT
    ROW_NUMBER() OVER (ORDER BY a.key_code,
                                l.prefcode, l.citycode, l.oazacode) AS gid,
    a.*,
    l.prefcode,
    l.citycode,
    l.oazacode,
    l.oaza_name,
    l.match_rule,
    p.shape
FROM estat.t001083 a
JOIN town.estat_oaza_link l
  ON l.key_code = a.key_code
JOIN town.oaza_polygon p
  ON  p.prefcode = l.prefcode
 AND  p.citycode = l.citycode
 AND  p.oazacode = l.oazacode
WHERE a.hyosyo IN ('2', '3');   -- redundant with the link build, but keeps the
                                -- view correct if the link table is ever
                                -- rebuilt under different criteria.
DROP VIEW IF EXISTS town.v4_view;
CREATE VIEW town.v4_view AS
SELECT
    ROW_NUMBER() OVER (ORDER BY a.key_code,
                                l.prefcode, l.citycode, l.oazacode) AS gid,
    a.*,
    l.prefcode,
    l.citycode,
    l.oazacode,
    l.oaza_name,
    l.match_rule,
    p.shape
FROM estat.t001084 a
JOIN town.estat_oaza_link l
  ON l.key_code = a.key_code
JOIN town.oaza_polygon p
  ON  p.prefcode = l.prefcode
 AND  p.citycode = l.citycode
 AND  p.oazacode = l.oazacode
WHERE a.hyosyo IN ('2', '3');   -- redundant with the link build, but keeps the
                                -- view correct if the link table is ever
                                -- rebuilt under different criteria.
DROP VIEW IF EXISTS town.v5_view;
CREATE VIEW town.v5_view AS
SELECT
    ROW_NUMBER() OVER (ORDER BY a.key_code,
                                l.prefcode, l.citycode, l.oazacode) AS gid,
    a.*,
    l.prefcode,
    l.citycode,
    l.oazacode,
    l.oaza_name,
    l.match_rule,
    p.shape
FROM estat.t001085 a
JOIN town.estat_oaza_link l
  ON l.key_code = a.key_code
JOIN town.oaza_polygon p
  ON  p.prefcode = l.prefcode
 AND  p.citycode = l.citycode
 AND  p.oazacode = l.oazacode
WHERE a.hyosyo IN ('2', '3');   -- redundant with the link build, but keeps the
                                -- view correct if the link table is ever
                                -- rebuilt under different criteria.
DROP VIEW IF EXISTS town.v6_view;
CREATE VIEW town.v6_view AS
SELECT
    ROW_NUMBER() OVER (ORDER BY a.key_code,
                                l.prefcode, l.citycode, l.oazacode) AS gid,
    a.*,
    l.prefcode,
    l.citycode,
    l.oazacode,
    l.oaza_name,
    l.match_rule,
    p.shape
FROM estat.t001086 a
JOIN town.estat_oaza_link l
  ON l.key_code = a.key_code
JOIN town.oaza_polygon p
  ON  p.prefcode = l.prefcode
 AND  p.citycode = l.citycode
 AND  p.oazacode = l.oazacode
WHERE a.hyosyo IN ('2', '3');   -- redundant with the link build, but keeps the
                                -- view correct if the link table is ever
                                -- rebuilt under different criteria.
COMMENT ON VIEW town.v1_view IS
'E-Stat t001081 attributes joined to MapFan oaza polygons. May contain overlapping features where several 丁目 rows map to one polygon — see town.v1_agg_view. 重複ジオメトリの可能性あり。';

COMMIT;


-- -----------------------------------------------------------------------------
--  6b. Aggregated view — TEMPLATE, edit the measure columns before use.
--      Use this when QA 5.3 shows many stacked rows: it emits exactly one
--      feature per MapFan oaza with the counts summed, instead of overlapping
--      identical geometries where a choropleth renders whichever draws last.
--
--      Two cautions:
--        * Only SUM genuine counts. Averages and ratios need weighting.
--        * E-Stat writes '-' or 'X' for suppressed small-area values, so cast
--          defensively if the columns were imported as text.
--
--      GROUP BY on a geometry works but is slow. If QA 5.2 also shows fan-out,
--      prefer ST_Union(p.shape) grouped on the code triple only — one dissolved
--      multipolygon per oaza and no duplicate features at all.
-- -----------------------------------------------------------------------------
-- DROP VIEW IF EXISTS town.v1_agg_view;
-- CREATE VIEW town.v1_agg_view AS
-- SELECT
--     ROW_NUMBER() OVER (ORDER BY l.prefcode, l.citycode, l.oazacode) AS gid,
--     l.prefcode,
--     l.citycode,
--     l.oazacode,
--     l.oaza_name,
--     count(*)                                        AS estat_row_count,
--     string_agg(a.key_code, ',' ORDER BY a.key_code) AS key_codes,
--     min(a.name)                                     AS estat_name_sample,
--     sum(NULLIF(NULLIF(a.t001081001,'-'),'X')::numeric) AS pop_total,
--     sum(NULLIF(NULLIF(a.t001081002,'-'),'X')::numeric) AS pop_male,
--     sum(NULLIF(NULLIF(a.t001081003,'-'),'X')::numeric) AS pop_female,
--     -- … remaining count columns …
--     ST_Union(p.shape)                               AS shape
-- FROM estat.t001081 a
-- JOIN town.estat_oaza_link l
--   ON l.key_code = a.key_code
-- JOIN town.oaza_polygon p
--   ON  p.prefcode = l.prefcode
--  AND  p.citycode = l.citycode
--  AND  p.oazacode = l.oazacode
-- WHERE a.hyosyo IN ('2','3')
-- GROUP BY l.prefcode, l.citycode, l.oazacode, l.oaza_name;


-- =============================================================================
--  7. Optional materialization for desktop GIS / QGIS 用の実体化
-- =============================================================================
--  The GIST index is the real win: without it every pan and zoom in QGIS
--  re-runs the whole join.
--
--  Remember after a schema rotation / dataset swap:
--    1) rebuild town.estat_oaza_link  (section 4 — it is a table, so it does
--       NOT follow a reload of oaza_code / oaza_polygon on its own)
--    2) REFRESH MATERIALIZED VIEW town.v1_mv;
-- -----------------------------------------------------------------------------
-- DROP MATERIALIZED VIEW IF EXISTS town.v1_mv;
-- CREATE MATERIALIZED VIEW town.v1_mv AS SELECT * FROM town.v1_view;
-- CREATE UNIQUE INDEX v1_mv_gid_idx   ON town.v1_mv (gid);
-- CREATE INDEX        v1_mv_shape_idx ON town.v1_mv USING GIST (shape);
-- CREATE INDEX        v1_mv_key_idx   ON town.v1_mv (key_code);
-- ANALYZE town.v1_mv;

-- Helpful for the link build itself if not already present:
-- CREATE INDEX IF NOT EXISTS t001081_key_code_idx ON estat.t001081 (key_code);
-- CREATE INDEX IF NOT EXISTS oaza_code_pref_city_idx
--     ON town.oaza_code ((prefcode || citycode));


-- =============================================================================
--  8. Uninstall / 撤去
-- =============================================================================
-- DROP MATERIALIZED VIEW IF EXISTS town.v1_mv;
-- DROP VIEW IF EXISTS town.v1_agg_view;
-- DROP VIEW IF EXISTS town.v1_view;
-- DROP TABLE IF EXISTS town.estat_oaza_link;
-- DROP FUNCTION IF EXISTS town.oaza_name_matches(text, text, text);
-- DROP FUNCTION IF EXISTS town.jo_key_estat(text);
-- DROP FUNCTION IF EXISTS town.jo_key_mapfan(text);
-- DROP FUNCTION IF EXISTS town.kanji_to_int(text);

-- =============================================================================
--  End of file
-- =============================================================================
