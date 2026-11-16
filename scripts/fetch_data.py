"""
取数脚本：A股行情（后复权）+ 财务指标 → data/raw/*.csv

数据源
------
行情: 腾讯财经  ak.stock_zh_a_hist_tx(adjust="hfq")   后复权，避免分红除权造成假下跌
财务: 新浪财经  ak.stock_financial_analysis_indicator   比率型指标，含同比增速与周转天数

注意
----
1. 财务数据是「累计口径」(Q1 是 1-3 月累计, Q3 是 1-9 月累计)，不能直接算环比。
   本项目统一做「同报告期同比」(2025Q3 vs 2024Q3)，这一点在 README 里单独说明。
2. 银行/非银的报表科目结构与制造业不同，应收账款周转、存货周转对其无意义，
   因此异常筛查查询会显式排除金融行业。
3. 东方财富接口有 IP 限流，故未使用。

用法:  python scripts/fetch_data.py
"""

from __future__ import annotations

import time
from pathlib import Path

import akshare as ak
import pandas as pd

# 股票池：5 个行业，覆盖不同报表特征。
# 行业按申万一级手工归类（银行股保留在池内，用于演示「口径不同需排除」）。
UNIVERSE = [
    # 食品饮料
    ("600519", "贵州茅台", "食品饮料", "主板"),
    ("000858", "五粮液", "食品饮料", "主板"),
    ("600887", "伊利股份", "食品饮料", "主板"),
    ("603288", "海天味业", "食品饮料", "主板"),
    # 银行
    ("600036", "招商银行", "银行", "主板"),
    ("601398", "工商银行", "银行", "主板"),
    ("000001", "平安银行", "银行", "主板"),
    ("601166", "兴业银行", "银行", "主板"),
    # 医药生物
    ("600276", "恒瑞医药", "医药生物", "主板"),
    ("300760", "迈瑞医疗", "医药生物", "创业板"),
    ("000538", "云南白药", "医药生物", "主板"),
    ("600196", "复星医药", "医药生物", "主板"),
    # 电子/电力设备
    ("002415", "海康威视", "电子", "主板"),
    ("000725", "京东方A", "电子", "主板"),
    ("300750", "宁德时代", "电力设备", "创业板"),
    ("002230", "科大讯飞", "计算机", "主板"),
    # 机械设备/家电
    ("600031", "三一重工", "机械设备", "主板"),
    ("000333", "美的集团", "家用电器", "主板"),
    ("000651", "格力电器", "家用电器", "主板"),
    ("601899", "紫金矿业", "有色金属", "主板"),
    # 风险案例（历史上存在财务争议，用于验证异常规则能否识别）
    ("600518", "ST康美", "医药生物", "主板"),
    ("600585", "海螺水泥", "建筑材料", "主板"),
]

INDUSTRY_LEVEL = {"食品饮料": "消费", "家用电器": "消费", "银行": "金融",
                  "医药生物": "医药", "电子": "科技", "计算机": "科技",
                  "电力设备": "制造", "机械设备": "制造", "有色金属": "周期",
                  "建筑材料": "周期"}

START_DATE = "20220101"
END_DATE = "20261116"
RAW = Path(__file__).resolve().parent.parent / "data" / "raw"


def tx_symbol(code: str) -> str:
    """6 位代码 → 腾讯格式。6 开头沪市，其余深市。"""
    return ("sh" if code.startswith("6") else "sz") + code


def fetch_quotes(code: str) -> pd.DataFrame:
    """后复权日线。返回 stock_code/trade_date/open/high/low/close/volume/amount/turnover"""
    df = ak.stock_zh_a_hist_tx(
        symbol=tx_symbol(code), start_date=START_DATE, end_date=END_DATE, adjust="hfq"
    )
    df = df.rename(columns={"date": "trade_date", "turnover": "turnover_rate"})
    df["stock_code"] = str(code).zfill(6)
    # turnover 是小数比例，转成百分数，与行情软件口径一致
    df["turnover_rate"] = (pd.to_numeric(df["turnover_rate"], errors="coerce") * 100).round(4)
    keep = ["stock_code", "trade_date", "open", "high", "low", "close",
            "volume", "amount", "turnover_rate"]
    return df[keep]


def fetch_financial(code: str) -> pd.DataFrame:
    """财务指标。只保留异常筛查用得上的字段。"""
    df = ak.stock_financial_analysis_indicator(symbol=code, start_year="2022")

    colmap = {
        "日期": "report_date",
        "主营业务收入增长率(%)": "revenue_yoy",
        "净利润增长率(%)": "profit_yoy",
        "销售净利率(%)": "net_margin",
        "主营业务利润率(%)": "gross_margin",
        "净资产收益率(%)": "roe",
        "摊薄每股收益(元)": "eps",
        "每股经营性现金流(元)": "ocf_ps",
        "每股净资产_调整后(元)": "bps",
        "应收账款周转天数(天)": "ar_days",
        "存货周转天数(天)": "inv_days",
        "总资产净利润率(%)": "roa",
    }
    missing = [c for c in colmap if c not in df.columns]
    if missing:
        raise KeyError(f"{code} 缺少列: {missing}")

    out = df[list(colmap)].rename(columns=colmap)
    out["stock_code"] = str(code).zfill(6)
    for c in out.columns:
        if c not in ("stock_code", "report_date"):
            out[c] = pd.to_numeric(out[c], errors="coerce")
    out["report_date"] = pd.to_datetime(out["report_date"], errors="coerce").dt.strftime("%Y-%m-%d")
    out = out.dropna(subset=["report_date"])
    # 财务数据偶有重复期间，保留第一次
    out = out.drop_duplicates(subset=["stock_code", "report_date"], keep="first")
    return out[["stock_code", "report_date", "revenue_yoy", "profit_yoy", "net_margin",
                "gross_margin", "roe", "roa", "eps", "bps", "ocf_ps", "ar_days", "inv_days"]]


def main() -> None:
    RAW.mkdir(parents=True, exist_ok=True)

    dim_industry = pd.DataFrame(
        [{"industry_name": k, "industry_level": v} for k, v in INDUSTRY_LEVEL.items()]
    ).sort_values("industry_name")
    dim_industry.insert(0, "industry_code", [f"SW{i:02d}" for i in range(1, len(dim_industry) + 1)])

    dim_stock = pd.DataFrame(UNIVERSE, columns=["stock_code", "stock_name", "industry_name", "board"])
    dim_stock = dim_stock.merge(dim_industry[["industry_code", "industry_name"]], on="industry_name")
    dim_stock["is_st"] = dim_stock["stock_name"].str.contains("ST").astype(int)
    dim_stock.to_csv(RAW / "dim_stock.csv", index=False, encoding="utf-8-sig")
    dim_industry.to_csv(RAW / "dim_industry.csv", index=False, encoding="utf-8-sig")
    print(f"维度表: {len(dim_stock)} 只股票, {len(dim_industry)} 个行业")

    quotes, fins = [], []
    for i, (code, name, *_rest) in enumerate(UNIVERSE, 1):
        try:
            q = fetch_quotes(code)
            quotes.append(q)
            print(f"  [{i:2}/{len(UNIVERSE)}] {code} {name:6} 行情 {len(q):5} 行", end="")
        except Exception as e:
            print(f"  [{i:2}/{len(UNIVERSE)}] {code} {name:6} 行情失败: {type(e).__name__} {str(e)[:60]}")
            continue
        try:
            f = fetch_financial(code)
            fins.append(f)
            print(f" | 财务 {len(f):3} 期")
        except Exception as e:
            print(f" | 财务失败: {type(e).__name__} {str(e)[:60]}")
        time.sleep(1.0)  # 对数据源保持礼貌，也避免触发限流

    pd.concat(quotes, ignore_index=True).to_csv(
        RAW / "fact_daily_quote.csv", index=False, encoding="utf-8-sig")
    pd.concat(fins, ignore_index=True).to_csv(
        RAW / "fact_financial.csv", index=False, encoding="utf-8-sig")

    print(f"\n完成: 行情 {sum(len(q) for q in quotes)} 行, 财务 {sum(len(f) for f in fins)} 行")
    print(f"输出目录: {RAW}")


if __name__ == "__main__":
    main()
