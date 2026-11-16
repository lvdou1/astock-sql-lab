-- Q1 区间累计收益与年化收益
-- 问题：2022 年初至最近一个交易日，股票池里谁赚得最多？年化是多少？
-- 技巧：首尾取价用条件聚合（MAX + CASE），避免为取一个值写两次子查询；
--       年化按「实际交易日数」折算，而不是自然日 365，否则会低估。
-- 结论：22 只里只有 6 只取得正收益，中位数 -9.46%。紫金矿业 +165.74% 排第一（有色金属周期行情），
--       ST康美 -54.57% 垫底。注意价格是后复权，收益率可直接横向比较，但不能与行情软件报价对照。

WITH span AS (
    SELECT stock_code,
           MIN(trade_date) AS d0,
           MAX(trade_date) AS d1,
           COUNT(*)        AS n_days      -- 实际交易日数，用于年化折算
    FROM fact_daily_quote
    GROUP BY stock_code
),
px AS (
    SELECT s.stock_code, s.d0, s.d1, s.n_days,
           MAX(CASE WHEN q.trade_date = s.d0 THEN q.close END) AS p0,
           MAX(CASE WHEN q.trade_date = s.d1 THEN q.close END) AS p1
    FROM span s
    JOIN fact_daily_quote q USING (stock_code)
    GROUP BY s.stock_code, s.d0, s.d1, s.n_days
)
SELECT st.stock_name                                      AS 股票,
       st.board                                           AS 板块,
       i.industry_name                                    AS 行业,
       px.d0                                              AS 起始日,
       px.d1                                              AS 结束日,
       ROUND(px.p0, 2)                                    AS 期初价,
       ROUND(px.p1, 2)                                    AS 期末价,
       ROUND((px.p1 / px.p0 - 1) * 100, 2)                AS 累计收益_pct,
       ROUND((POWER(px.p1 / px.p0, 252.0 / px.n_days) - 1) * 100, 2) AS 年化_pct
FROM px
JOIN dim_stock   st USING (stock_code)
JOIN dim_industry i USING (industry_code)
ORDER BY 累计收益_pct DESC;
