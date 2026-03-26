-- Persists tickers the user has browsed via search (independent of trades).
-- Merged with trade-derived tickers in TickerDashboardScreen.
CREATE TABLE watched_tickers (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  ticker     TEXT NOT NULL,
  added_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, ticker)
);

ALTER TABLE watched_tickers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage their own watched tickers"
  ON watched_tickers FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE INDEX idx_watched_tickers_user ON watched_tickers (user_id, added_at DESC);
