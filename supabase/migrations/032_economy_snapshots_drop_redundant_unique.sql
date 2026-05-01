-- Drop redundant unique constraint on economy_indicator_snapshots.
-- The primary key (identifier, date) already enforces uniqueness on these
-- columns. The separate unique_identifier_date constraint is a duplicate
-- left over from a post-creation manual addition.  Having two unique indexes
-- on identical columns causes PostgreSQL to raise "ambiguous unique index"
-- on upserts that specify onConflict: 'identifier,date'.

ALTER TABLE economy_indicator_snapshots
    DROP CONSTRAINT IF EXISTS unique_identifier_date;
