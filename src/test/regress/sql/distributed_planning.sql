SET search_path TO "distributed planning";

-- Confirm the basics work
INSERT INTO test VALUES (1, 2), (3, 4), (5, 6), (2, 7), (4, 5);
INSERT INTO test VALUES (6, 7);
SELECT * FROM test WHERE x = 1 ORDER BY y, x;
SELECT t1.x, t2.y FROM test t1 JOIN test t2 USING(x) WHERE t1.x = 1 AND t2.x = 1 ORDER BY t2.y, t1.x;
SELECT * FROM test WHERE x = 1 OR x = 2 ORDER BY y, x;
SELECT count(*) FROM test;
SELECT * FROM test ORDER BY x;
WITH cte_1 AS (UPDATE test SET y = y - 1 RETURNING *) SELECT * FROM cte_1 ORDER BY 1,2;

-- observe that there is a conflict and the following query does nothing
INSERT INTO upsert_test (part_key, other_col) VALUES (1, 1) ON CONFLICT DO NOTHING RETURNING *;

-- same as the above with different syntax
INSERT INTO upsert_test (part_key, other_col) VALUES (1, 1) ON CONFLICT (part_key) DO NOTHING RETURNING *;

-- again the same query with another syntax
INSERT INTO upsert_test (part_key, other_col) VALUES (1, 1) ON CONFLICT ON CONSTRAINT upsert_test_part_key_key DO NOTHING RETURNING *;

BEGIN;

	-- force local execution if possible
	SELECT count(*) FROM upsert_test WHERE part_key = 1;

	-- multi-shard pushdown query that goes through local execution
	INSERT INTO upsert_test (part_key, other_col) SELECT part_key, other_col FROM upsert_test ON CONFLICT ON CONSTRAINT upsert_test_part_key_key DO NOTHING RETURNING *;
	INSERT INTO upsert_test (part_key, other_col) SELECT part_key, other_col FROM upsert_test ON CONFLICT ON CONSTRAINT upsert_test_part_key_key DO UPDATE SET other_col=EXCLUDED.other_col + 1 RETURNING *;

	-- multi-shard pull-to-coordinator query that goes through local execution
	INSERT INTO upsert_test (part_key, other_col) SELECT part_key, other_col FROM upsert_test LIMIT 100 ON CONFLICT ON CONSTRAINT upsert_test_part_key_key DO NOTHING RETURNING *;
	INSERT INTO upsert_test (part_key, other_col) SELECT part_key, other_col FROM upsert_test LIMIT 100 ON CONFLICT ON CONSTRAINT upsert_test_part_key_key DO UPDATE SET other_col=EXCLUDED.other_col + 1 RETURNING *;

COMMIT;


BEGIN;
	INSERT INTO  test SELECT i,i from generate_series(0,1000)i;

	-- only pulls 1 row, should not hit the limit
	WITH cte_1 AS (SELECT * FROM test LIMIT 1) SELECT count(*) FROM cte_1;

	-- cte_1 only pulls 1 row, but cte_2 all rows
	WITH cte_1 AS (SELECT * FROM test LIMIT 1),
	     cte_2 AS (SELECT * FROM test OFFSET 0)
	SELECT count(*) FROM cte_1, cte_2;
ROLLBACK;



-- single shard and multi-shard delete
-- inside a transaction block
BEGIN;
	DELETE FROM test WHERE y = 5;
	INSERT INTO test VALUES (4, 5);

	DELETE FROM test WHERE x = 1;
	INSERT INTO test VALUES (1, 2);
COMMIT;


-- basic view queries
CREATE VIEW simple_view AS
	SELECT count(*) as cnt FROM test t1 JOIN test t2 USING (x);
SELECT * FROM simple_view;
SELECT * FROM simple_view, test WHERE test.x = simple_view.cnt;

BEGIN;
	COPY test(x) FROM STDIN;
1
2
3
4
5
6
7
8
9
10
\.
	SELECT count(*) FROM test;
	COPY (SELECT count(DISTINCT x) FROM test) TO STDOUT;
	INSERT INTO test SELECT i,i FROM generate_series(0,100)i;
ROLLBACK;

-- prepared statements with custom types
PREPARE single_node_prepare_p1(int, int, new_type) AS
	INSERT INTO test_2 VALUES ($1, $2, $3);

EXECUTE single_node_prepare_p1(1, 1, (95, 'citus9.5')::new_type);
EXECUTE single_node_prepare_p1(2 ,2, (94, 'citus9.4')::new_type);
EXECUTE single_node_prepare_p1(3 ,2, (93, 'citus9.3')::new_type);
EXECUTE single_node_prepare_p1(4 ,2, (92, 'citus9.2')::new_type);
EXECUTE single_node_prepare_p1(5 ,2, (91, 'citus9.1')::new_type);
EXECUTE single_node_prepare_p1(6 ,2, (90, 'citus9.0')::new_type);
EXECUTE single_node_prepare_p1(6 ,2, (90, 'citus9.0')::new_type);

PREPARE use_local_query_cache(int) AS SELECT count(*) FROM test_2 WHERE x =  $1;

EXECUTE use_local_query_cache(1);
EXECUTE use_local_query_cache(1);
EXECUTE use_local_query_cache(1);
EXECUTE use_local_query_cache(1);
EXECUTE use_local_query_cache(1);
EXECUTE use_local_query_cache(1);
EXECUTE use_local_query_cache(1);


BEGIN;
	INSERT INTO test_2 VALUES (7 ,2, (83, 'citus8.3')::new_type);
	SAVEPOINT s1;
	INSERT INTO test_2 VALUES (9 ,1, (82, 'citus8.2')::new_type);
	SAVEPOINT s2;
	ROLLBACK TO SAVEPOINT s1;
	SELECT * FROM test_2 WHERE z = (83, 'citus8.3')::new_type OR z = (82, 'citus8.2')::new_type;
	RELEASE SAVEPOINT s1;
COMMIT;

SELECT * FROM test_2 WHERE z = (83, 'citus8.3')::new_type OR z = (82, 'citus8.2')::new_type;

WITH cte_1 AS (SELECT * FROM test_2) SELECT * FROM cte_1 ORDER BY 1,2;

-- final query is router query
WITH cte_1 AS (SELECT * FROM test_2) SELECT * FROM cte_1, test_2 WHERE  test_2.x = cte_1.x AND test_2.x = 7 ORDER BY 1,2;

-- final query is a distributed query
WITH cte_1 AS (SELECT * FROM test_2) SELECT * FROM cte_1, test_2 WHERE  test_2.x = cte_1.x AND test_2.y != 2 ORDER BY 1,2;

SELECT count(DISTINCT x) FROM test;
SELECT count(DISTINCT y) FROM test;

-- query pushdown should work
SELECT
	*
FROM
	(SELECT x, count(*) FROM test_2 GROUP BY x) as foo,
	(SELECT x, count(*) FROM test_2 GROUP BY x) as bar
WHERE
	foo.x = bar.x
ORDER BY 1 DESC, 2 DESC, 3 DESC, 4 DESC
LIMIT 1;

-- Check repartition joins are supported
SELECT * FROM test t1, test t2 WHERE t1.x = t2.y ORDER BY t1.x, t2.x, t1.y, t2.y;


-- INSERT SELECT router
BEGIN;
INSERT INTO test(x, y) SELECT x, y FROM test WHERE x = 1;
SELECT count(*) from test;
ROLLBACK;


-- INSERT SELECT pushdown
BEGIN;
INSERT INTO test(x, y) SELECT x, y FROM test;
SELECT count(*) from test;
ROLLBACK;

-- INSERT SELECT analytical query
BEGIN;
INSERT INTO test(x, y) SELECT count(x), max(y) FROM test;
SELECT count(*) from test;
ROLLBACK;

-- INSERT SELECT repartition
BEGIN;
INSERT INTO test(x, y) SELECT y, x FROM test;
SELECT count(*) from test;
ROLLBACK;

-- INSERT SELECT from reference table into distributed
BEGIN;
INSERT INTO test(x, y) SELECT a, b FROM ref;
SELECT count(*) from test;
ROLLBACK;


-- INSERT SELECT from local table into distributed
BEGIN;
INSERT INTO test(x, y) SELECT c, d FROM local;
SELECT count(*) from test;
ROLLBACK;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO ref(a, b) SELECT x, y FROM test;
SELECT count(*) from ref;
ROLLBACK;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO ref(a, b) SELECT c, d FROM local;
SELECT count(*) from ref;
ROLLBACK;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO local(c, d) SELECT x, y FROM test;
SELECT count(*) from local;
ROLLBACK;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO local(c, d) SELECT a, b FROM ref;
SELECT count(*) from local;
ROLLBACK;

-- Confirm that dummy placements work
SELECT count(*) FROM test WHERE false;
SELECT count(*) FROM test WHERE false GROUP BY GROUPING SETS (x,y);

SELECT count(*) FROM test;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO ref(a, b) SELECT x, y FROM test;
SELECT count(*) from ref;
ROLLBACK;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO ref(a, b) SELECT c, d FROM local;
SELECT count(*) from ref;
ROLLBACK;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO local(c, d) SELECT x, y FROM test;
SELECT count(*) from local;
ROLLBACK;

-- INSERT SELECT from distributed table to local table
BEGIN;
INSERT INTO local(c, d) SELECT a, b FROM ref;
SELECT count(*) from local;
ROLLBACK;

-- values materialization test
WITH cte_1 (num,letter) AS (VALUES (1, 'one'), (2, 'two'), (3, 'three'))
SELECT
	count(*)
FROM
	test
WHERE x IN (SELECT num FROM cte_1);

-- query fails on the shards should be handled
-- nicely
\set VERBOSITY terse
SELECT x/0 FROM test;

SELECT count(DISTINCT row(key, value)) FROM non_binary_copy_test;
SELECT count(*), event FROM date_part_table GROUP BY event ORDER BY count(*) DESC, event DESC LIMIT 5;
SELECT count(*), event FROM date_part_table WHERE user_id = 1 GROUP BY event ORDER BY count(*) DESC, event DESC LIMIT 5;
SELECT count(*), t1.event FROM date_part_table t1 JOIN date_part_table USING (user_id) WHERE t1.user_id = 1 GROUP BY t1.event ORDER BY count(*) DESC, t1.event DESC LIMIT 5;

SELECT count(*), event FROM date_part_table WHERE event_time > '2020-01-05' GROUP BY event ORDER BY count(*) DESC, event DESC LIMIT 5;
SELECT count(*), event FROM date_part_table WHERE user_id = 12 AND event_time = '2020-01-12 12:00:00' GROUP BY event ORDER BY count(*) DESC, event DESC LIMIT 5;
SELECT count(*), t1.event FROM date_part_table t1 JOIN date_part_table t2 USING (user_id) WHERE t1.user_id = 1 AND t2.event_time > '2020-01-03' GROUP BY t1.event ORDER BY count(*) DESC, t1.event DESC LIMIT 5;
