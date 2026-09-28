# -*- coding: utf-8 -*-
"""逐块打点诊断：搞清「前 12 本快、之后全卡死」到底是什么机制。

对每个文件：完整走三步握手，然后按 threshold 逐块下载，
每块记录 HTTP 状态、Content-Range、字节数、耗时、瞬时速度。
"""
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
NBOOK = 4

opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    urllib.request.ProxyHandler({}))
opener.addheaders = [("User-Agent", UA)]


def get(url, ref=None, rng=None, timeout=60):
    req = urllib.request.Request(url)
    if ref:
        req.add_header("Referer", ref)
    req.add_header("X-Requested-With", "XMLHttpRequest")
    if rng:
        req.add_header("Range", rng)
    return opener.open(req, timeout=timeout)


def one(pack, idx):
    L = []
    page = pack["url"]
    m = FID_RE.search(page)
    fpart = m.group(0)[3:]
    pc = urllib.parse.parse_qs(urllib.parse.urlparse(page).query).get("p", [""])[0]
    L.append("#%d %s" % (idx, pack["zip_name"]))
    try:
        get(page).read()
        u1 = ("%s/getfile.php?path=f&f=%s&passcode=%s&ref=&url=%s"
              % (API, fpart, pc, urllib.parse.quote(page, safe="")))
        j1 = json.loads(get(u1, ref=page).read().decode("utf-8"))
        f = j1.get("file") or {}
        L.append("  getfile code=%s wait=%s free_speed=%s size=%s"
                 % (j1.get("code"), f.get("wait_seconds"), f.get("free_speed"), f.get("file_size")))
        if j1.get("code") != 200:
            return L
        u2 = ("%s/get_file_url.php?uid=%s&fid=%s&folder_id=0&share_id="
              "&file_chk=%s&start_time=%s&wait_seconds=0&mb=0&app=0&acheck=0"
              "&verifycode=%s&rd=%s"
              % (API, f["userid"], f["file_id"], f["file_chk"], f["start_time"],
                 f["verifycode"], int(time.time() * 1000)))
        j2 = json.loads(get(u2, ref=page).read().decode("utf-8"))
        if j2.get("code") != 200:
            L.append("  get_file_url code=%s msg=%s" % (j2.get("code"), j2.get("msg")))
            return L
        down = j2["downurl"]
        size = int(j2["file_size"])
        q = urllib.parse.parse_qs(urllib.parse.urlparse(down).query)
        thr = int(q.get("threshold", ["0"])[0])
        host = urllib.parse.urlparse(down).netloc
        L.append("  down host=%s threshold=%d size=%d" % (host, thr, size))
    except Exception as e:
        L.append("  HANDSHAKE ERR %r" % e)
        return L

    chunk = max(512 * 1024, min(thr if thr > 0 else size, 8 * 1024 * 1024))
    off = 0
    total = 0
    t_all = time.time()
    while off < size:
        end = min(off + chunk - 1, size - 1)
        t = time.time()
        try:
            r = get(down, ref=page, rng="bytes=%d-%d" % (off, end), timeout=60)
            data = r.read()
            dt = time.time() - t
            cr = r.headers.get("Content-Range")
            L.append("    blk %-24s off=%-9d got=%-9d %6.2fs %8.0f KB/s cr=%s"
                     % ("[%d-%d]" % (off, end), off, len(data), dt,
                        (len(data) / dt / 1024) if dt > 0 else 0, cr))
            if not data:
                L.append("    ZERO BYTES -> abort")
                break
            off += len(data)
            total += len(data)
        except Exception as e:
            L.append("    blk off=%d ERR %r" % (off, e))
            break
    L.append("  total=%dB in %.1fs -> %.0f KB/s avg" % (total, time.time() - t_all,
                                                         total / max(time.time() - t_all, 0.01) / 1024))
    return L


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    man = os.path.abspath(os.path.join(here, "..", "data", "manifest.jsonl"))
    state = os.path.abspath(os.path.join(here, "..", "data", "_probe-state.jsonl"))
    done = set()
    if os.path.exists(state):
        with open(state, encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                    if r.get("status") == "ok":
                        done.add(r["fid"])
                except Exception:
                    pass

    packs = []
    with open(man, encoding="utf-8") as f:
        for line in f:
            p = json.loads(line)
            if p["fid"] not in done:
                packs.append(p)
            if len(packs) >= NBOOK:
                break

    dest = os.path.join(os.environ["TEMP"], "chunk-diag.txt")
    with open(dest, "w", encoding="utf-8", buffering=1) as out:
        for i, p in enumerate(packs, 1):
            for ln in one(p, i):
                out.write(ln + "\n")
                print(ln, flush=True)
            out.write("  ---\n")


if __name__ == "__main__":
    main()
