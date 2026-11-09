-- 0005_engine: the repository is engine-neutral at the core. Every instance names its engine
-- (postgres today; another engine later brings its own collections and import functions and
-- reuses instances, collection_dates and the purge).
ALTER TABLE pgvigil.instances ADD COLUMN IF NOT EXISTS engine text NOT NULL DEFAULT 'postgres';
