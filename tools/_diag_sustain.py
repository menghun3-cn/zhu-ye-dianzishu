# -*- coding: utf-8 -*-
"""持续吞吐实验：一条快线路(usw) + 一条慢线路(cucc) 同时拉，看各自能撑多久、是否互相影响。

用法: python tools/_diag_sustain.py <usw_file_id> <cucc_file_id> [每路拉多少MB]
输出每秒速率，用于判断：
  * 快线路是否能长时间维持 500KB/s（=> 多 worker 跨主机并行就是正解）
  * 慢线路的 30KB/s 是否与快线路互不干扰（=> 可以同时薅）
"""
import http.cookiejar
import json
import os
import re
import sys
import threading
import time
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
API = "https://webapi.ctfile.com"
FID_RE = re.compile(r"/f/(\d+)-(\d+)-([0-9a-fA-F]+)")

WANT_MB = int(sys.argv[3]) if len(sys.argv) > 3 else 20
SLOW_MB = int(sys.argv[4]) if len(sys.argv) > 4 else 4

opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    urllib.request.ProxyHandler({}))
opener.addheaders = [("User-Agent", UA)]


def get(url, ref=None, rng=None, timeout=120):
    req = urllib.request.Request(url)
    if ref:
        req.add_header("Referer", ref)
    req.add_header("X-Requested-With", "XMLHttpRequest")
    if rng:
        req.add_header("Range", rng)
    return opener.open(req, timeout=timeout)


def handshake(p):
    page = p["url"]
    m = FID_RE.search(page)
    fpart = m.group(0)[3:]
    pc = urllib.parse.parse_qs(urllib.parse.urlparse(page).query).get("p", [""])[0]
    get(page).read()
    u1 = ("%s/getfile.php?path=f&f=%s&passcode=%s&ref=&url=%s"
          % (API, fpart, pc, urllib.parse.quote(page, safe="")))
    f = json.loads(get(u1, ref=page).read().decode("utf-8"))["file"]
    u2 = ("%s/get_file_url.php?uid=%s&fid=%s&folder_id=0&share_id="
          "&file_chk=%s&start_time=%s&wait_seconds=0&mb=0&app=0&acheck=0"
          "&verifycode=%s&rd=%s"
          % (API, f["userid"], f["file_id"], f["file_chk"], f["start_time"],
             f["verifycode"], int(time.time() * 1000)))
    j2 = json.loads(get(u2, ref=page).read().decode("utf-8"))
    return j2["downurl"], int(j2["file_size"]), page


class Stream(threading.Thread):
    def __init__(self, tag, down, size, page, want):
        super().__init__(daemon=True)
        self.tag, self.down, self.size, self.page = tag, down, size, page
        self.want = min(want, size)
        self.samples = []      # (elapsed, cumulative_bytes)
        self.err = None
        self.barrier = None

    def run(self):
        if self.barrier:
            self.barrier.wait()
        t0 = time.time()
        got = 0
        try:
            r = get(self.down, ref=self.page, rng="bytes=0-%d" % (self.want - 1))
            last = 0.0
            while True:
                b = r.read(65536)
                if not b:
                    break
                got += len(b)
                el = time.time() - t0
                if el - last >= 5.0:
                    last = el
                    self.samples.append((round(el, 1), got))
                if got >= self.want:
                    break
        except Exception as e:                # noqa: BLE001
            self.err = repr(e)
        el = time.time() - t0
        self.samples.append((round(el, 1), got))


def main():
    if len(sys.argv) < 3:
        print("用法: _diag_sustain.py <fid_fast> <fid_slow> [MB]")
        return
    here = os.path.dirname(os.path.abspath(__file__))
    man = os.path.abspath(os.path.join(here, "..", "data", "manifest.jsonl"))
    byid = {}
    with open(man, encoding="utf-8") as f:
        for line in f:
            p = json.loads(line)
            byid[p["file_id"]] = p
    out = []
    streams = []
    for tag, fid in (("fast", sys.argv[1]), ("slow", sys.argv[2])):
        p = byid.get(fid)
        if not p:
            out.append("%s: fid %s 不在清单" % (tag, fid))
            continue
        down, size, page = handshake(p)
        host = urllib.parse.urlparse(down).netloc
        want = (WANT_MB if tag == "fast" else SLOW_MB) * 1024 * 1024
        out.append("%-5s %-16s %-34s size=%d want=%.0fMB"
                   % (tag, p["zip_name"], host, size, want / 1048576))
        streams.append(Stream(tag, down, size, page, want))

    bar = threading.Barrier(len(streams))
    for s in streams:
        s.barrier = bar
        s.start()
    for s in streams:
        s.join()

    out.append("")
    for s in streams:
        if not s.samples:
            out.append("%s: 无样本 %s" % (s.tag, s.err or ""))
            continue
        total_t, total_b = s.samples[-1]
        out.append("=== %s  共 %d B / %.1fs = %.0f KB/s   %s"
                   % (s.tag, total_b, total_t, total_b / total_t / 1024,
                      s.err or ""))
        prev_t, prev_b = 0.0, 0
        for (t, b) in s.samples:
            dt = t - prev_t
            if dt > 0:
                out.append("     t=%6.1fs  +%7dB  %6.0f KB/s"
                           % (t, b - prev_b, (b - prev_b) / dt / 1024))
            prev_t, prev_b = t, b

    txt = "\n".join(out)
    with open(os.path.join(os.environ["TEMP"], "sustain.txt"), "w",
              encoding="utf-8") as fo:
        fo.write(txt + "\n")
    print(txt)


if __name__ == "__main__":
    main()
