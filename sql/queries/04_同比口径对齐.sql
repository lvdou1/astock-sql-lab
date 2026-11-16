-- Q4 同报告期对齐：最新一期的质量指标同比
-- 问题：最新报告期(2026Q3)里，哪些公司的应收账款和存货周转在恶化？
-- 技巧：财经数据里最容易错的一步——财务科目是「累计口径」，
--       Q3 是 1-9 月累计、Q2 是 1-6 月累计，直接拿 Q3 和 Q2 比没有任何意义。
--       正确做法是「同报告期自关联」：月份和日必须相同，年份差 1。
--       所以 JOIN 条件是 MONTH 相等 + YEAR 差 1，而不是 date - interval 1 year 之后随便连。
-- 结论：银行股四项指标全为 NULL —— 银行的报表根本没有"应收账款周转"这个科目，
--       这不是数据错误，是口径问题，因此异常筛查必须显式排除金融行业。
--       本报告期全池应收天数同比变化最大的是科大讯飞 +10.1 天，没有一家达到"恶化"级别，
--       说明这套样本里的公司整体应收管理是稳的。

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
