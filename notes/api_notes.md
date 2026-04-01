

#	Feature	Why Now
1	Strategy × Regime Matrix	Uses existing trade data, immediate insight
2	Pre-Trade Macro Score	Uses all existing APIs, high daily value
3	Economic Calendar → Trade Alerts	APIs all wired, just need the calendar table
4	Earnings Reaction DB	Builds compounding value over time
5	IV Crush Tracker	Already capturing the data, just need the chart
6	Kalshi Event Overlay	API configured, differentiated feature
7	Insider Timeline on Price Chart	SEC data already flowing

https://api.stlouisfed.org/fred/series/observations?api_key=0c954db43e2d317e25a346b3ddfb1ed4&file_type=json&limit=500&sort_order=desc&series_id=VIXCLS

https://api.stlouisfed.org/fred/series/observations?api_key=0c954db43e2d317e25a346b3ddfb1ed4&file_type=json&limit=500&sort_order=desc&series_id=GOLDAMGBD228NLBM

https://api.stlouisfed.org/fred/series/observations?api_key=0c954db43e2d317e25a346b3ddfb1ed4&file_type=json&limit=500&sort_order=desc&series_id=SLVPRUSD

https://api.stlouisfed.org/fred/series/observations?api_key=0c954db43e2d317e25a346b3ddfb1ed4&file_type=json&limit=500&sort_order=desc&series_id=BAMLH0A0HYM2

https://api.stlouisfed.org/fred/series/observations?api_key=0c954db43e2d317e25a346b3ddfb1ed4&file_type=json&limit=500&sort_order=desc&series_id=BAMLC0A0CM

https://api.stlouisfed.org/fred/series/observations?api_key=0c954db43e2d317e25a346b3ddfb1ed4&file_type=json&limit=500&sort_order=desc&series_id=T10Y2Y

https://api.stlouisfed.org/fred/series/observations?api_key=0c954db43e2d317e25a346b3ddfb1ed4&file_type=json&limit=500&sort_order=desc&series_id=DFF


Here are all URLs the app hits, organized by service:

FMP — https://financialmodelingprep.com/stable

GET /quote?symbol={symbol}&apikey=wwUPq2ualtz00o9DCrJqYRFyZLWHZiI6
GET /search-symbol?query={q}&apikey=...
GET /profile?symbol={symbol}&apikey=...
GET /historical-price-eod/full?symbol={symbol}&from={date}&to={date}&apikey=...
GET /economic-indicators?name={name}&limit={n}&apikey=...
GET /treasury-rates?limit=1&apikey=...
GET /earnings-calendar?symbol={symbol}&from={date}&to={date}&apikey=...
Economy Pulse also calls /quote for: SPY, QQQ, VIXY, UUP, GC=F, SI=F, CL=F, NG=F, HYG, LQD, COPX

FRED — https://api.stlouisfed.org/fred

GET /series/observations?series_id=VIXCLS&api_key=0c954db43e2d317e25a346b3ddfb1ed4&file_type=json&limit=500&sort_order=desc
GET /series/observations?series_id=GOLDAMGBD228NLBM&...
GET /series/observations?series_id=SLVPRUSD&...
GET /series/observations?series_id=BAMLH0A0HYM2&...
GET /series/observations?series_id=BAMLC0A0CM&...
GET /series/observations?series_id=T10Y2Y&...
GET /series/observations?series_id=DFF&...
BLS — https://api.bls.gov/publicAPI/v2

POST /timeseries/data/
Body: { seriesid: [...], startyear, endyear, registrationkey: 93217583ea504d04a22f29111ae20521 }
Called 4 times (Employment, CPI, PPI, JOLTS) — each batch up to 50 series IDs.

BEA — https://apps.bea.gov/api/data

GET ?UserID=6B726760-97F8-4378-B759-DF2ACE8D19AF&method=GetData&DataSetName=NIPA&TableName={T10101|T10105|T10106|T10109|T20100|T10901|T20804}&...
EIA — https://api.eia.gov/v2

GET /petroleum/sum/sndw/data/?api_key=e3pafMUzOEhSyciPL5ovYXry1SGij960J9B8gfsL&...
GET /petroleum/stoc/wstk/data/?...   (crude stocks)
GET /petroleum/crd/crpdn/data/?...   (crude production, length=5000)
GET /petroleum/pri/gnd/data/?...     (gasoline prices, length=5000)
GET /natural-gas/stor/wkly/data/?...
GET /electricity/rto/fuel-type-data/data/?...
GET /petroleum/pnp/wiup/data/?...    (refinery utilization)
GET /steo/data/?...                  (strategic petroleum reserve)
Census — https://api.census.gov/data

GET /MARTS?key=84fb79d0f74e2ed803c7a32f47469e889eb923ee&get=...  (retail sales)
GET /VALCONS?key=...  (construction spending)
GET /M3?key=...       (manufacturing orders)
GET /M3S?key=...      (wholesale trade)
Supabase — https://hnuokvosmgmkzpetimtm.supabase.co

REST calls to: economy_quote_snapshots, economy_indicator_snapshots,
economy_treasury_snapshots, us_gasoline_price_history,
us_unemployment_rate_history, us_natural_gas_import_prices, trades, profiles
SEC — https://api.secfilingdata.com

POST /live-query-api   (Elasticsearch queries for filings by ticker/form type)
Kalshi — https://api.kalshi.com/v2

GET /markets?limit={n}&...
GET /markets/{ticker}/orderbook
GET /events/{eventTicker}
GET /markets/{ticker}/trades
Apify — https://api.apify.com/v2

POST /acts/{actorId}/runs?token=apify_api_3VmtRCdbU4ErpF13FMQWy0aO1eeOiG0bXGp0
POST /acts/{actorId}/run-sync-get-dataset-items?token=...
GET  /actor-runs/{runId}?token=...
GET  /datasets/{datasetId}/items?token=...


supabase functions deploy get-bls-data
supabase functions deploy get-eia-data
supabase functions deploy get-census-data
supabase functions deploy get-bea-data
supabase functions deploy get-apify-data

supabase login          # if not already
supabase link           # if not already linked to your project
supabase secrets list
To check which project you're linked to:


supabase status

supabase functions list                 # list deployed functions
supabase functions deploy <name>        # deploy one function
supabase functions deploy               # deploy all functions
supabase functions delete <name>
supabase functions serve                # run functions locally
Secrets


supabase secrets list                   # list secret names (not values)
supabase secrets set KEY=value          # set one or more secrets
supabase secrets unset KEY              # delete a secret
Database


supabase db pull                        # pull remote schema to local
supabase db push                        # push local migrations to remote
supabase db diff                        # diff local vs remote schema
supabase db reset                       # reset local DB and re-run migrations
supabase migration list                 # list migrations
supabase migration new <name>           # create a new migration file
Local Dev


supabase start                          # start local Supabase stack (Docker)
supabase stop                           # stop local stack
supabase db studio                      # open local Studio UI