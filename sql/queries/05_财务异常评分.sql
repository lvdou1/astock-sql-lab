-- Q5 财务异常评分（项目核心）
-- 问题：用五条会计逻辑规则扫描中证800，哪些公司同时踩中多条？
-- 设计原则：单指标异常大多不是财务问题，是行业属性或口径差异。
--           所以每条规则都要求「两个信号同时成立」，这比单阈值可靠得多。
--   R1 利润与营收背离 : 净利增速 - 营收增速 > 50pct 且 营收增速 < 10%
--                        （利润不是主营业务挣来的，靠投资收益/卖资产/补贴）
--   R2 收入质量恶化   : 营收增速 > 15% 且 应收天数同比增 > 30 天
--                        （放宽信用政策换收入，钱没收回来）
--   R3 存货积压       : 存货天数同比增 > 30 天 且 营收增速 < 5% 且 毛利率同比降 > 2pct
--                        （货卖不动且开始降价——关键是这个毛利率条件，否则会把
--                          白酒的基酒储备、地产的土储误判成积压）
--   R4 现金流背离     : 每股经营现金流由正转负 且 净利增速 > 0
--                        （赚钱但收不到现金。注意：只能用「由正转负」，
--                          因为 A 股财务报表是累计口径，Q1 的经营现金流天然常为负，
--                          直接判 ocf<0 会误伤约三成的一季报）
--   R5 毛利率下滑     : 主营利润率同比下降 > 5pct（议价能力或成本控制出问题）
-- 为什么排除整个金融大类（银行 + 非银）：
--       银行没有应收/存货科目（全 NULL），这个好识别；
--       但非银金融有应收科目，口径却完全不同——券商的应收主要是客户保证金和清算款，
--       湘财股份的应收周转天数算出来是 8,910 天（24 年），不是造假，是分母口径错了。
--       如果只按「IS NOT NULL」过滤，湘财会被评成高风险——这是本项目最典型的一个误报。
-- 技巧：MAX(...) FILTER (WHERE ...) 一次算出「近期」和「全历史」两套统计，不必写两个查询。
-- 结论：717 只入围，高风险 1 只（九安医疗 4 分：R1+R3+R4+R5），关注 32 只，其余正常或轻微。
--       九安医疗是疫情红利退潮的典型：2022 年抗原检测暴赚，此后营收与利润同步崩塌、
--       存货天数飙升、毛利率腰斩、现金流由正转负——四条规则同时共振。
--       但要强调：**这是"经营剧变"，不是"财务造假"**。规则只能标记异常，
--       判定性质必须回去读公告和年报。SQL 只能发现异常，不能判定异常。

WITH paired AS (
    SELECT a.stock_code,
           a.report_date,
           a.revenue_yoy, a.profit_yoy,
           a.ocf_ps,   b.ocf_ps  AS prev_ocf_ps,
           a.ar_days,  b.ar_days AS prev_ar_days,
           a.inv_days, b.inv_days AS prev_inv_days,
           a.gross_margin, b.gross_margin AS prev_gm
    FROM fact_financial a
    JOIN fact_financial b
      ON  a.stock_code = b.stock_code
     AND MONTH(a.report_date) = MONTH(b.report_date)
     AND DAY(a.report_date)   = DAY(b.report_date)
     AND YEAR(a.report_date)  = YEAR(b.report_date) + 1
),
scored AS (
    SELECT p.*,
           CASE WHEN profit_yoy - revenue_yoy > 50 AND revenue_yoy < 10
                THEN 1 ELSE 0 END AS r1,
           CASE WHEN revenue_yoy > 15 AND ar_days - prev_ar_days > 30
                THEN 1 ELSE 0 END AS r2,
           CASE WHEN inv_days - prev_inv_days > 30
                 AND revenue_yoy < 5
                 AND gross_margin < prev_gm - 2
                THEN 1 ELSE 0 END AS r3,
           CASE WHEN ocf_ps < 0 AND prev_ocf_ps > 0 AND profit_yoy > 0
                THEN 1 ELSE 0 END AS r4,
           CASE WHEN gross_margin < prev_gm - 5
                THEN 1 ELSE 0 END AS r5
    FROM paired p
    JOIN dim_stock    st ON st.stock_code = p.stock_code
    JOIN dim_industry i  ON i.industry_code = st.industry_code
    WHERE i.industry_level <> '金融'   -- 银行无非应收科目，非银有但口径不同，整类排除
),
flagged AS (
    SELECT *,
           r1 + r2 + r3 + r4 + r5 AS score,
           report_date > (SELECT MAX(report_date) FROM fact_financial) - INTERVAL 1 YEAR AS is_recent
    FROM scored
),
agg AS (
    SELECT stock_code,
           COUNT(*) FILTER (WHERE is_recent)      AS 近期观测期数,
           MAX(score) FILTER (WHERE is_recent)    AS 近期最高分,
           SUM(score) FILTER (WHERE is_recent)    AS 近期命中合计,
           MAX(score)                            AS 历史最高分,
           COUNT(*) FILTER (WHERE score >= 2)    AS 多指标共振期数,
           string_agg(DISTINCT CASE WHEN r1 = 1 THEN 'R1' END, ',') AS 命中R1,
           string_agg(DISTINCT CASE WHEN r2 = 1 THEN 'R2' END, ',') AS 命中R2,
           string_agg(DISTINCT CASE WHEN r3 = 1 THEN 'R3' END, ',') AS 命中R3,
           string_agg(DISTINCT CASE WHEN r4 = 1 THEN 'R4' END, ',') AS 命中R4,
           string_agg(DISTINCT CASE WHEN r5 = 1 THEN 'R5' END, ',') AS 命中R5,
           arg_max(report_date, score)           AS 最差报告期
    FROM flagged
    GROUP BY stock_code
)
SELECT st.stock_name                                   AS 股票,
       i.industry_name                                 AS 行业,
       a.近期观测期数,
       COALESCE(a.近期最高分, 0)                       AS 近期最高分,
       COALESCE(a.近期命中合计, 0)                     AS 近期命中合计,
       a.历史最高分,
       a.多指标共振期数,
       concat_ws(' ',
           a.命中R1, a.命中R2, a.命中R3, a.命中R4, a.命中R5) AS 命中规则,
       a.最差报告期,
       CASE WHEN COALESCE(a.近期最高分, 0) >= 3 THEN '高风险'
            WHEN COALESCE(a.近期最高分, 0) = 2  THEN '关注'
            WHEN COALESCE(a.近期最高分, 0) = 1  THEN '轻微'
            ELSE '正常' END                            AS 风险分级
FROM agg a
JOIN dim_stock    st ON st.stock_code = a.stock_code
JOIN dim_industry i  ON i.industry_code = st.industry_code
ORDER BY COALESCE(a.近期最高分, 0) DESC, COALESCE(a.近期命中合计, 0) DESC;
