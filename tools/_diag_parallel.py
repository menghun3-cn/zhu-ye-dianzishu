# -*- coding: utf-8 -*-
"""限速模型探针：限速到底是「IP 级」还是「连接/主机级」？

做法：同时握手 N 个不同书包，拿到 N 个（可能不同主机的）downurl，
在同一个时刻用 N 条线程各拉 1MB，测每条的速率与**总吞吐**。

判读：
  * 总吞吐 ≈ 单条速率          -> IP 级限速，加线程没用（别折腾）
  * 总吞吐 ≈ 单条速率 × N      -> 连接/主机级限速，多线程能成倍提速
  * 居中                       -> 部分共享，适度并行有收益
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

N = int(sys.argv[2]) if len(sys.argv) > 2 else 4
CHUNK = 1024 * 1024            # 每条拉 1MB

opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    urllib.request.ProxyHandler({}))
opener.addheaders = [("User-Agent", UA)]


def get(url, ref=None, rng=None, timeout=90):
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
    j1 = json.loads(get(u1, ref=page).read().decode("utf-8"))
    f = j1["file"]
    u2 = ("%s/get_file_url.php?uid=%s&fid=%s&folder_id=0&share_id="
          "&file_chk=%s&start_time=%s&wait_seconds=0&mb=0&app=0&acheck=0"
          "&verifycode=%s&rd=%s"
          % (API, f["userid"], f["file_id"], f["file_chk"], f["start_time"],
             f["verifycode"], int(time.time() * 1000)))
    j2 = json.loads(get(u2, ref=page).read().decode("utf-8"))
    return j2["downurl"], int(j2["file_size"]), page


class Solo:
    """单条对照：串行拉 1MB 的速率"""
    def __init__(self, down, size, page, off):
        self.down, self.size, self.page, self.off = down, size, page, off
        self.got, self.secs, self.err = 0, 0.0, None

    def run(self):
        end = min(self.off + CHUNK - 1, self.size - 1)
        t = time.time()
        try:
            r = get(self.down, ref=self.page, rng="bytes=%d-%d" % (self.off, end))
            self.got = len(r.read())
        except Exception as e:            # noqa: BLE001
            self.err = repr(e)
        self.secs = time.time() - t


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    man = os.path.abspath(os.path.join(here, "..", "data", "manifest.jsonl"))
    packs = []
    with open(man, encoding="utf-8") as f:
        for line in f:
            packs.append(json.loads(line))
            if len(packs) >= 400:
                break
    if len(packs) < N:
        print("清单太小")
        return

    out = []
    # 均匀取 N 个（尽量落在不同分享页/主机上）
    picked = packs[::max(1, len(packs) // N)][:N]
    prepared = []
    for p in picked:
        try:
            down, size, page = handshake(p)
            host = urllib.parse.urlparse(down).netloc
            prepared.append((p, down, size, page, host))
            out.append("准备 %-16s %-34s size=%d" % (p["zip_name"], host, size))
        except Exception as e:            # noqa: BLE001
            out.append("准备 %s 失败: %r" % (p["zip_name"], e))
        time.sleep(0.4)

    # 只用真的有 3MB 以上的包做并行测试（三个偏移 2M/3M/4M 都要落在文件内）
    prepared = [t for t in prepared if t[2] > 4 * CHUNK]
    if len(prepared) < 2:
        out.append("可测的大包不足（需 >4MB），退出")
        print("\n".join(out))
        return
    out.append("可用于并行测试的大包: %d 个" % len(prepared))

    out.append("")
    out.append("=== 阶段1：串行（逐条各拉 1MB）===")
    solo_rates = []
    for (p, down, size, page, host) in prepared:
        s = Solo(down, size, page, 2 * CHUNK)
        s.run()
        rr = s.got / s.secs / 1024 if s.secs > 0 else 0
        solo_rates.append(rr)
        out.append("  %-16s %-34s %6.0f KB/s  got=%dB %.1fs %s"
                   % (p["zip_name"], host, rr, s.got, s.secs, s.err or ""))
        time.sleep(1.0)
    solo_avg = sum(solo_rates) / len(solo_rates) if solo_rates else 0

    out.append("")
    out.append("=== 阶段2：并行（同时拉，各 1MB）===")
    runs = []
    for i, (p, down, size, page, host) in enumerate(prepared):
        runs.append(Solo(down, size, page, 3 * CHUNK))
    ths = [threading.Thread(target=r.run) for r in runs]
    t0 = time.time()
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    wall = time.time() - t0
    par_rates = []
    for (p, down, size, page, host), r in zip(prepared, runs):
        rr = r.got / r.secs / 1024 if r.secs > 0 else 0
        par_rates.append(rr)
        out.append("  %-16s %-34s %6.0f KB/s  got=%dB %.1fs %s"
                   % (p["zip_name"], host, rr, r.got, r.secs, r.err or ""))
    par_avg = sum(par_rates) / len(par_rates) if par_rates else 0
    total_bytes = sum(r.got for r in runs)
    agg = total_bytes / wall / 1024 if wall > 0 else 0

    out.append("")
    out.append("=== 判读 ===")
    out.append("  串行平均单条      : %6.0f KB/s" % solo_avg)
    out.append("  并行平均单条      : %6.0f KB/s" % par_avg)
    out.append("  并行总吞吐        : %6.0f KB/s  (墙钟 %.1fs, 共 %dB)" % (agg, wall, total_bytes))
    out.append("  加速比(总/串行单条): %6.2fx   （=1 说明是 IP 级；=N 说明是连接级）"
               % (agg / solo_avg if solo_avg > 0 else 0))

    txt = "\n".join(out)
    with open(os.path.join(os.environ["TEMP"], "parallel_probe.txt"),
              "w", encoding="utf-8") as fo:
        fo.write(txt + "\n")
    print(txt)


if __name__ == "__main__":
    main()
