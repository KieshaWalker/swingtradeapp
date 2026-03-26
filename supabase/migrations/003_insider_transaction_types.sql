-- Extend ticker_insider_buys to support all Form 4 transaction types (not just buys).
ALTER TABLE ticker_insider_buys
  DROP CONSTRAINT ticker_insider_buys_transaction_type_check,
  ADD CONSTRAINT ticker_insider_buys_transaction_type_check
    CHECK (transaction_type IN ('purchase', 'sale', 'exercise', 'gift', 'tax_withholding', 'other'));
