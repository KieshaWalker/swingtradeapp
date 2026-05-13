-- ============================================================
-- 047_economy_snapshots_anon_access
-- Grant anon role read/write access to economy snapshot tables.
--
-- These tables hold public economic data (BLS, BEA, EIA, Census,
-- market quotes) that the Flutter web app writes directly using
-- the anon key. The existing policies only cover 'authenticated',
-- causing upserts from unauthenticated sessions to return a 520
-- which the browser misreports as a CORS error.
-- ============================================================



create policy "Anon users can manage indicator snapshots"
  on economy_indicator_snapshots for all
  to anon
  using (true)
  with check (true);

create policy "Anon users can manage treasury snapshots"
  on economy_treasury_snapshots for all
  to anon
  using (true)
  with check (true);

create policy "Anon users can manage quote snapshots"
  on economy_quote_snapshots for all
  to anon
  using (true)
  with check (true);
