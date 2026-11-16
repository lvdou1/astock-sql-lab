-- Q1 区间累计收益与年化收益
-- 问题：2022 年初至最近一个交易日，股票池里谁赚得最多？年化是多少？
-- 技巧：首尾取价用条件聚合（MAX + CASE），避免为取一个值写两次子查询；
--       年化按「实际交易日数」折算，而不是自然日 365，否则会低估。
-- 结论：730 只（区间内全程有数据）里 359 只取得正收益，收益中位数 -0.78%，但均值 +26.66%。
--       均值是中位数的 34 倍，因为长尾被极端值撑起来了：寒武纪 +1258%、中际旭创 +1256%。
--       ——这就是"平均收益"在金融数据里不可信的原因，一定要看中位数和分位数。
--       分指数看更清楚：沪深300 中位 +8.44%（153/282 正收益），中证500 中位 -2.73%（206/448）。
--       这五年大盘跑赢中盘，与"小盘股长期占优"的直觉相反。

WITH span AS (
    SELECT stock_code,
           MIN(trade_date) AS d0,
           MAX(trade_date) AS d1,
           COUNT(*)        AS n_days      -- 实际交易日数，用于年化折算
    FROM fact_daily_quote
    GROUP BY stock_code
    -- 统一评估窗口：只保留区间内全程有数据的标的。
    -- 2022 年后上市的新股窗口更短，累计收益不可与全程标的直接比较
    -- （例如德明利 2022-07 上市，五年涨幅会被高估）。详见 Q6 的交易日覆盖检查。
    HAVING MIN(trade_date) = (SELECT MIN(trade_date) FROM fact_daily_quote)
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
       st.index_membership                                AS 所属指数,
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
