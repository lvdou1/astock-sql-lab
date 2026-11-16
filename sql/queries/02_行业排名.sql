-- Q2 行业内排名与超额收益
-- 问题：每只股票在自己的行业里排第几？跑赢/跑输行业中位数多少？
-- 技巧：ROW_NUMBER 做名次，MEDIAN() OVER (PARTITION BY) 在同一次扫描里算出行业基准，
--       不必再写一个 GROUP BY 子查询回连——这是窗口函数最典型的用法。
-- 结论：绝对收益高不代表做得好，要看超额。交通运输行业最强，招商轮船 +260.92%，
--       而行业中位数只有 +3.63%，超额 +257.29pct——航运周期股在 2022-2026 是最大赢家。
--       反面是食品饮料：21 只里中位数 -37.81%，重庆啤酒 -62.15% 垫底，
--       说明"大行业"不等于"好行业"，样本足够时行业基准才有意义（电子 77 只、医药生物 63 只）。

WITH span AS (
    SELECT stock_code, MIN(trade_date) AS d0, MAX(trade_date) AS d1, COUNT(*) AS n_days
    FROM fact_daily_quote
    GROUP BY stock_code
    -- 与 Q1 保持同一评估窗口：只保留区间内全程有数据的标的
    HAVING MIN(trade_date) = (SELECT MIN(trade_date) FROM fact_daily_quote)
),
px AS (
    SELECT s.stock_code, s.d0,
           MAX(CASE WHEN q.trade_date = s.d0 THEN q.close END) AS p0,
           MAX(CASE WHEN q.trade_date = s.d1 THEN q.close END) AS p1
    FROM span s JOIN fact_daily_quote q USING (stock_code)
    GROUP BY s.stock_code, s.d0
),
ret AS (
    SELECT st.stock_code, st.stock_name, i.industry_name, i.industry_level,
           (px.p1 / px.p0 - 1) * 100 AS cum_return_pct
    FROM px
    JOIN dim_stock    st USING (stock_code)
    JOIN dim_industry i  USING (industry_code)
),
ranked AS (
    SELECT r.*,
           ROW_NUMBER() OVER (PARTITION BY industry_name ORDER BY cum_return_pct DESC) AS rk,
           COUNT(*)     OVER (PARTITION BY industry_name)                                AS n_in_industry,
           MEDIAN(cum_return_pct) OVER (PARTITION BY industry_name)                      AS ind_median
    FROM ret r
)
SELECT industry_name                                   AS 行业,
       industry_level                                  AS 一级归类,
       rk || '/' || n_in_industry                      AS 行业内排名,
       stock_name                                      AS 股票,
       ROUND(cum_return_pct, 2)                        AS 累计收益_pct,
       ROUND(ind_median, 2)                            AS 行业中位数_pct,
       ROUND(cum_return_pct - ind_median, 2)           AS 超额收益_pct,
       CASE WHEN n_in_industry < 3 THEN '样本过少' ELSE '' END AS 备注
FROM ranked
ORDER BY industry_name, rk;
