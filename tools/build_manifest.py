# -*- coding: utf-8 -*-
"""从名录 all-books.json 生成下载清单。

产出（写入 --out 目录）：
  catalog.jsonl       24,071 条书目条目（含 fid 反向引用）—— 供应用端检索/书架显示
  manifest.jsonl      11,348 个书包（按 fid 去重）—— 下载器的工作清单
  manifest.meta.json  统计摘要

用法：
  python build_manifest.py --out data
"""
import argparse
import collections
import datetime
import json
import os
import re
import urllib.request

SRC = "https://jbiaojerry.github.io/ebook-treasure-chest/all-books.json"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

# /f/<userid>-<file_id>-<file_chk>
FID_RE = re.compile(r"/f/(\d+)-(\d+)-([0-9a-fA-F]+)")


def fetch(url, timeout=180):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data")
    ap.add_argument("--src", default=SRC)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)

    print("fetching catalog ...")
    raw = fetch(args.src)
    items = json.loads(raw.decode("utf-8"))
    print("  entries: %d  (%.2f MB)" % (len(items), len(raw) / 1048576.0))

    catalog = []
    packs = collections.OrderedDict()
    no_link = 0
    bad_link = 0
    userids = collections.Counter()

    for idx, it in enumerate(items):
        title = (it.get("title") or "").strip()
        author = (it.get("author") or "").strip()
        link = (it.get("link") or "").strip()
        category = (it.get("category") or "").strip()
        language = (it.get("language") or "").strip()
        level = (it.get("level") or "").strip()
        formats = it.get("formats") or []

        if not link:
            no_link += 1
            fid = None
            userid = file_id = chk = None
        else:
            m = FID_RE.search(link)
            if not m:
                bad_link += 1
                fid = None
                userid = file_id = chk = None
            else:
                userid, file_id, chk = m.group(1), m.group(2), m.group(3)
                fid = "%s-%s-%s" % (userid, file_id, chk)
                userids[userid] += 1

        catalog.append({
            "i": idx,
            "t": title,
            "a": author,
            "c": category,
            "lang": language,
            "lv": level,
            "fmt": formats,
            "fid": fid,
        })

        if fid and fid not in packs:
            packs[fid] = {
                "fid": fid,
                "userid": userid,
                "file_id": file_id,
                "chk": chk,
                "url": link,
                "names": [title],
                "cats": [category],
            }
        elif fid:
            packs[fid]["names"].append(title)
            if category not in packs[fid]["cats"]:
                packs[fid]["cats"].append(category)

    p_catalog = os.path.join(args.out, "catalog.jsonl")
    with open(p_catalog, "w", encoding="utf-8", newline="\n") as f:
        for row in catalog:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    p_manifest = os.path.join(args.out, "manifest.jsonl")
    with open(p_manifest, "w", encoding="utf-8", newline="\n") as f:
        for fid, pk in packs.items():
            pk["zip_name"] = "%s.zip" % pk["file_id"]
            f.write(json.dumps(pk, ensure_ascii=False) + "\n")

    meta = {
        "generated_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "source": args.src,
        "source_bytes": len(raw),
        "entries_total": len(items),
        "entries_without_link": no_link,
        "entries_bad_link": bad_link,
        "packs_unique": len(packs),
        "duplicate_entries": len(items) - len(packs),
        "userids": dict(userids),
        "categories": len({c["c"] for c in catalog}),
    }
    with open(os.path.join(args.out, "manifest.meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

    print("catalog  -> %s (%d rows)" % (p_catalog, len(catalog)))
    print("manifest -> %s (%d rows)" % (p_manifest, len(packs)))
    print("no_link=%d bad_link=%d" % (no_link, bad_link))
    print("userids=%s" % dict(userids))
    print(json.dumps(meta, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
