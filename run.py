"""
一键跑通：建库 → 装载 → 建索引 → 依次执行 sql/queries/*.sql

用法:
    python run.py              # 全流程
    python run.py -q 3         # 只跑第 3 个查询
    python run.py --keep       # 复用已有数据库，不重新装载
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
import time
import unicodedata
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "astock.duckdb"
SQL_DIR = ROOT / "sql"
QUERY_DIR = SQL_DIR / "queries"
OUT_DIR = ROOT / "output"


def disp_width(s: str) -> int:
    """中文占两个字符宽，否则表格对不齐。"""
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def pad(s: str, width: int, right: bool = False) -> str:
    fill = " " * max(0, width - disp_width(s))
    return fill + s if right else s + fill


def print_table(cols: list[str], rows: list[tuple], max_rows: int = 15) -> None:
    if not rows:
        print("  (无结果)")
        return

    shown = rows[:max_rows]
    cells = [[("NULL" if v is None else str(v)) for v in r] for r in shown]
    widths = [disp_width(c) for c in cols]
    for r in cells:
        for i, v in enumerate(r):
            widths[i] = max(widths[i], disp_width(v))

    line = "  " + "  ".join(pad(c, widths[i]) for i, c in enumerate(cols))
    print(line)
    print("  " + "  ".join("-" * w for w in widths))
    for r in cells:
        # 数字右对齐，文本左对齐
        print("  " + "  ".join(
            pad(v, widths[i], right=bool(re.fullmatch(r"-?[\d.,%]+", v)))
            for i, v in enumerate(r)
        ))
    if len(rows) > max_rows:
        print(f"  ... 共 {len(rows)} 行，仅显示前 {max_rows} 行（完整结果见 output/）")


def read_caption(sql: str) -> str:
    """把文件开头的注释块当作说明打出来。"""
    lines = []
    for raw in sql.splitlines():
        s = raw.strip()
        if not s:
            if lines:
                break
            continue
        if s.startswith("--"):
            t = s.lstrip("-").strip()
            if t and not set(t) <= {"="}:
                lines.append(t)
        else:
            break
    return "\n".join("  " + l for l in lines)


def strip_comments(sql: str) -> str:
    """去掉整行注释，避免分号切分时把注释块当成语句的一部分。"""
    return "\n".join(l for l in sql.splitlines() if not l.strip().startswith("--"))


def run_file(con: duckdb.DuckDBPyConnection, path: Path) -> None:
    sql = strip_comments(path.read_text(encoding="utf-8"))
    for stmt in (s.strip() for s in sql.split(";")):
        if stmt:
            con.execute(stmt)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-q", "--query", type=int, default=None, help="只跑第 N 个查询")
    ap.add_argument("--keep", action="store_true", help="复用已有数据库")
    args = ap.parse_args()

    t0 = time.time()
    DB.parent.mkdir(parents=True, exist_ok=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    if not args.keep and DB.exists():
        DB.unlink()

    con = duckdb.connect(str(DB))

    if not args.keep:
        print("=== 建库 ===")
        for f in ["01_schema.sql", "02_load.sql", "03_index.sql"]:
            t = time.time()
            run_file(con, SQL_DIR / f)
            print(f"  {f:<16} {time.time() - t:5.2f}s")

        counts = con.execute("""
            SELECT 'dim_stock' AS t, COUNT(*) FROM dim_stock
            UNION ALL SELECT 'dim_industry', COUNT(*) FROM dim_industry
            UNION ALL SELECT 'fact_daily_quote', COUNT(*) FROM fact_daily_quote
            UNION ALL SELECT 'fact_financial', COUNT(*) FROM fact_financial
        """).fetchall()
        print("\n  表行数: " + "  ".join(f"{n}={c:,}" for n, c in counts))
        print(f"  数据库: {DB.relative_to(ROOT)}  (总耗时 {time.time() - t0:.1f}s)\n")

    files = sorted(QUERY_DIR.glob("*.sql"))
    if args.query is not None:
        files = [f for f in files if f.name.startswith(f"{args.query:02d}")]

    for path in files:
        print("=" * 78)
        print(f"  {path.name}")
        print("=" * 78)
        sql = path.read_text(encoding="utf-8")
        print(read_caption(sql))
        print()

        t = time.time()
        try:
            cur = con.execute(sql)
            cols = [d[0] for d in cur.description]
            rows = cur.fetchall()
        except Exception as e:
            print(f"  执行失败: {type(e).__name__}: {e}\n")
            continue
        elapsed = time.time() - t

        print_table(cols, rows)

        out = OUT_DIR / f"{path.stem}.csv"
        with out.open("w", newline="", encoding="utf-8-sig") as fh:
            w = csv.writer(fh)
            w.writerow(cols)
            w.writerows(rows)
        print(f"\n  {len(rows)} 行 | {elapsed * 1000:.0f} ms | 已存 {out.relative_to(ROOT)}\n")

    con.close()
    print(f"全部完成，总耗时 {time.time() - t0:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
