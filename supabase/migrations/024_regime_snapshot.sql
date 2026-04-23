

-------THIS columns DOES NOT EXIST

---- does ANY CODE MATCH THIS INPUT? SCHWAB PULL DOES NOT HAVE THIS SO IT IS CHECKED OFF 
alter table regime_snapshots
    add column if not exists vol_sma3 float,
    add column if not exists vol_sma20 float;

    
