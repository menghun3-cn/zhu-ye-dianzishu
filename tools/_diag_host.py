# -*- coding: utf-8 -*-
"""抽样握手，统计媒体主机分配比例 —— 区分「坏主机绑定」与「IP 级配额」。"""
import collections
import http.cookiejar
import json
import os
import re
import time
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
API = "https://webapi.ctfile.com"
FID_RE = re.compile(r"/f/(\d+)-(\d+)-([0-9a-fA-F]+)")
N = 30

opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    urllib.request.ProxyHandler({}))
opener.addheaders = [("User-Agent", UA)]


def get(url, ref=None):
    req = urllib.request.Request(url)
    if ref:
        req.add_header("Referer", ref)
    req.add_header("X-Requested-With", "XMLHttpRequest")
    return opener.open(req, timeout=40)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    man = os.path.abspath(os.path.join(here, "..", "data", "manifest.jsonl"))
    packs = []
    with open(man, encoding="utf-8") as f:
        for i, line in enumerate(f):
            if i >= N:
                break
            packs.append(json.loads(line))

    hosts = collections.Counter()
    sizes = []
    out = []
    ok = 0
    for p in packs:
        page = p["url"]
        m = FID_RE.search(page)
        fpart = m.group(0)[3:]
        pc = urllib.parse.parse_qs(urllib.parse.urlparse(page).query).get("p", [""])[0]
        try:
            get(page).read()
            u1 = ("%s/getfile.php?path=f&f=%s&passcode=%s&ref=&url=%s"
                  % (API, fpart, pc, urllib.parse.quote(page, safe="")))
            j1 = json.loads(get(u1, ref=page).read().decode("utf-8"))
            f = j1.get("file") or {}
            u2 = ("%s/get_file_url.php?uid=%s&fid=%s&folder_id=0&share_id="
                  "&file_chk=%s&start_time=%s&wait_seconds=0&mb=0&app=0&acheck=0"
                  "&verifycode=%s&rd=%s"
                  % (API, f["userid"], f["file_id"], f["file_chk"], f["start_time"],
                     f["verifycode"], int(time.time() * 1000)))
            j2 = json.loads(get(u2, ref=page).read().decode("utf-8"))
            down = j2.get("downurl", "")
            host = urllib.parse.urlparse(down).netloc
            hosts[host] += 1
            sizes.append(int(j2.get("file_size") or 0))
            ok += 1
            out.append("  %s -> %s" % (p["zip_name"], host))
            # 立刻试下第一块，看这台主机到底快不快
            t = time.time()
            r = get(down, ref=page)
            req = urllib.request.Request(down)
        except Exception as e:
            out.append("  %s ERR %r" % (p["zip_name"], e))
        time.sleep(1.2)

    out.append("")
    out.append("成功握手 %d/%d" % (ok, N))
    out.append("主机分布: %s" % dict(hosts.most_common()))
    if sizes:
        out.append("平均大小: %.2f MB" % (sum(sizes) / len(sizes) / 1048576))
    dest = os.path.join(os.environ["TEMP"], "hostprobe.txt")
    with open(dest, "w", encoding="utf-8", buffering=1) as fo:
        fo.write("\n".join(out) + "\n")
    print("\n".join(out[-4:]))


if __name__ == "__main__":
    main()
