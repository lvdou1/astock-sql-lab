-- ============================================================
-- 02_load.sql  从 data/ 装载
--
-- 两类文件、两种处理方式，这个区别本身值得注意：
--   维度表 → CSV：行数少、人要能直接打开看，用 CSV 更合适。
--            但必须显式声明列类型，否则 stock_code 的 '000001'
--            会被识别成整数 1，前导零丢失 —— CSV 入库最常见的坑。
--            这里先 all_varchar 全读成文本，再按「列名」CAST。
--            不要用 read_csv 的 columns={...} 参数：它是按位置匹配的，
--            CSV 一加字段就整体错位，报错信息还极难懂（本项目踩过）。
--   事实表 → Parquet：行数多、只给程序读，列存 + ZSTD 压缩后约 3 MB，
--            而且 schema 跟着数据走，不需要再手写字段类型。
-- ============================================================

INSERT INTO dim_industry
SELECT "industry_code"::VARCHAR  AS industry_code,
       "industry_name"::VARCHAR  AS industry_name,
       "industry_level"::VARCHAR AS industry_level
FROM read_csv('data/dim_industry.csv', header = true, all_varchar = true);

INSERT INTO dim_stock
SELECT "stock_code"::VARCHAR       AS stock_code,
       "stock_name"::VARCHAR       AS stock_name,
       "industry_code"::VARCHAR    AS industry_code,
       "board"::VARCHAR            AS board,
       "index_membership"::VARCHAR AS index_membership,
       "is_st"::INT::BOOLEAN       AS is_st
FROM read_csv('data/dim_stock.csv', header = true, all_varchar = true);

-- Parquet 自带类型信息，直接整表灌入
INSERT INTO fact_daily_quote
SELECT * FROM read_parquet('data/fact_daily_quote.parquet');

INSERT INTO fact_financial
SELECT * FROM read_parquet('data/fact_financial.parquet');
