-- Q4 同报告期对齐：最新一期的质量指标同比
-- 问题：最新报告期(2026Q3)里，哪些公司的应收账款和存货周转在恶化？
-- 技巧：财经数据里最容易错的一步——财务科目是「累计口径」，
--       Q3 是 1-9 月累计、Q2 是 1-6 月累计，直接拿 Q3 和 Q2 比没有任何意义。
--       正确做法是「同报告期自关联」：月份和日必须相同，年份差 1。
--       所以 JOIN 条件是 MONTH 相等 + YEAR 差 1，而不是 date - interval 1 year 之后随便连。
-- 结论：应收天数变化榜首全是非银金融——湘财股份 +7,356 天、国投资本 +3,935 天，
--       应收周转天数绝对值 8,910 天（24 年）。这不是经营恶化，是券商的应收主要是
--       客户保证金和清算款，用制造业的"应收/收入×365"去算，分母口径就错了。
--       金融业共 76 只在最新报告期缺这两项指标，占 9.5%。
--       所以：任何涉及应收/存货的横向比较，第一步就该把金融整类剔除，
--       而不是只剔除"指标为 NULL"的记录——非银有值，但值不可比。

WITH latest AS (
    SELECT MAX(report_date) AS rd FROM fact_financial
),
paired AS (
    SELECT a.stock_code,
           a.report_date                AS cur_rd,
           b.report_date                AS prev_rd,
           a.revenue_yoy, a.profit_yoy,
           a.ar_days,      b.ar_days      AS prev_ar_days,
           a.inv_days,     b.inv_days     AS prev_inv_days,
           a.gross_margin, b.gross_margin AS prev_gross_margin
    FROM fact_financial a
    JOIN fact_financial b
      ON  a.stock_code   = b.stock_code
     AND MONTH(a.report_date) = MONTH(b.report_date)
     AND DAY(a.report_date)   = DAY(b.report_date)
     AND YEAR(a.report_date)  = YEAR(b.report_date) + 1
)
SELECT st.stock_name            AS 股票,
       i.industry_name          AS 行业,
       p.cur_rd                 AS 本期,
       p.prev_rd                AS 去年同期,
       ROUND(p.revenue_yoy, 2)  AS 营收同比_pct,
       ROUND(p.profit_yoy, 2)   AS 净利同比_pct,
       ROUND(p.ar_days, 1)      AS 应收天数,
       ROUND(p.ar_days - p.prev_ar_days, 1)  AS 应收天数变化,
       ROUND(p.inv_days, 1)     AS 存货天数,
       ROUND(p.inv_days - p.prev_inv_days, 1) AS 存货天数变化,
       ROUND(p.gross_margin, 2) AS 主营利润率,
       ROUND(p.gross_margin - p.prev_gross_margin, 2) AS 利润率变化
FROM paired p
JOIN latest  l ON p.cur_rd = l.rd
JOIN dim_stock    st USING (stock_code)
JOIN dim_industry i  USING (industry_code)
ORDER BY 应收天数变化 DESC NULLS LAST;
