-- =============================================================================
-- 027_iv_snapshots_extended_fields.sql
-- =============================================================================
-- Extends iv_snapshots with the full IvAnalysis result set so the vol surface
-- screen can read regime, IV rank, skew z-score, etc. from Supabase instead
-- of recomputing approximations in Dart.
-- =============================================================================

alter table iv_snapshots
  add column if not exists iv_rank             numeric(6,2),
  add column if not exists iv_percentile       numeric(6,2),
  add column if not exists iv_rating           text,
  add column if not exists gamma_regime        text,
  add column if not exists gamma_slope         text,
  add column if not exists iv_gex_signal       text,
  add column if not exists zero_gamma_level    numeric(10,2),
  add column if not exists spot_to_zero_gamma_pct numeric(8,4),
  add column if not exists delta_gex           numeric(14,2),
  add column if not exists put_wall_density    numeric(8,4),
  add column if not exists vanna_regime        text,
  add column if not exists total_vex           numeric(14,2),
  add column if not exists total_cex           numeric(14,2),
  add column if not exists total_volga         numeric(14,2),
  add column if not exists max_vex_strike      numeric(10,2),
  add column if not exists skew_avg_52w        numeric(8,4),
  add column if not exists skew_z_score        numeric(8,4);
