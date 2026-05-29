-- =============================================================================
-- 053: macro_indicators
-- User-defined macro/economic factors with a signed percentage weight.
-- Weight is -100 to +100 (stored as smallint) representing the user's
-- estimated bullish/bearish impact on their current trading environment.
-- Net score (sum of weights) is derived client-side — not stored.
-- =============================================================================

create table if not exists macro_indicators (
  id         uuid        primary key default gen_random_uuid(),
  user_id    uuid        not null references auth.users(id) on delete cascade,
  name       text        not null,
  weight     smallint    not null check (weight between -100 and 100),
  created_at timestamptz not null default now()
);

alter table macro_indicators enable row level security;

do $$ begin
  create policy "Users manage own macro indicators"
    on macro_indicators
    using  (user_id = auth.uid())
    with check (user_id = auth.uid());
exception when duplicate_object then null;
end $$;

create index if not exists macro_indicators_user_created
  on macro_indicators (user_id, created_at asc);
