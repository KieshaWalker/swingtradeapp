-- Backfill watched_tickers with every open trade ticker so the pipeline
-- pulls data for all actively traded symbols, not just manually-watched ones.
INSERT INTO watched_tickers (user_id, ticker)
SELECT DISTINCT user_id, ticker
FROM trades
WHERE status = 'open'
ON CONFLICT (user_id, ticker) DO NOTHING;


