-- =============================================================================
-- 072_fix_positions_updated_at_trigger
-- =============================================================================
-- positions.updated_at has silently never been maintained: 042_position_model
-- .sql was written to create update_updated_at_column() and wire it to both
-- positions and enriched_legs, but the live database's `positions` table
-- (and its RLS policies -- "Users can view their own positions" etc., not
-- 042's "positions_select" naming) doesn't match that file at all. The
-- table was evidently created by an earlier hand-applied schema, and 042
-- was written to document it after the fact without ever actually running
-- against this database. update_updated_at_column() genuinely doesn't
-- exist in `public` (only a same-named, unrelated one in the `storage`
-- schema does) -- confirmed via direct inspection, not assumed from the
-- migration file.
--
-- enriched_legs turned out fine on inspection: it already has a working
-- trigger (update_enriched_legs_modtime), just calling a differently-named
-- but functionally identical function (update_modified_column(), also
-- pre-existing and live) -- so it's left alone here. positions is the only
-- actual gap: zero triggers on it. Reusing update_modified_column() rather
-- than introducing a third equivalent function, since it's already the
-- live convention for this exact table family.
-- =============================================================================

CREATE TRIGGER trg_positions_updated_at
    BEFORE UPDATE ON positions
    FOR EACH ROW EXECUTE FUNCTION update_modified_column();
