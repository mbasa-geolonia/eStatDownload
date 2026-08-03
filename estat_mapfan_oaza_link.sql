-- =============================================================================
--  estat_mapfan_oaza_link.sql
--  Links E-Stat 小地域 stats to MapFan oaza_polygon by (prefcode+citycode)
--  plus fuzzy name matching, including Hokkaido's 条-grid naming
--  (MapFan 伏古５ / 屯田２ / 北２４東 <-> E-Stat 伏古五条 / 屯田二条 / 北二十四条東)
--  and Kyoto-style aggregate district names (E-Stat 紫野 covers many MapFan
--  chō such as 紫野西御所田町, 紫野下若草町, ...).
--
--  Sections: 1-3 functions, 4 link table, 5 QA (read-only), 6 views, 7 materialization.
--  Idempotent. Requires PostgreSQL 9.6+ and PostGIS.
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;

-- =============================================================================
--  1. Kanji numeral parser (漢数字パーサ) — e.g. 五->5, 十二->12, 二十四->24.
--     Returns NULL for any non-numeral input. Does not handle 百/千.
-- =============================================================================
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
'漢数字→整数変換 (一〜九, 十 only; NULL otherwise).';


-- =============================================================================
--  2. Canonical join keys (突合キー生成)
--     Both sides normalize to "base|number|tail" so the numeral is compared
--     as an integer, e.g. MapFan 伏古５ and E-Stat 伏古五条 both -> '伏古|5|'.
-- =============================================================================

-- MapFan side: loose, keys on any name containing a digit.
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


-- E-Stat side: strict, requires a literal 条 after the numeral (excludes
-- 四つ木/南四日町/十日町 etc). 丁目 is stripped first, e.g. 伏古五条１丁目 -> '伏古|5|'.
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

-- Old-form 條 (e.g. 奈良県五條市) is not matched, so it safely returns NULL.


-- =============================================================================
--  3. Single match predicate (突合判定関数) — shared by the link build and
--     any ad-hoc investigation. prefcode fences the 条 branch to Hokkaido
--     ('01'), where the 条 grid actually exists.
--
--     The reverse-prefix branch handles Kyoto-style aggregation, where
--     E-Stat's 小地域 name is a traditional district name (often a former
--     元学区) that is shorter than, and a prefix of, many individual MapFan
--     chō — e.g. E-Stat 紫野 covers MapFan 紫野西御所田町, 紫野下若草町, etc.
--     This is a legitimate one-to-many fan-out, unlike the forward branch.
-- =============================================================================
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
        OR mapfan_name LIKE (estat_name || '%')
        OR ( prefcode = '01'
             AND town.jo_key_estat(estat_name) = town.jo_key_mapfan(mapfan_name) );
$fn$;

COMMENT ON FUNCTION town.oaza_name_matches(text, text, text) IS
'True when an E-Stat小地域 name corresponds to a MapFan oaza_name. 名称突合ルール一括判定。';


-- -----------------------------------------------------------------------------
--  3b. Self-test — fails loudly at install time if the parser or keys regress.
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

    -- Reverse prefix: E-Stat's aggregate name is a prefix of MapFan's chō
    ASSERT town.oaza_name_matches('紫野', '紫野西御所田町', '26') IS TRUE,  'reverse prefix kyoto';
    ASSERT town.oaza_name_matches('大宮', '大宮一ノ井町',     '26') IS TRUE,  'reverse prefix kyoto 2';
    ASSERT town.oaza_name_matches('紫野', '出雲路神楽町',     '26') IS FALSE, 'reverse prefix no false match';

    RAISE NOTICE 'town.* name-matching self-test passed.';
END
$test$;

COMMIT;


-- =============================================================================
--  4. Build the correspondence table (対応表の構築)
--     Resolves the fuzzy match ONCE into a table instead of re-evaluating it
--     on every view read. match_rule records which branch fired (see QA below).
-- =============================================================================
BEGIN;

-- Views in section 6 read from this table, so on a re-run they must be
-- dropped first or DROP TABLE fails with a dependency error.
DROP VIEW IF EXISTS town.v1_view;
DROP VIEW IF EXISTS town.v2_view;
DROP VIEW IF EXISTS town.v3_view;
DROP VIEW IF EXISTS town.v4_view;
DROP VIEW IF EXISTS town.v5_view;
DROP VIEW IF EXISTS town.v6_view;
DROP VIEW IF EXISTS town.v1_agg_view;

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
        WHEN a.name LIKE (c.oaza_name || '%')              THEN 'like_prefix'
        WHEN c.oaza_name LIKE (a.name || '%')              THEN 'reverse_prefix'
        ELSE                                                    'other'
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
--  5. QA — read-only, run before trusting the output (検証クエリ)
-- =============================================================================

-- 5.1 Link counts by rule.
-- SELECT match_rule, count(*) AS links, count(DISTINCT key_code) AS key_codes
-- FROM town.estat_oaza_link
-- GROUP BY 1 ORDER BY 2 DESC;

-- 5.2 One key_code matched to several MapFan oaza (fan-out).
--     Expected for match_rule = 'reverse_prefix' (Kyoto-style aggregate names);
--     check other rules here for unintended fan-out.
-- SELECT key_code, estat_name, count(*) AS mapfan_oaza,
--        string_agg(oaza_name || ' [' || match_rule || ']', ', ' ORDER BY oazacode)
-- FROM town.estat_oaza_link
-- GROUP BY 1, 2 HAVING count(*) > 1
-- ORDER BY 3 DESC;

-- 5.3 Several key_codes stacked on one MapFan polygon (expected for 条 grid).
-- SELECT prefcode, citycode, oazacode, oaza_name, count(*) AS estat_rows,
--        string_agg(estat_name, ', ' ORDER BY key_code)
-- FROM town.estat_oaza_link
-- GROUP BY 1, 2, 3, 4 HAVING count(*) > 1
-- ORDER BY 5 DESC;

-- 5.4 Still unmatched in Hokkaido.
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

-- 5.6 Bare-numeral guard: MapFan oaza_name that is only digits.
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
--  6. The views (ビュー生成) — one row per (E-Stat row x matched polygon),
--     one view per E-Stat table (t001081..t001086). gid needs a deterministic
--     ORDER BY or QGIS's feature-id cache misbehaves after a refresh.
--
--     DROP+CREATE, not CREATE OR REPLACE, since gid is prepended ahead of the
--     e-stat columns. If DROP hits a dependency error, something else is built
--     on top (materialized view / QGIS layer) — find it via pg_depend before CASCADE.
-- =============================================================================
BEGIN;

DROP VIEW IF EXISTS town.v1_view;
CREATE VIEW town.v1_view AS
SELECT
    ROW_NUMBER() OVER (ORDER BY a.key_code,
                                l.prefcode, l.citycode, l.oazacode) AS gid,
    a.*,
    p.shape
FROM estat.t001081 a
JOIN town.estat_oaza_link l
  ON l.key_code = a.key_code
JOIN town.oaza_polygon p
  ON  p.prefcode = l.prefcode
 AND  p.citycode = l.citycode
 AND  p.oazacode = l.oazacode
WHERE a.hyosyo IN ('2', '3');   -- kept in sync with the filter in the link build


DROP VIEW IF EXISTS town.v2_view;
CREATE VIEW town.v2_view AS
SELECT
    ROW_NUMBER() OVER (ORDER BY a.key_code,
                                l.prefcode, l.citycode, l.oazacode) AS gid,
    a.*,
    p.shape
FROM estat.t001082 a
JOIN town.estat_oaza_link l
  ON l.key_code = a.key_code
JOIN town.oaza_polygon p
  ON  p.prefcode = l.prefcode
 AND  p.citycode = l.citycode
 AND  p.oazacode = l.oazacode
WHERE a.hyosyo IN ('2', '3');

DROP VIEW IF EXISTS town.v3_view;
CREATE VIEW town.v3_view AS
SELECT
    ROW_NUMBER() OVER (ORDER BY a.key_code,
                                l.prefcode, l.citycode, l.oazacode) AS gid,
    a.*,
    p.shape
FROM estat.t001083 a
JOIN town.estat_oaza_link l
  ON l.key_code = a.key_code
JOIN town.oaza_polygon p
  ON  p.prefcode = l.prefcode
 AND  p.citycode = l.citycode
 AND  p.oazacode = l.oazacode
WHERE a.hyosyo IN ('2', '3');
DROP VIEW IF EXISTS town.v4_view;
CREATE VIEW town.v4_view AS
SELECT
    ROW_NUMBER() OVER (ORDER BY a.key_code,
                                l.prefcode, l.citycode, l.oazacode) AS gid,
    a.*,
    p.shape
FROM estat.t001084 a
JOIN town.estat_oaza_link l
  ON l.key_code = a.key_code
JOIN town.oaza_polygon p
  ON  p.prefcode = l.prefcode
 AND  p.citycode = l.citycode
 AND  p.oazacode = l.oazacode
WHERE a.hyosyo IN ('2', '3');
DROP VIEW IF EXISTS town.v5_view;
CREATE VIEW town.v5_view AS
SELECT
    ROW_NUMBER() OVER (ORDER BY a.key_code,
                                l.prefcode, l.citycode, l.oazacode) AS gid,
    a.*,
    p.shape
FROM estat.t001085 a
JOIN town.estat_oaza_link l
  ON l.key_code = a.key_code
JOIN town.oaza_polygon p
  ON  p.prefcode = l.prefcode
 AND  p.citycode = l.citycode
 AND  p.oazacode = l.oazacode
WHERE a.hyosyo IN ('2', '3');
DROP VIEW IF EXISTS town.v6_view;
CREATE VIEW town.v6_view AS
SELECT
    ROW_NUMBER() OVER (ORDER BY a.key_code,
                                l.prefcode, l.citycode, l.oazacode) AS gid,
    a.*,
    p.shape
FROM estat.t001086 a
JOIN town.estat_oaza_link l
  ON l.key_code = a.key_code
JOIN town.oaza_polygon p
  ON  p.prefcode = l.prefcode
 AND  p.citycode = l.citycode
 AND  p.oazacode = l.oazacode
WHERE a.hyosyo IN ('2', '3');
COMMENT ON VIEW town.v1_view IS
'E-Stat t001081 attributes joined to MapFan oaza polygons. May contain overlapping features where several 丁目 rows map to one polygon — see town.v1_agg_view. 重複ジオメトリの可能性あり。';

COMMIT;


-- -----------------------------------------------------------------------------
--  6b. Aggregated view — TEMPLATE, edit the measure columns before use.
--      Emits one feature per MapFan oaza with counts summed, avoiding the
--      overlapping geometries from stacked 丁目 rows. Only SUM genuine counts
--      (not ratios), and cast '-'/'X' suppressed values defensively.
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
--  7. Optional materialization for desktop GIS (QGIS 用の実体化)
--     The GIST index avoids re-running the join on every pan/zoom. After a
--     dataset swap: rebuild town.estat_oaza_link (section 4), then refresh.
-- =============================================================================
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
