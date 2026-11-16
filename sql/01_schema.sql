-- ============================================================
-- 01_schema.sql  星型模型：2 张维度表 + 2 张事实表
-- 设计说明见 docs/DATA_DICT.md
-- ============================================================

DROP TABLE IF EXISTS fact_financial;
DROP TABLE IF EXISTS fact_daily_quote;
DROP TABLE IF EXISTS dim_stock;
DROP TABLE IF EXISTS dim_industry;

-- ---------- 维度表 ----------

-- 行业维度。industry_level 是自定义的大类归类（消费/金融/医药/科技/制造/周期/公用），
-- 用来做跨申万行业的横向比较——申万一级切太细，小行业只有 1-2 只样本。
CREATE TABLE dim_industry (
    industry_code   VARCHAR PRIMARY KEY,
    industry_name   VARCHAR NOT NULL,
    industry_level  VARCHAR NOT NULL
);

-- 股票维度。board 区分主板/创业板/科创板，因为涨跌停幅度不同（10% vs 20%），
-- 做异常涨跌幅校验时必须带上这个字段，否则会把创业板的正常波动误判为异常。
-- index_membership 记录所属指数（沪深300 / 中证500），用于对比大盘与中盘的表现差异。
CREATE TABLE dim_stock (
    stock_code       VARCHAR PRIMARY KEY,
    stock_name       VARCHAR NOT NULL,
    industry_code    VARCHAR NOT NULL REFERENCES dim_industry(industry_code),
    board            VARCHAR NOT NULL,
    index_membership VARCHAR NOT NULL,
    is_st            BOOLEAN NOT NULL
);

-- ---------- 事实表 ----------

-- 日行情。价格已做后复权，因此 close 不能与行情软件上的名义价格直接对比，
-- 但收益率、回撤、区间涨幅都是可比且正确的。
CREATE TABLE fact_daily_quote (
    stock_code      VARCHAR NOT NULL REFERENCES dim_stock(stock_code),
    trade_date      DATE    NOT NULL,
    open            DOUBLE,
    high            DOUBLE,
    low             DOUBLE,
    close           DOUBLE,
    volume          BIGINT,
    amount          DOUBLE,
    turnover_rate   DOUBLE,
    PRIMARY KEY (stock_code, trade_date)     -- 复合主键：一只股票一天只能有一条
);

-- 财务报表（比率口径）。report_date 是报告期末，不是公告日。
-- 财务数据是累计口径，因此同比必须与「去年同一报告期」对齐，不能跨期直接比。
CREATE TABLE fact_financial (
    stock_code      VARCHAR NOT NULL REFERENCES dim_stock(stock_code),
    report_date     DATE    NOT NULL,
    revenue_yoy     DOUBLE,   -- 营业收入同比增速 %
    profit_yoy      DOUBLE,   -- 净利润同比增速 %
    net_margin      DOUBLE,   -- 销售净利率 %
    gross_margin    DOUBLE,   -- 主营业务利润率 %
    roe             DOUBLE,   -- 净资产收益率 %
    roa             DOUBLE,   -- 总资产净利润率 %
    eps             DOUBLE,   -- 摊薄每股收益 元
    bps             DOUBLE,   -- 每股净资产 元
    ocf_ps          DOUBLE,   -- 每股经营性现金流 元
    ar_days         DOUBLE,   -- 应收账款周转天数
    inv_days        DOUBLE,   -- 存货周转天数
    PRIMARY KEY (stock_code, report_date)
);
