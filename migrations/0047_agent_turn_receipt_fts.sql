-- ── Exclude kind 44201 (NIP-AR Agent Turn Receipts) from full-text search ────
--
-- A receipt is deliberately public to its channel, so this is not a privacy
-- exclusion like 0005 (44200), 0014 (30350) or 0033 (30179). Its content is a
-- JSON usage record — model id, harness id, token counts — and tokenizing it
-- would put that into the results of every ordinary channel search.
--
-- Same wrap-the-existing-expression shape as 0014/0033: PostgreSQL cannot alter
-- a generated expression in place, so capture the current expression, drop the
-- column, and re-add it wrapped with the new exclusion. Every other kind keeps
-- whatever policy the database had before.
--
-- Unlike 0014/0033 this migration first asks whether the rewrite is needed at
-- all. Migration 0008 gives fresh databases a positive FTS allowlist
-- (kinds 0, 9, 40002, 45001, 45003), and scripts/maintenance/
-- nip_rs_search_allowlist.sql converges brownfield databases onto the same
-- expression out of band. Both already yield NULL for kind 44201, so for those
-- databases the rewrite below would be a pure no-op that still rewrites the
-- entire events heap and rebuilds the partitioned GIN index under ACCESS
-- EXCLUSIVE. The probe is exact rather than textual: it builds a throwaway
-- table carrying the live generated expression, feeds it a kind-44201 row, and
-- skips the rewrite only when the expression really does suppress it.
--
-- When the probe says the rewrite IS needed (a database still on the legacy
-- negative skip-set from 0001/0005), the cost is the one 0033 documents:
-- a full heap rewrite plus GIN rebuild under ACCESS EXCLUSIVE inside this
-- migration's transaction, with no lock_timeout. The index is recreated from
-- the stock definition below; non-stock indexes or storage parameters on
-- search_tsv are not captured or replayed. Operators with large brownfield
-- databases should schedule a window.
DO $$
DECLARE
    existing_expression TEXT;
    already_suppressed  BOOLEAN := FALSE;
BEGIN
    SELECT pg_get_expr(d.adbin, d.adrelid)
      INTO existing_expression
      FROM pg_attrdef d
      JOIN pg_attribute a
        ON a.attrelid = d.adrelid
       AND a.attnum = d.adnum
     WHERE d.adrelid = 'events'::regclass
       AND a.attname = 'search_tsv';

    IF existing_expression IS NULL THEN
        RAISE EXCEPTION 'events.search_tsv generated expression not found';
    END IF;

    -- Probe: does the live expression already yield NULL for kind 44201?
    -- Any failure here (an expression referencing columns this probe does not
    -- model) falls through to the rewrite, which is the safe answer.
    BEGIN
        EXECUTE format(
            'CREATE TEMP TABLE _search_tsv_probe (kind INT NOT NULL, content TEXT NOT NULL, '
            'search_tsv TSVECTOR GENERATED ALWAYS AS (%s) STORED) ON COMMIT DROP',
            existing_expression
        );
        INSERT INTO _search_tsv_probe (kind, content) VALUES (44201, 'agent turn receipt probe');
        SELECT bool_and(search_tsv IS NULL) INTO already_suppressed FROM _search_tsv_probe;
        DROP TABLE _search_tsv_probe;
    EXCEPTION WHEN OTHERS THEN
        already_suppressed := FALSE;
    END;

    IF already_suppressed THEN
        RAISE NOTICE 'events.search_tsv already excludes kind 44201; skipping heap rewrite';
        RETURN;
    END IF;

    ALTER TABLE events DROP COLUMN search_tsv;
    EXECUTE format(
        'ALTER TABLE events ADD COLUMN search_tsv TSVECTOR GENERATED ALWAYS AS (CASE WHEN kind = 44201 THEN NULL::tsvector ELSE (%s) END) STORED',
        existing_expression
    );
    CREATE INDEX idx_events_search_tsv ON events USING GIN (search_tsv);
END $$;
