-- Q6 数据质量报告
-- 问题：这份数据干不干净？哪些字段是「有值但不可用」的？
-- 技巧：用 UNION ALL 把多个校验维度拼成一张体检表。
--       比写 5 个脚本、看 5 份输出高效得多，也是数据岗面试常问的"你怎么保证数据质量"的标准答法。
-- 结论：6 项检查里 4 项通过、2 项需关注——
--   1) ST康美 只有 1176 个交易日，比全市场少 2 天（停牌）；
--   2) 应收/存货天数有 79 条为空，全部来自 4 家银行（口径差异，不是脏数据）。
--   主键无重复、无空价格、复权后无异常涨跌幅，说明这份数据可以直接用来算收益和回撤；
--   但任何涉及应收/存货的统计都必须先过滤掉金融行业，否则均值会被系统性拉偏。

WITH mkt AS (
    SELECT COUNT(DISTINCT trade_date) AS n_dates FROM fact_daily_quote
),
per_stock AS (
    SELECT stock_code, COUNT(*) AS n_rows FROM fact_daily_quote GROUP BY stock_code
),
fin_dates AS (
    SELECT COUNT(DISTINCT report_date) AS n_periods FROM fact_financial
),
per_fin AS (
    SELECT stock_code, COUNT(*) AS n_fin FROM fact_financial GROUP BY stock_code
),
checks AS (
    -- 1. 主键是否重复（理想结果 = 0）
    SELECT '主键重复行数'                                             AS 检查项,
           (SELECT COUNT(*) FROM (
               SELECT stock_code, trade_date FROM fact_daily_quote
               GROUP BY 1, 2 HAVING COUNT(*) > 1))                    AS 异常数,
           '应为 0'                                                   AS 说明

    UNION ALL
    -- 2. 交易日覆盖不足的股票（停牌）
    SELECT '交易日少于全市场',
           (SELECT COUNT(*) FROM per_stock, mkt WHERE n_rows < n_dates),
           '停牌导致，非数据错误'

    UNION ALL
    -- 3. 财务营运指标缺失（银行口径）
    SELECT '应收/存货天数缺失',
           (SELECT COUNT(*) FROM fact_financial WHERE ar_days IS NULL OR inv_days IS NULL),
           '银行等金融业无此科目，属口径差异'

    UNION ALL
    -- 4. 财务期间不连续
    SELECT '财务报告期数不足',
           (SELECT COUNT(*) FROM per_fin, fin_dates WHERE n_fin < n_periods),
           '报告期少于全池期数'

    UNION ALL
    -- 5. 极端单日收益（复权后不应出现，出现即数据异常）
    SELECT '单日涨跌幅超过21%',
           (SELECT COUNT(*) FROM (
               SELECT stock_code, trade_date,
                      close / LAG(close) OVER (PARTITION BY stock_code ORDER BY trade_date) - 1 AS r
               FROM fact_daily_quote) t
            WHERE ABS(r) > 0.21),
           '后复权数据不应出现，需人工核查'

    UNION ALL
    -- 6. 价格为空的记录
    SELECT '收盘价为空',
           (SELECT COUNT(*) FROM fact_daily_quote WHERE close IS NULL OR close <= 0),
           '应为 0'
)
SELECT 检查项, 异常数, 说明,
       CASE WHEN 异常数 = 0 THEN '通过' ELSE '需关注' END AS 结论
FROM checks;
