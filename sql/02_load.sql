-- ============================================================
-- 02_load.sql  从 data/raw/*.csv 装载
-- 显式声明列类型：不要依赖自动推断，否则 stock_code 的 '000001'
-- 会被识别成整数 1，前导零丢失 —— 这是 CSV 入库最常见的坑。
-- ============================================================

INSERT INTO dim_industry
SELECT industry_code, industry_name, industry_level
FROM read_csv('data/raw/dim_industry.csv', header = true, columns = {
    'industry_code' : 'VARCHAR',
    'industry_name' : 'VARCHAR',
    'industry_level': 'VARCHAR'
});

INSERT INTO dim_stock
SELECT stock_code, stock_name, industry_code, board, is_st::INT::BOOLEAN
FROM read_csv('data/raw/dim_stock.csv', header = true, columns = {
    'stock_code'   : 'VARCHAR',
    'stock_name'   : 'VARCHAR',
    'industry_name': 'VARCHAR',
    'board'        : 'VARCHAR',
    'industry_code': 'VARCHAR',
    'is_st'        : 'VARCHAR'
});

INSERT INTO fact_daily_quote
SELECT stock_code, trade_date, open, high, low, close, volume, amount, turnover_rate
FROM read_csv('data/raw/fact_daily_quote.csv', header = true, columns = {
    'stock_code'   : 'VARCHAR',
    'trade_date'   : 'DATE',
    'open'         : 'DOUBLE',
    'high'         : 'DOUBLE',
    'low'          : 'DOUBLE',
    'close'        : 'DOUBLE',
    'volume'       : 'BIGINT',
    'amount'       : 'DOUBLE',
    'turnover_rate': 'DOUBLE'
});

INSERT INTO fact_financial
SELECT stock_code, report_date, revenue_yoy, profit_yoy, net_margin, gross_margin,
       roe, roa, eps, bps, ocf_ps, ar_days, inv_days
FROM read_csv('data/raw/fact_financial.csv', header = true, columns = {
    'stock_code' : 'VARCHAR',
    'report_date': 'DATE',
    'revenue_yoy': 'DOUBLE',
    'profit_yoy' : 'DOUBLE',
    'net_margin' : 'DOUBLE',
    'gross_margin': 'DOUBLE',
    'roe'        : 'DOUBLE',
    'roa'        : 'DOUBLE',
    'eps'        : 'DOUBLE',
    'bps'        : 'DOUBLE',
    'ocf_ps'     : 'DOUBLE',
    'ar_days'    : 'DOUBLE',
    'inv_days'   : 'DOUBLE'
});
