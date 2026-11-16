-- Q6 数据质量报告
-- 问题：这份数据干不干净？哪些"异常"是真问题，哪些只是规则差异？
-- 技巧：用 UNION ALL 把多个校验维度拼成一张体检表。
--       比写 5 个脚本、看 5 份输出高效得多，也是数据岗面试常问的
--       "你怎么保证数据质量"的标准答法。
-- 关键设计：把「规则内波动」和「真异常」分开统计。
--       科创板/创业板新股上市前 5 个交易日不设涨跌幅限制，会产生 ±90% 的单日涨幅。
--       如果不区分，要么误报一堆（把规则当错误），要么把阈值放宽到 ±100%（真异常漏掉）。
-- 结论：7 项里真正需要人介入的只有 1 条 —— 中孚实业 2024-07-09 单日 +22.5%，
--       它不是新股（上市第 606 个交易日），大概率是重组/定增复牌当日不设涨跌幅，
--       属于"规则解释得通但要看公告确认"的情况。
--       其余 4 条极端波动全部来自合合信息(688615)上市前 5 日，规则内正常。
--       所以：数据可以直接用来算收益和回撤；但凡涉及应收/存货的统计，
--       必须先过滤金融行业，否则均值会被系统性拉偏。

WITH quote AS (
    SELECT stock_code, trade_date, close,
           ROW_NUMBER() OVER (PARTITION BY stock_code ORDER BY trade_date) AS rn,
           close / LAG(close) OVER (PARTITION BY stock_code ORDER BY trade_date) - 1 AS ret
    FROM fact_daily_quote
),
mkt AS (
    SELECT COUNT(DISTINCT trade_date) AS n_dates FROM fact_daily_quote
),
per_stock AS (
    SELECT stock_code, COUNT(*) AS n_rows FROM quote GROUP BY stock_code
),
fin_dates AS (
    SELECT COUNT(DISTINCT report_date) AS n_periods FROM fact_financial
),
per_fin AS (
    SELECT stock_code, COUNT(*) AS n_fin FROM fact_financial GROUP BY stock_code
),
checks AS (
    -- 1. 主键是否重复（理想结果 = 0）
    SELECT '主键重复行数'                                 AS 检查项,
           (SELECT COUNT(*) FROM (
               SELECT stock_code, trade_date FROM fact_daily_quote
               GROUP BY 1, 2 HAVING COUNT(*) > 1))        AS 异常数,
           '应为 0'                                       AS 说明

    UNION ALL
    -- 2. 交易日覆盖不足（停牌、上市较晚）
    SELECT '交易日少于全市场',
           (SELECT COUNT(*) FROM per_stock, mkt WHERE n_rows < n_dates),
           '停牌或上市较晚，非数据错误'

    UNION ALL
    -- 3. 财务营运指标缺失（金融业口径）
    SELECT '应收/存货天数缺失',
           (SELECT COUNT(*) FROM fact_financial WHERE ar_days IS NULL OR inv_days IS NULL),
           '银行/非银无此科目，属口径差异'

    UNION ALL
    -- 4. 财务期间不足（上市晚的公司报告期天然少）
    SELECT '财务报告期数不足',
           (SELECT COUNT(*) FROM per_fin, fin_dates WHERE n_fin < n_periods),
           '报告期少于全池期数'

    UNION ALL
    -- 5. 极端涨跌幅：拆成「规则内」与「真异常」两个口径
    SELECT '极端涨跌幅(新股前5日,规则内)',
           (SELECT COUNT(*) FROM quote WHERE ABS(ret) > 0.21 AND rn <= 5),
           '注册制新股上市前5日不设涨跌幅限制'

    UNION ALL
    SELECT '极端涨跌幅(非新股,需核查)',
           (SELECT COUNT(*) FROM quote WHERE ABS(ret) > 0.21 AND rn > 5),
           '复牌/重组当日可能不设涨跌幅，需看公告'

    UNION ALL
    -- 6. 价格为空的记录
    SELECT '收盘价为空',
           (SELECT COUNT(*) FROM fact_daily_quote WHERE close IS NULL OR close <= 0),
           '应为 0'
)
SELECT 检查项, 异常数, 说明,
       CASE WHEN 异常数 = 0            THEN '通过'
            WHEN 检查项 LIKE '%规则内%' THEN '正常'
            WHEN 检查项 LIKE '%缺失%'   THEN '口径差异'
            ELSE '需关注' END            AS 结论
FROM checks;
