# -*- coding: utf-8 -*-
"""为应用生成精简书目索引 assets/catalog.json。

应用不需要完整 7MB 名录，只需要 file_id -> 元数据 的反查表。
输出紧凑结构，供 Dart 端一次性加载进内存：

{
  "generated_at": "...",
  "books": {
     "1375510375": {"t": "极度成功", "a": "丹尼尔・科伊尔", "c": "企业", "n": 3},
     ...
  }
}
其中 n = 该书目条目被重复收录的次数（>1 说明该书在名录里有多个书名/分类变体）。
另有 "aliases"：重复条目的别名列表（最多保留 3 个），用于搜索命中。
"""
import argparse
import collections
import datetime
import json
import os

FID_RE_NUM = None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", required=True, help="catalog.jsonl")
    ap.add_argument("--out", required=True, help="输出的 catalog.json")
    args = ap.parse_args()

    books = collections.OrderedDict()
    with open(args.catalog, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            fid = r.get("fid")
            if not fid:
                continue
            file_id = fid.split("-")[1]
            t = (r.get("t") or "").strip()
            a = (r.get("a") or "").strip()
            c = (r.get("c") or "").strip()
            if file_id not in books:
                books[file_id] = {"t": t, "a": a, "c": c, "n": 1, "x": []}
            else:
                b = books[file_id]
                b["n"] += 1
                if t and t != b["t"] and t not in b["x"] and len(b["x"]) < 3:
                    b["x"].append(t)

    payload = {
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "source": "jbiaojerry/ebook-treasure-chest all-books.json",
        "count": len(books),
        "books": books,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))

    size = os.path.getsize(args.out)
    cats = collections.Counter(v["c"] for v in books.values())
    print("books=%d size=%.2fMB categories=%d" % (len(books), size / 1048576.0, len(cats)))
    print("top cats:", dict(cats.most_common(8)))


if __name__ == "__main__":
    main()
