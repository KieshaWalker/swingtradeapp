


alter table regime_snapshot
    add column if not exists iv_rank real,
    add column if not exists vvol_rank real;

    
