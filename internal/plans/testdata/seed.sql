-- The seeded shapes of the plan rules (proof-plans.sh and the recorded fixtures of plans_test.go): one table per
-- shape, made in a database of their own. Autovacuum is off on h40 so its visibility map stays unset.
CREATE TABLE t40 (id int, v int, pad text);
INSERT INTO t40 SELECT g, g % 100, repeat('x', 40) FROM generate_series(1, 200000) g;
CREATE TABLE e40 (a int, b int);
INSERT INTO e40 SELECT g % 1000, g % 1000 FROM generate_series(1, 200000) g;
CREATE TABLE n40 (id int PRIMARY KEY, w int);
INSERT INTO n40 SELECT g, g FROM generate_series(1, 200000) g;
CREATE TABLE b40 (id int, v int, pad text);
INSERT INTO b40 SELECT g, (g * 7919) % 1000, repeat('y', 100) FROM generate_series(1, 200000) g;
CREATE INDEX b40_v ON b40 (v);
CREATE TABLE h40 (id int PRIMARY KEY, pad text) WITH (autovacuum_enabled = false);
INSERT INTO h40 SELECT g, 'z' FROM generate_series(1, 200000) g;
CREATE TABLE p40 (id int PRIMARY KEY);
INSERT INTO p40 SELECT g FROM generate_series(1, 2000) g;
CREATE TABLE c40 (id int, pid int REFERENCES p40 (id) ON DELETE CASCADE);
INSERT INTO c40 SELECT g, 1000 + g % 1000 FROM generate_series(1, 100000) g;
ANALYZE t40, e40, n40, b40, p40, c40;
ANALYZE h40;
