# -*- coding: utf-8 -*-
"""挖出 get_file_url.php 的完整响应，找有没有可选下载线路。
另外试探 get_down_url.php 备用接口。"""
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

opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    urllib.request.ProxyHandler({}))
opener.addheaders = [("User-Agent", UA)]


def get(url, ref=None):
    req = urllib.request.Request(url)
    if ref:
        req.add_header("Referer", ref)
    req.add_header("X-Requested-With", "XMLHttpRequest")
    return opener.open(req, timeout=60)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    man = os.path.abspath(os.path.join(here, "..", "data", "manifest.jsonl"))
    packs = []
    with open(man, encoding="utf-8") as f:
        for i, line in enumerate(f):
            if i >= 6:
                break
            packs.append(json.loads(line))

    out = []
    for p in packs:
        page = p["url"]
        m = FID_RE.search(page)
        fpart = m.group(0)[3:]
        pc = urllib.parse.parse_qs(urllib.parse.urlparse(page).query).get("p", [""])[0]
        out.append("=" * 70)
        out.append("FILE %s" % p["zip_name"])
        try:
            get(page).read()
            u1 = ("%s/getfile.php?path=f&f=%s&passcode=%s&ref=&url=%s"
                  % (API, fpart, pc, urllib.parse.quote(page, safe="")))
            j1 = json.loads(get(u1, ref=page).read().decode("utf-8"))
            out.append("  getfile.php 完整响应:")
            out.append("  " + json.dumps(j1, ensure_ascii=False)[:1600])

            f = j1.get("file") or {}
            u2 = ("%s/get_file_url.php?uid=%s&fid=%s&folder_id=0&share_id="
                  "&file_chk=%s&start_time=%s&wait_seconds=0&mb=0&app=0&acheck=0"
                  "&verifycode=%s&rd=%s"
                  % (API, f.get("userid"), f.get("file_id"), f.get("file_chk"),
                     f.get("start_time"), f.get("verifycode"), int(time.time() * 1000)))
            j2 = json.loads(get(u2, ref=page).read().decode("utf-8"))
            out.append("  get_file_url.php 完整响应:")
            out.append("  " + json.dumps(j2, ensure_ascii=False)[:1600])
            if j2.get("downurl"):
                out.append("  downurl 主机: " + urllib.parse.urlparse(j2["downurl"]).netloc)

            # 备用接口
            try:
                u3 = ("%s/get_down_url.php?uid=%s&fid=%s&file_chk=%s&start_time=%s"
                      "&wait_seconds=0&rd=%s"
                      % (API, f.get("userid"), f.get("file_id"), f.get("file_chk"),
                         f.get("start_time"), int(time.time() * 1000)))
                r3 = get(u3, ref=page).read()
                out.append("  get_down_url.php: " + (r3.decode("utf-8", "replace")[:600] if r3 else "(空)"))
            except Exception as e:
                out.append("  get_down_url.php ERR %r" % e)
        except Exception as e:
            out.append("  ERR %r" % e)
        time.sleep(0.8)

    dest = os.path.join(os.environ["TEMP"], "api-dump.txt")
    with open(dest, "w", encoding="utf-8", buffering=1) as fo:
        fo.write("\n".join(out) + "\n")
    print("written", dest)


if __name__ == "__main__":
    main()
