-- Drop redundant unique constraint on sabr_calibrations.
-- sabr_calibrations_user_id_ticker_obs_date_dte_key already enforces
-- uniqueness on (user_id, ticker, obs_date, dte) via the UNIQUE declaration
-- in migration 021.  unique_user_ticker_date is an identical duplicate added
-- manually afterward.  Having two unique indexes on the same columns causes
-- PostgreSQL to raise "ambiguous unique index" on upserts specifying
-- on_conflict="user_id,ticker,obs_date,dte".

ALTER TABLE sabr_calibrations
    DROP CONSTRAINT IF EXISTS unique_user_ticker_date;
