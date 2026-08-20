CREATE OR REPLACE VIEW town.v1_view AS 
SELECT 
    -- 1. Create a unique integer ID required by GIS desktop tools
    ROW_NUMBER() OVER () AS gid,
    a.*, 
    p.shape
FROM estat.t001081 a
-- Join MapFan code master with MapFan polygons
JOIN town.oaza_code c
  ON c.prefcode || c.citycode = SUBSTR(a.key_code, 1, 5)
JOIN town.oaza_polygon p
  ON c.prefcode = p.prefcode 
 AND c.citycode = p.citycode 
 AND c.oazacode = p.oazacode
WHERE a.hyosyo IN ('2', '3')
  -- Flexible name matching across Urban (3) and Rural (2)
  AND (
      a.name = c.oaza_name
      OR REPLACE(a.name, '大字', '') = c.oaza_name
      OR a.name LIKE (c.oaza_name || '%')
  );

CREATE OR REPLACE VIEW town.v2_view AS 
SELECT 
    -- 1. Create a unique integer ID required by GIS desktop tools
    ROW_NUMBER() OVER () AS gid,
    a.*, 
    p.shape
FROM estat.t001082 a
-- Join MapFan code master with MapFan polygons
JOIN town.oaza_code c
  ON c.prefcode || c.citycode = SUBSTR(a.key_code, 1, 5)
JOIN town.oaza_polygon p
  ON c.prefcode = p.prefcode 
 AND c.citycode = p.citycode 
 AND c.oazacode = p.oazacode
WHERE a.hyosyo IN ('2', '3')
  -- Flexible name matching across Urban (3) and Rural (2)
  AND (
      a.name = c.oaza_name
      OR REPLACE(a.name, '大字', '') = c.oaza_name
      OR a.name LIKE (c.oaza_name || '%')
  );

CREATE OR REPLACE VIEW town.v3_view AS 
SELECT 
    -- 1. Create a unique integer ID required by GIS desktop tools
    ROW_NUMBER() OVER () AS gid,
    a.*, 
    p.shape
FROM estat.t001083 a
-- Join MapFan code master with MapFan polygons
JOIN town.oaza_code c
  ON c.prefcode || c.citycode = SUBSTR(a.key_code, 1, 5)
JOIN town.oaza_polygon p
  ON c.prefcode = p.prefcode 
 AND c.citycode = p.citycode 
 AND c.oazacode = p.oazacode
WHERE a.hyosyo IN ('2', '3')
  -- Flexible name matching across Urban (3) and Rural (2)
  AND (
      a.name = c.oaza_name
      OR REPLACE(a.name, '大字', '') = c.oaza_name
      OR a.name LIKE (c.oaza_name || '%')
  );

CREATE OR REPLACE VIEW town.v4_view AS 
SELECT 
    -- 1. Create a unique integer ID required by GIS desktop tools
    ROW_NUMBER() OVER () AS gid,
    a.*, 
    p.shape
FROM estat.t001084 a
-- Join MapFan code master with MapFan polygons
JOIN town.oaza_code c
  ON c.prefcode || c.citycode = SUBSTR(a.key_code, 1, 5)
JOIN town.oaza_polygon p
  ON c.prefcode = p.prefcode 
 AND c.citycode = p.citycode 
 AND c.oazacode = p.oazacode
WHERE a.hyosyo IN ('2', '3')
  -- Flexible name matching across Urban (3) and Rural (2)
  AND (
      a.name = c.oaza_name
      OR REPLACE(a.name, '大字', '') = c.oaza_name
      OR a.name LIKE (c.oaza_name || '%')
  );

CREATE OR REPLACE VIEW town.v5_view AS 
SELECT 
    -- 1. Create a unique integer ID required by GIS desktop tools
    ROW_NUMBER() OVER () AS gid,
    a.*, 
    p.shape
FROM estat.t001085 a
-- Join MapFan code master with MapFan polygons
JOIN town.oaza_code c
  ON c.prefcode || c.citycode = SUBSTR(a.key_code, 1, 5)
JOIN town.oaza_polygon p
  ON c.prefcode = p.prefcode 
 AND c.citycode = p.citycode 
 AND c.oazacode = p.oazacode
WHERE a.hyosyo IN ('2', '3')
  -- Flexible name matching across Urban (3) and Rural (2)
  AND (
      a.name = c.oaza_name
      OR REPLACE(a.name, '大字', '') = c.oaza_name
      OR a.name LIKE (c.oaza_name || '%')
  );

CREATE OR REPLACE VIEW town.v6_view AS 
SELECT 
    -- 1. Create a unique integer ID required by GIS desktop tools
    ROW_NUMBER() OVER () AS gid,
    a.*, 
    p.shape
FROM estat.t001086 a
-- Join MapFan code master with MapFan polygons
JOIN town.oaza_code c
  ON c.prefcode || c.citycode = SUBSTR(a.key_code, 1, 5)
JOIN town.oaza_polygon p
  ON c.prefcode = p.prefcode 
 AND c.citycode = p.citycode 
 AND c.oazacode = p.oazacode
WHERE a.hyosyo IN ('2', '3')
  -- Flexible name matching across Urban (3) and Rural (2)
  AND (
      a.name = c.oaza_name
      OR REPLACE(a.name, '大字', '') = c.oaza_name
      OR a.name LIKE (c.oaza_name || '%')
  );


