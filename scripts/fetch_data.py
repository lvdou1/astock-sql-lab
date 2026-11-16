"""
取数脚本：沪深300 成分股行情（后复权）+ 财务指标

数据源
------
成分股: 中证指数官网   ak.index_stock_cons_csindex("000300")
行业  : 申万行业官网   ak.index_first_info_sw / ak.index_component_sw（31 个一级行业）
行情  : 腾讯财经       ak.stock_zh_a_hist_tx(adjust="hfq")   后复权
财务  : 新浪财经       ak.stock_financial_analysis_indicator  比率口径

输出
----
data/dim_industry.csv          行业维度（31 个申万一级 + 7 大类）
data/dim_stock.csv             股票维度（中证800 成分，含所属指数）
data/fact_daily_quote.parquet  日行情事实表
data/fact_financial.parquet    财务事实表
data/raw/*.csv                 中间文件（已 gitignore）

注意
----
1. 财务是累计口径，同比必须与「去年同一报告期」对齐，不能跨期直接比。
2. 银行/非银的报表科目结构与制造业不同，应收账款周转、存货周转对其无意义，
   异常筛查查询会显式排除金融行业。
3. 东方财富接口有 IP 限流，故未使用；换用腾讯 + 新浪。

用法:  python scripts/fetch_data.py
"""

from __future__ import annotations

import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import akshare as ak
import duckdb
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
DATA = ROOT / "data"

# 中证800 = 沪深300（大盘）+ 中证500（中盘），覆盖 A 股约 70% 市值。
# 只取沪深300 的话，电子、医药以外的行业样本只有 3-5 只，行业排名没有统计意义。
INDEX_CODES = {"000300": "沪深300", "000905": "中证500"}
START_DATE = "20220101"
END_DATE = "20261116"
MAX_WORKERS = 6                # 6 并发实测约 1.4 秒/只，再高容易被限流
RETRIES = 3

# 申万一级 → 自定义大类。样本量大之后，按大类做横向比较才有统计意义。
LEVEL_MAP = {
    "农林牧渔": "消费", "食品饮料": "消费", "家用电器": "消费", "纺织服饰": "消费",
    "轻工制造": "消费", "商贸零售": "消费", "社会服务": "消费", "美容护理": "消费",
    "银行": "金融", "非银金融": "金融",
    "医药生物": "医药",
    "电子": "科技", "计算机": "科技", "通信": "科技", "传媒": "科技",
    "电力设备": "制造", "机械设备": "制造", "国防军工": "制造", "汽车": "制造",
    "建筑装饰": "制造",
    "有色金属": "周期", "钢铁": "周期", "基础化工": "周期", "煤炭": "周期",
    "石油石化": "周期", "建筑材料": "周期", "房地产": "周期", "综合": "周期",
    "公用事业": "公用", "交通运输": "公用", "环保": "公用",
}

QUOTE_COLS = {
    "stock_code": "VARCHAR", "trade_date": "DATE", "open": "DOUBLE", "high": "DOUBLE",
    "low": "DOUBLE", "close": "DOUBLE", "volume": "BIGINT", "amount": "DOUBLE",
    "turnover_rate": "DOUBLE",
}
FIN_COLS = {
    "stock_code": "VARCHAR", "report_date": "DATE", "revenue_yoy": "DOUBLE",
    "profit_yoy": "DOUBLE", "net_margin": "DOUBLE", "gross_margin": "DOUBLE",
    "roe": "DOUBLE", "roa": "DOUBLE", "eps": "DOUBLE", "bps": "DOUBLE",
    "ocf_ps": "DOUBLE", "ar_days": "DOUBLE", "inv_days": "DOUBLE",
}


def tx_symbol(code: str) -> str:
    """6 位代码 → 腾讯格式。6 开头沪市，其余深市。"""
    return ("sh" if code.startswith("6") else "sz") + code


def board_of(code: str) -> str:
    if code.startswith("688"):
        return "科创板"
    if code.startswith("300") or code.startswith("301"):
        return "创业板"
    return "主板"


def build_universe() -> tuple[pd.DataFrame, pd.DataFrame]:
    """沪深300 成分 + 申万一级行业映射。"""
    frames_idx = []
    for icode, iname in INDEX_CODES.items():
        df = ak.index_stock_cons_csindex(symbol=icode)
        df = df[["成分券代码", "成分券名称"]].rename(
            columns={"成分券代码": "stock_code", "成分券名称": "stock_name"})
        df["stock_code"] = df["stock_code"].astype(str).str.zfill(6)
        df["index_membership"] = iname
        frames_idx.append(df)
        print(f"  {iname} 成分: {len(df)} 只")
        time.sleep(0.3)
    cons = (pd.concat(frames_idx, ignore_index=True)
              .drop_duplicates("stock_code")      # 两个指数不重叠，去重只是保险
              .sort_values(["index_membership", "stock_code"]))

    info = ak.index_first_info_sw()
    frames = []
    for i, (icode, iname) in enumerate(zip(info["行业代码"], info["行业名称"]), 1):
        try:
            c = ak.index_component_sw(symbol=str(icode).split(".")[0])
            c = c[["证券代码", "证券名称"]].rename(
                columns={"证券代码": "stock_code", "证券名称": "sname"})
            c["stock_code"] = c["stock_code"].astype(str).str.zfill(6)
            c["industry_code"] = str(icode).split(".")[0]
            c["industry_name"] = iname
            frames.append(c)
        except Exception as e:
            print(f"  [{i:2}/31] {iname} 取成分失败: {type(e).__name__}")
        print(f"  申万行业 {i:2}/31 {iname}", end="\r")
        time.sleep(0.1)
    print()

    sw = pd.concat(frames, ignore_index=True).drop_duplicates("stock_code")
    m = cons.merge(sw[["stock_code", "industry_code", "industry_name"]],
                   on="stock_code", how="left")
    unmatched = m[m["industry_name"].isna()]
    if len(unmatched):
        print(f"  警告: {len(unmatched)} 只未匹配到申万行业: {unmatched['stock_name'].tolist()[:8]}")
        m = m.dropna(subset=["industry_name"])

    dim_industry = (m[["industry_code", "industry_name"]]
                    .drop_duplicates()
                    .assign(industry_level=lambda d: d["industry_name"].map(LEVEL_MAP).fillna("其他"))
                    .sort_values("industry_code"))
    dim_stock = (m[["stock_code", "stock_name", "industry_code", "index_membership"]]
                 .assign(board=lambda d: d["stock_code"].map(board_of),
                         is_st=lambda d: d["stock_name"].str.replace("*", "", regex=False)
                                          .str.contains("ST").astype(int))
                 .drop_duplicates("stock_code")
                 .sort_values("stock_code"))
    return dim_industry, dim_stock


def fetch_one(code: str) -> tuple[pd.DataFrame | None, pd.DataFrame | None]:
    """取单只股票的行情与财务。失败重试，最终仍失败则返回 None。"""
    quote = fin = None
    for attempt in range(RETRIES):
        try:
            if quote is None:
                df = ak.stock_zh_a_hist_tx(symbol=tx_symbol(code), start_date=START_DATE,
                                           end_date=END_DATE, adjust="hfq")
                df = df.rename(columns={"date": "trade_date", "turnover": "turnover_rate"})
                df["stock_code"] = code
                df["turnover_rate"] = (pd.to_numeric(df["turnover_rate"], errors="coerce") * 100).round(4)
                quote = df[["stock_code", "trade_date", "open", "high", "low", "close",
                            "volume", "amount", "turnover_rate"]]
            if fin is None:
                df = ak.stock_financial_analysis_indicator(symbol=code, start_year="2022")
                colmap = {
                    "日期": "report_date",
                    "主营业务收入增长率(%)": "revenue_yoy",
                    "净利润增长率(%)": "profit_yoy",
                    "销售净利率(%)": "net_margin",
                    "主营业务利润率(%)": "gross_margin",
                    "净资产收益率(%)": "roe",
                    "总资产净利润率(%)": "roa",
                    "摊薄每股收益(元)": "eps",
                    "每股净资产_调整后(元)": "bps",
                    "每股经营性现金流(元)": "ocf_ps",
                    "应收账款周转天数(天)": "ar_days",
                    "存货周转天数(天)": "inv_days",
                }
                out = df[list(colmap)].rename(columns=colmap)
                out["stock_code"] = code
                for c in out.columns:
                    if c not in ("stock_code", "report_date"):
                        out[c] = pd.to_numeric(out[c], errors="coerce")
                out["report_date"] = pd.to_datetime(out["report_date"], errors="coerce").dt.strftime("%Y-%m-%d")
                fin = (out.dropna(subset=["report_date"])
                       .drop_duplicates(["stock_code", "report_date"])
                       [list(FIN_COLS)])          # 固定列顺序，与 parquet schema 一致
            if quote is not None and fin is not None:
                return quote, fin
        except Exception:
            pass
        time.sleep(1.5 * (attempt + 1))
    return quote, fin


def to_parquet(csv_path: Path, pq_path: Path, columns: dict[str, str]) -> None:
    """CSV → Parquet。用 duckdb 转，不需要额外的 pyarrow 依赖。

    注意: read_csv 的 columns 参数是按「位置」匹配的，一旦 CSV 列顺序变了就会错位，
    所以这里先 all_varchar 全读成文本，再按列名显式 CAST —— 与列顺序无关。
    """
    casts = ", ".join(f'"{k}"::{v} AS "{k}"' for k, v in columns.items())
    con = duckdb.connect()
    con.execute(f"""
        COPY (
            SELECT {casts}
            FROM read_csv('{csv_path.as_posix()}', header=true, all_varchar=true)
        ) TO '{pq_path.as_posix()}' (FORMAT PARQUET, COMPRESSION ZSTD)
    """)
    con.close()


def main() -> None:
    DATA.mkdir(parents=True, exist_ok=True)
    RAW.mkdir(parents=True, exist_ok=True)

    dim_industry, dim_stock = build_universe()
    dim_industry.to_csv(DATA / "dim_industry.csv", index=False, encoding="utf-8-sig")
    dim_stock.to_csv(DATA / "dim_stock.csv", index=False, encoding="utf-8-sig")
    print(f"维度表: {len(dim_stock)} 只股票, {len(dim_industry)} 个申万一级行业")
    print(dim_stock["index_membership"].value_counts().to_string(), "\n")

    codes = dim_stock["stock_code"].tolist()
    quotes, fins, failed = [], [], []
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        futures = {ex.submit(fetch_one, c): c for c in codes}
        for i, fut in enumerate(as_completed(futures), 1):
            code = futures[fut]
            q, f = fut.result()
            if q is not None:
                quotes.append(q)
            if f is not None:
                fins.append(f)
            if q is None or f is None:
                failed.append(code)
            el = time.time() - t0
            eta = el / i * (len(codes) - i)
            print(f"  {i:3}/{len(codes)}  成功 {len(quotes):3}  失败 {len(failed):2}  "
                  f"已用 {el:5.0f}s  ETA {eta:4.0f}s", end="\r")
    print()

    q_all = pd.concat(quotes, ignore_index=True).sort_values(["stock_code", "trade_date"])
    f_all = pd.concat(fins, ignore_index=True).sort_values(["stock_code", "report_date"])
    q_all.to_csv(RAW / "fact_daily_quote.csv", index=False, encoding="utf-8-sig")
    f_all.to_csv(RAW / "fact_financial.csv", index=False, encoding="utf-8-sig")

    to_parquet(RAW / "fact_daily_quote.csv", DATA / "fact_daily_quote.parquet", QUOTE_COLS)
    to_parquet(RAW / "fact_financial.csv", DATA / "fact_financial.parquet", FIN_COLS)

    print(f"\n完成: 行情 {len(q_all):,} 行 ({q_all['stock_code'].nunique()} 只), "
          f"财务 {len(f_all):,} 行 ({f_all['stock_code'].nunique()} 只)")
    if failed:
        print(f"失败 {len(failed)} 只: {failed}")
    for p in ["dim_industry.csv", "dim_stock.csv",
              "fact_daily_quote.parquet", "fact_financial.parquet"]:
        size = (DATA / p).stat().st_size / 1024 / 1024
        print(f"  {p:<28} {size:6.2f} MB")


if __name__ == "__main__":
    main()
