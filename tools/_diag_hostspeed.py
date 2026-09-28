# -*- coding: utf-8 -*-
"""对比 89-cucc-data 与 *-usw-data 两台主机的真实限速行为。
对指定文件各取前 2MB，报告状态码与速率。"""
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

# 城通: 1 本 cucc 主机的书 + 1 本 usw 主机的书，各测两次
TARGETS = ["1357039087", "1357031224", "1375510375", "1357044763"]

opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    urllib.request.ProxyHandler({}))
opener.addheaders = [("User-Agent", UA)]


def get(url, ref=None, rng=None, timeout=45):
    req = urllib.request.Request(url)
    if ref:
        req.add_header("Referer", ref)
    req.add_header("X-Requested-With", "XMLHttpRequest")
    if rng:
        req.add_header("Range", rng)
    return opener.open(req, timeout=timeout)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    man = os.path.abspath(os.path.join(here, "..", "data", "manifest.jsonl"))
    byid = {}
    with open(man, encoding="utf-8") as f:
        for line in f:
            p = json.loads(line)
            byid[p["file_id"]] = p

    out = []
    for fid in TARGETS:
        p = byid.get(fid)
        if not p:
            out.append("%s 不在清单里" % fid)
            continue
        page = p["url"]
        m = FID_RE.search(page)
        fpart = m.group(0)[3:]
        pc = urllib.parse.parse_qs(urllib.parse.urlparse(page).query).get("p", [""])[0]
        line = ["%s (%s)" % (p["zip_name"], p["file_id"])]
        try:
            get(page).read()
            u1 = ("%s/getfile.php?path=f&f=%s&passcode=%s&ref=&url=%s"
                  % (API, fpart, pc, urllib.parse.quote(page, safe="")))
            j1 = json.loads(get(u1, ref=page).read().decode("utf-8"))
            f = j1["file"]
            u2 = ("%s/get_file_url.php?uid=%s&fid=%s&folder_id=0&share_id="
                  "&file_chk=%s&start_time=%s&wait_seconds=0&mb=0&app=0&acheck=0"
                  "&verifycode=%s&rd=%s"
                  % (API, f["userid"], f["file_id"], f["file_chk"], f["start_time"],
                     f["verifycode"], int(time.time() * 1000)))
            j2 = json.loads(get(u2, ref=page).read().decode("utf-8"))
            down = j2["downurl"]
            size = int(j2["file_size"])
            host = urllib.parse.urlparse(down).netloc
            q = urllib.parse.parse_qs(urllib.parse.urlparse(down).query)
            thr = int(q.get("threshold", ["0"])[0])
            line.append("  host=%s size=%d threshold=%d" % (host, size, thr))

            for attempt in (1, 2):
                end = min(2 * 1024 * 1024 - 1, size - 1)
                t = time.time()
                try:
                    r = get(down, ref=page, rng="bytes=0-%d" % end, timeout=60)
                    data = r.read()
                    dt = time.time() - t
                    line.append("  尝试%d: status=%s got=%dB %.2fs -> %.0f KB/s"
                                % (attempt, getattr(r, "status", "?"), len(data), dt,
                                   len(data) / dt / 1024 if dt > 0 else 0))
                except urllib.error.HTTPError as e:
                    dt = time.time() - t
                    line.append("  尝试%d: HTTP%s (%.2fs)" % (attempt, e.code, dt))
                except Exception as e:
                    dt = time.time() - t
                    line.append("  尝试%d: ERR %r (%.2fs)" % (attempt, e, dt))
                time.sleep(1.0)
        except Exception as e:
            line.append("  握手 ERR %r" % e)
        out += line
        out.append("  ---")
        time.sleep(1.5)

    dest = os.path.join(os.environ["TEMP"], "hostspeed.txt")
    with open(dest, "w", encoding="utf-8", buffering=1) as fo:
        fo.write("\n".join(out) + "\n")
    print("\n".join(out))


if __name__ == "__main__":
    main()
