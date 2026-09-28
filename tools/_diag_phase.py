# -*- coding: utf-8 -*-
"""分阶段诊断：定位城通慢在哪一步。
阶段：share页 / getfile.php / get_file_url.php / 传输
单线程顺序执行，避免互相污染。"""
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


def get(url, ref=None, rng=None, timeout=180):
    req = urllib.request.Request(url)
    if ref:
        req.add_header("Referer", ref)
    req.add_header("X-Requested-With", "XMLHttpRequest")
    if rng:
        req.add_header("Range", rng)
    return opener.open(req, timeout=timeout)


def run(one_based, pack):
    page = pack["url"]
    m = FID_RE.search(page)
    fpart = m.group(0)[3:]
    pc = urllib.parse.parse_qs(urllib.parse.urlparse(page).query).get("p", [""])[0]
    line = ["#%d %s" % (one_based, pack["zip_name"])]

    t = time.time()
    try:
        get(page, timeout=60).read()
    except Exception as e:
        line.append("  share ERR %s" % e)
        return line
    t_share = time.time() - t

    t = time.time()
    u1 = ("%s/getfile.php?path=f&f=%s&passcode=%s&ref=&url=%s"
          % (API, fpart, pc, urllib.parse.quote(page, safe="")))
    r1 = get(u1, ref=page).read()
    t_gf = time.time() - t
    if not r1:
        line.append("  getfile EMPTY  share=%.2fs gf=%.2fs" % (t_share, t_gf))
        return line
    j1 = json.loads(r1.decode("utf-8"))
    f = j1.get("file", {})
    line.append("  share=%.2fs getfile=%.2fs code=%s wait=%s free_speed=%s size=%s"
                % (t_share, t_gf, j1.get("code"), f.get("wait_seconds"),
                   f.get("free_speed"), f.get("file_size")))

    t = time.time()
    u2 = ("%s/get_file_url.php?uid=%s&fid=%s&folder_id=0&share_id="
          "&file_chk=%s&start_time=%s&wait_seconds=0&mb=0&app=0&acheck=0"
          "&verifycode=%s&rd=%s"
          % (API, f["userid"], f["file_id"], f["file_chk"], f["start_time"],
             f["verifycode"], int(time.time() * 1000)))
    r2 = get(u2, ref=page).read()
    t_gu = time.time() - t
    if not r2:
        line.append("  get_file_url EMPTY  gu=%.2fs" % t_gu)
        return line
    j2 = json.loads(r2.decode("utf-8"))
    line.append("  get_file_url=%.2fs code=%s size=%s" % (t_gu, j2.get("code"), j2.get("file_size")))
    down = j2.get("downurl") or ""
    if down:
        q = urllib.parse.parse_qs(urllib.parse.urlparse(down).query)
        line.append("    url_params: " + json.dumps(
            {k: q.get(k) for k in ("spd", "spd2", "threshold", "limit", "t", "u") if k in q},
            ensure_ascii=False))

    # 分块传输计时
    size = int(j2.get("file_size") or 0)
    for label, nbytes in (("1MB", 1048576), ("8MB", 8 * 1024 * 1024)):
        if size <= 0:
            break
        end = min(nbytes - 1, size - 1)
        t = time.time()
        try:
            data = get(down, ref=page, rng="bytes=0-%d" % end).read()
        except Exception as e:
            line.append("  xfer %s ERR %s" % (label, e))
            continue
        dt = time.time() - t
        line.append("  xfer %s got=%dB in %.2fs -> %.0f KB/s"
                    % (label, len(data), dt, len(data) / dt / 1024 if dt > 0 else 0))
    return line


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    man = os.path.join(here, "..", "data", "manifest.jsonl")
    packs = []
    with open(os.path.abspath(man), encoding="utf-8") as fh:
        for i, l in enumerate(fh):
            if i >= 12:
                break
            packs.append(json.loads(l))

    dest = os.path.join(os.environ["TEMP"], "phase-out.txt")
    with open(dest, "w", encoding="utf-8", buffering=1) as out:
        for i, p in enumerate(packs):
            try:
                lines = run(i + 1, p)
            except Exception:
                import traceback
                lines = ["#%d %s" % (i + 1, p.get("zip_name"))] + traceback.format_exc().splitlines()
            for ln in lines + ["  ---"]:
                out.write(ln + "\n")
                print(ln, flush=True)
            time.sleep(1.5)


if __name__ == "__main__":
    main()
