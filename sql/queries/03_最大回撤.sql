-- Q3 最大回撤与波谷日期
-- 问题：每只股票历史上最惨的一笔回撤有多深？从哪天开始、哪天见底？
-- 技巧：三层递进——
--       1) 用 MAX() OVER (ORDER BY ... ROWS UNBOUNDED PRECEDING) 算出「历史最高价」；
--       2) close / 历史最高价 - 1 得到每天的实时回撤；
--       3) arg_min(日期, 回撤) 直接取出回撤最深那天的日期，不用再排序取第一条。
-- 结论：全池最大回撤中位数 -53.46%，比收益中位数 -0.11% 惨得多——回撤衡量"最差时点"，
--       收益只看首尾两个点。恩捷股份 -90.00%（锂电材料泡沫破裂），天合光能 -86.87%，
--       基本等于跌到脚踝。而建设银行 -9.88%、工商银行 -10.04% 几乎没怎么跌。
--       同一个市场里，"回撤 -90%" 和 "回撤 -10%" 是两种完全不同的产品风险等级，
--       这也是为什么配置盘要按波动率分层，而不是按收益率排名。

WITH cum AS (
    SELECT stock_code,
           trade_date,
           close,
           MAX(close) OVER (
               PARTITION BY stock_code
               ORDER BY trade_date
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
           ) AS running_peak
    FROM fact_daily_quote
),
dd AS (
    SELECT stock_code, trade_date, close, running_peak,
           close / running_peak - 1 AS drawdown
    FROM cum
),
worst AS (
    SELECT stock_code,
           MIN(drawdown)                        AS max_drawdown,
           arg_min(trade_date, drawdown)        AS trough_date
    FROM dd
    GROUP BY stock_code
),
peak AS (
    -- 见底那天对应的历史高点日期：回撤最深时，此前的最高价就是峰
    SELECT w.stock_code, MAX(d2.trade_date) AS peak_date
    FROM worst w
    JOIN dd d2
      ON d2.stock_code = w.stock_code
     AND d2.trade_date <= w.trough_date
     AND d2.close = d2.running_peak
    GROUP BY w.stock_code
)
SELECT st.stock_name                        AS 股票,
       i.industry_name                      AS 行业,
       p.peak_date                          AS 峰值日,
       w.trough_date                        AS 波谷日,
       date_diff('day', p.peak_date, w.trough_date) AS 下跌天数,
       ROUND(w.max_drawdown * 100, 2)       AS 最大回撤_pct,
       ROUND(dd_peak.close, 2)              AS 峰值价,
       ROUND(dd_trough.close, 2)            AS 波谷价
FROM worst w
JOIN peak  p  ON p.stock_code = w.stock_code
JOIN dim_stock    st ON st.stock_code = w.stock_code
JOIN dim_industry i  ON i.industry_code = st.industry_code
JOIN dd dd_peak   ON dd_peak.stock_code = w.stock_code AND dd_peak.trade_date = p.peak_date
JOIN dd dd_trough ON dd_trough.stock_code = w.stock_code AND dd_trough.trade_date = w.trough_date
ORDER BY 最大回撤_pct ASC;
