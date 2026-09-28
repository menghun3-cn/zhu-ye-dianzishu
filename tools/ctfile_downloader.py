# -*- coding: utf-8 -*-
"""城通网盘（ctfile）批量下载器 —— 断点续传 / 分块绕节流 / 慢链路自愈。

协议（对应 skill: ctfile-batch-download）：
  ① GET /getfile.php      拿 file_chk / start_time / verifycode / userid
  ② GET /get_file_url.php 换签名直链（必须带 X-Requested-With，否则 200 空 body）
  ③ GET <直链>  Range 分块

两个必须知道的实测规律：
  * threshold 逐文件不同，= max(1MB, size*40%)。块大小一旦超过它，溢出部分立刻掉到 16KB/s。
    所以每本书都要重新解析 downurl 里的 threshold，绝不能写死。
  * 突发请求会触发服务端软限速：速率跌到 16KB/s 且**不是永久的**，静默几分钟后恢复；
    不同媒体主机（xxx-usw-data.tv002.com）表现还不一致。因此必须做「慢块检测 → 换链重试
    → 全局冷却」，而不是死等。

关键设计：
  - 流式写入，边写边记 off；慢块中断时已写入的字节不丢，换链后从新 off 续。
  - 慢块判定：(a) socket 阻塞超过 --stall-secs 无数据；(b) 单位窗口内吞吐低于 --slow-kbps。
  - 任一 worker 触发慢速 → 置全局冷却，所有 worker 一起退避，避免继续刺激服务端。
  - 每本书下载完做 zip CRC 校验，通过才原子改名落盘。

用法：
  python ctfile_downloader.py --manifest data/manifest.jsonl --root E:\\chinabook \\
         --state data/download-state.jsonl --workers 2 --limit 500
"""
import argparse
import datetime
import http.cookiejar
import json
import os
import random
import re
import socket
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import zipfile

API = "https://webapi.ctfile.com"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
FID_RE = re.compile(r"/f/(\d+)-(\d+)-([0-9a-fA-F]+)")

CHUNK_MAX = 4 * 1024 * 1024      # 4MB，留足 threshold 余量，也让慢块更快暴露
CHUNK_MIN = 512 * 1024
READ_PIECE = 64 * 1024
PROGRESS_EVERY = 20              # 秒

_log_lock = threading.Lock()
_state_lock = threading.Lock()
_stat_lock = threading.Lock()


def now():
    return datetime.datetime.now().strftime("%H:%M:%S")


class Stats:
    def __init__(self, total):
        self.done = 0
        self.failed = 0
        self.skipped = 0
        self.bytes = 0
        self.total = total
        self.stalls = 0
        self.throttles = 0
        self.t0 = time.time()
        self.last_err = ""
        # 滚动窗口，用于判断"当前是否被限速"
        self.win_t = time.time()
        self.win_b = 0

    def add_bytes(self, n):
        with _stat_lock:
            self.bytes += n
            self.win_b += n

    def snapshot(self):
        with _stat_lock:
            el = time.time() - self.t0
            wdt = max(time.time() - self.win_t, 0.001)
            return {
                "done": self.done,
                "failed": self.failed,
                "skipped": self.skipped,
                "bytes": self.bytes,
                "total": self.total,
                "stalls": self.stalls,
                "throttles": self.throttles,
                "elapsed_sec": int(el),
                "avg_mbps": round(self.bytes / el / 1048576.0, 3) if el > 0 else 0,
                "win_kbps": round(self.win_b / wdt / 1024.0, 1),
                "last_err": self.last_err,
            }

    def roll_window(self):
        with _stat_lock:
            self.win_t = time.time()
            self.win_b = 0


class Logger:
    def __init__(self, path):
        self.path = path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.f = open(path, "a", encoding="utf-8", buffering=1)

    def __call__(self, msg):
        line = "%s %s" % (now(), msg)
        with _log_lock:
            self.f.write(line + "\n")
            try:
                print(line, flush=True)
            except Exception:
                pass


class Gate:
    """全局退避闸门：任一 worker 发现被限速，所有 worker 一起停一会儿。"""

    def __init__(self):
        self.until = 0.0
        self.lock = threading.Lock()

    def pause(self, secs):
        with self.lock:
            t = time.time() + secs
            if t > self.until:
                self.until = t

    def wait(self):
        while True:
            with self.lock:
                d = self.until - time.time()
            if d <= 0:
                return
            time.sleep(min(d, 5))


class Throttled(Exception):
    pass


class Pacer:
    """全局握手节流：实测突发大量 getfile/get_file_url 会招来 503，
    所以强制所有 worker 的握手之间留一个最小间隔。"""

    def __init__(self, gap):
        self.gap = gap
        self.next_at = 0.0
        self.lock = threading.Lock()

    def wait(self):
        if self.gap <= 0:
            return
        while True:
            with self.lock:
                t = time.time()
                if t >= self.next_at:
                    self.next_at = t + self.gap
                    return
                d = self.next_at - t
            time.sleep(min(d, 1.0))


class Session:
    def __init__(self, use_proxy=False, sock_timeout=20):
        cj = http.cookiejar.CookieJar()
        handlers = [urllib.request.HTTPCookieProcessor(cj)]
        if not use_proxy:
            handlers.append(urllib.request.ProxyHandler({}))
        self.opener = urllib.request.build_opener(*handlers)
        self.opener.addheaders = [("User-Agent", UA),
                                  ("Accept", "*/*"),
                                  ("Accept-Language", "zh-CN,zh;q=0.9")]
        self.sock_timeout = sock_timeout

    def get(self, url, ref=None, rng=None, timeout=None):
        req = urllib.request.Request(url)
        if ref:
            req.add_header("Referer", ref)
        req.add_header("X-Requested-With", "XMLHttpRequest")   # ← 少这个 = 200 空 body
        if rng:
            req.add_header("Range", rng)
        return self.opener.open(req, timeout=timeout or self.sock_timeout)


def resolve(pack, sess, pacer=None):
    """三步握手 → (downurl, size, page, threshold, host)。"""
    if pacer is not None:
        pacer.wait()
    page = pack["url"]
    m = FID_RE.search(page)
    fpart = m.group(0)[3:]
    pc = urllib.parse.parse_qs(urllib.parse.urlparse(page).query).get("p", [""])[0]

    try:
        sess.get(page, timeout=30).read()
    except Exception:
        pass

    u1 = ("%s/getfile.php?path=f&f=%s&passcode=%s&ref=&url=%s"
          % (API, fpart, pc, urllib.parse.quote(page, safe="")))
    r1 = sess.get(u1, ref=page, timeout=40).read()
    if not r1:
        raise RuntimeError("getfile.php 空 body")
    j1 = json.loads(r1.decode("utf-8"))
    if j1.get("code") != 200:
        raise RuntimeError("getfile.php code=%s msg=%s" % (j1.get("code"), j1.get("msg")))
    f = j1["file"]

    u2 = ("%s/get_file_url.php?uid=%s&fid=%s&folder_id=0&share_id="
          "&file_chk=%s&start_time=%s&wait_seconds=0&mb=0&app=0&acheck=0"
          "&verifycode=%s&rd=%s"
          % (API, f["userid"], f["file_id"], f["file_chk"], f["start_time"],
             f["verifycode"], int(time.time() * 1000)))
    r2 = sess.get(u2, ref=page, timeout=40).read()
    if not r2:
        raise RuntimeError("get_file_url.php 空 body")
    j2 = json.loads(r2.decode("utf-8"))
    if j2.get("code") != 200:
        raise RuntimeError("get_file_url.php code=%s msg=%s" % (j2.get("code"), j2.get("msg")))

    down = j2["downurl"]
    q = urllib.parse.parse_qs(urllib.parse.urlparse(down).query)
    try:
        threshold = int(q.get("threshold", ["0"])[0])
    except Exception:
        threshold = 0
    host = urllib.parse.urlparse(down).netloc
    return down, int(j2["file_size"]), page, threshold, host


def download_pack(pack, root, sess, log, stats, gate, pacer, args):
    final = os.path.join(root, pack["zip_name"])
    if os.path.exists(final) and os.path.getsize(final) > 0:
        return "skip", 0

    tmpdir = os.path.join(root, ".tmp")
    os.makedirs(tmpdir, exist_ok=True)
    part = os.path.join(tmpdir, pack["zip_name"] + ".part")

    try:
        down, size, page, threshold, host = resolve(pack, sess, pacer)
    except Exception as e:
        return "fail", "handshake: %s" % e

    chunk = max(CHUNK_MIN, min(threshold if threshold > 0 else CHUNK_MAX, CHUNK_MAX))

    t_start = time.time()
    off = os.path.getsize(part) if os.path.exists(part) else 0
    if off > size:
        os.remove(part)
        off = 0
    fh = open(part, "ab" if off > 0 else "wb")

    slow_events = 0
    total_slow = 0
    try:
        while off < size:
            if time.time() - t_start > args.pack_timeout:
                fh.close()
                return "fail", "per-pack timeout %.0fs @%.1f%%" % (
                    time.time() - t_start, 100.0 * off / max(size, 1))
            gate.wait()
            end = min(off + chunk - 1, size - 1)
            t_chunk = time.time()
            got_chunk = 0
            try:
                resp = sess.get(down, ref=page, rng="bytes=%d-%d" % (off, end),
                                timeout=args.stall_secs)
                if getattr(resp, "status", 206) == 200 and off > 0:
                    # 服务端忽略 Range：整体重置
                    log("RANGE-IGNORED %s，从头重下" % pack["zip_name"])
                    fh.close()
                    fh = open(part, "wb")
                    off = 0
                    got_chunk = 0
                    t_chunk = time.time()
                while True:
                    piece = resp.read(READ_PIECE)
                    if not piece:
                        break
                    fh.write(piece)
                    off += len(piece)
                    got_chunk += len(piece)
                    stats.add_bytes(len(piece))
                    dt = time.time() - t_chunk
                    # 慢块判定：窗口内吞吐过低
                    if dt > args.slow_window and got_chunk < args.slow_bytes:
                        raise Throttled(
                            "slow block: %dB in %.1fs (%.0f KB/s)"
                            % (got_chunk, dt, got_chunk / dt / 1024))
            except (socket.timeout, TimeoutError) as e:
                slow_events += 1
                total_slow += 1
                stats.stalls += 1
                log("STALL %s off=%d sock-timeout，换链重试" % (pack["zip_name"], off))
            except Throttled as e:
                slow_events += 1
                total_slow += 1
                stats.throttles += 1
                log("THROTTLE %s off=%d %s host=%s" % (pack["zip_name"], off, e, host))
            except urllib.error.HTTPError as e:
                slow_events += 1
                total_slow += 1
                if e.code in (403, 404, 410, 503):
                    log("HTTP%s %s off=%d，换链重试" % (e.code, pack["zip_name"], off))
                else:
                    raise
            if total_slow >= args.max_slow:
                # 这台媒体主机对这个文件就是不给力（实测：主机按文件绑定，换链换不掉），
                # 直接放弃，留给下一轮重试，别让单个坏文件卡死唯一的 worker。
                fh.close()
                return "fail", "give-up: %d 次限速/错误 @%.1f%% (host=%s)" % (
                    total_slow, 100.0 * off / max(size, 1), host)
            if slow_events >= 3:
                # 连续异常 → 全局冷却，然后重新握手换一台媒体主机
                cool = args.cooldown
                gate.pause(cool)
                log("COOLDOWN %ds（%s 连续 %d 次异常，host=%s）"
                    % (cool, pack["zip_name"], slow_events, host))
                slow_events = 0
            if off < size:
                # 重新握手换链（可能落到另一台媒体主机）
                try:
                    down, size, page, threshold, host = resolve(pack, sess, pacer)
                    chunk = max(CHUNK_MIN, min(threshold if threshold > 0 else CHUNK_MAX, CHUNK_MAX))
                except Exception as e:
                    return "fail", "re-resolve: %s" % e
                if off > size:
                    fh.close()
                    fh = open(part, "wb")
                    off = 0
    except Exception as e:
        try:
            fh.close()
        except Exception:
            pass
        return "fail", "%s: %s" % (type(e).__name__, e)
    finally:
        try:
            fh.close()
        except Exception:
            pass

    try:
        with zipfile.ZipFile(part) as z:
            bad = z.testzip()
        if bad is not None:
            raise RuntimeError("zip CRC 损坏 %s" % bad)
    except zipfile.BadZipFile as e:
        try:
            os.remove(part)
        except Exception:
            pass
        return "fail", "非法 zip: %s" % e

    os.replace(part, final)
    return "ok", size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--delay", type=float, default=0.5, help="每本之间最小间隔秒（漏桶，避免触发限速）")
    ap.add_argument("--proxy", action="store_true")
    ap.add_argument("--max-attempts", type=int, default=3)
    ap.add_argument("--stall-secs", type=int, default=20, help="socket 无数据超时")
    ap.add_argument("--slow-window", type=float, default=12.0, help="慢块判定窗口(秒)")
    ap.add_argument("--slow-bytes", type=int, default=512 * 1024, help="窗口内低于此字节数判为慢块")
    ap.add_argument("--cooldown", type=int, default=10, help="被限速后的全局冷却秒数")
    ap.add_argument("--resolve-gap", type=float, default=1.5, help="握手最小间隔秒")
    ap.add_argument("--pack-timeout", type=int, default=300, help="单本下载总时长上限（秒），超时放弃留给下一轮重试")
    ap.add_argument("--max-slow", type=int, default=3, help="单本累计限速/错误达此数即放弃，避免卡死 worker")
    ap.add_argument("--retry-failed-only", action="store_true", help="只重跑上次失败的（用于补漏轮次）")
    ap.add_argument("--rest-secs", type=int, default=45, help="上一本偏慢时主动让出多少秒等突发额度恢复（0=关闭）")
    ap.add_argument("--rest-below-kbps", type=float, default=400.0, help="低于此速率视为额度已耗尽")
    args = ap.parse_args()

    os.makedirs(args.root, exist_ok=True)
    os.makedirs(os.path.dirname(os.path.abspath(args.state)), exist_ok=True)
    logdir = os.path.join(os.path.dirname(os.path.abspath(args.state)), "logs")
    log = Logger(os.path.join(logdir, "download-%s.log" % datetime.date.today().isoformat()))

    packs = []
    with open(args.manifest, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                packs.append(json.loads(line))
    if args.limit:
        packs = packs[:args.limit]

    done = set()
    failed = set()
    if os.path.exists(args.state):
        with open(args.state, encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                if r.get("status") == "ok":
                    done.add(r["fid"])
                    failed.discard(r["fid"])
                elif r.get("status") == "fail" and r["fid"] not in done:
                    failed.add(r["fid"])

    log("START packs=%d already_ok=%d workers=%d limit=%s root=%s"
        % (len(packs), len(done), args.workers, args.limit or "-", args.root))

    stats = Stats(len(packs))
    stats.done = len(done)
    stats.skipped = len(done)
    gate = Gate()
    pacer = Pacer(args.resolve_gap)
    state_fh = open(args.state, "a", encoding="utf-8", buffering=1)
    prog_path = os.path.join(os.path.dirname(os.path.abspath(args.state)), "progress.json")
    stop = threading.Event()

    def monitor():
        while not stop.wait(PROGRESS_EVERY):
            snap = stats.snapshot()
            remaining = snap["total"] - snap["done"] - snap["failed"]
            avg_mb = (snap["bytes"] / max(snap["done"] - snap["skipped"], 1)) / 1048576.0
            eta = int(remaining * avg_mb / snap["avg_mbps"]) if snap["avg_mbps"] > 0 else 0
            snap["remaining"] = remaining
            snap["eta_sec"] = eta
            snap["updated_at"] = datetime.datetime.now().isoformat(timespec="seconds")
            try:
                tmp = prog_path + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump(snap, f, ensure_ascii=False, indent=2)
                os.replace(tmp, prog_path)
            except Exception:
                pass
            log("PROGRESS done=%d fail=%d skip=%d win=%.0fKB/s avg=%.2fMB/s stalls=%d throttled=%d remaining=%d eta=%s"
                % (snap["done"], snap["failed"], snap["skipped"], snap["win_kbps"],
                   snap["avg_mbps"], snap["stalls"], snap["throttles"], remaining,
                   "%dh%02dm" % (eta // 3600, (eta % 3600) // 60)))
            stats.roll_window()

    threading.Thread(target=monitor, daemon=True).start()

    todo = [p for p in packs if p["fid"] in failed] if args.retry_failed_only \
        else [p for p in packs if p["fid"] not in done]
    cursor = [0]
    cur_lock = threading.Lock()

    def worker(wid):
        sess = Session(use_proxy=args.proxy, sock_timeout=args.stall_secs)
        while True:
            with cur_lock:
                if cursor[0] >= len(todo):
                    return
                pack = todo[cursor[0]]
                cursor[0] += 1
            if args.delay:
                time.sleep(args.delay * (1 + random.random() * 0.5))
            t0 = time.time()
            status, info = "fail", "unknown"
            for attempt in range(1, args.max_attempts + 1):
                status, info = download_pack(pack, args.root, sess, log, stats, gate, pacer, args)
                if status in ("ok", "skip"):
                    break
                log("RETRY %s attempt=%d/%d err=%s" % (pack["zip_name"], attempt, args.max_attempts, info))
                with _stat_lock:
                    stats.last_err = "%s: %s" % (pack["zip_name"], info)
                if attempt < args.max_attempts:
                    time.sleep(5 * attempt + random.random() * 3)
            dt = time.time() - t0
            with _stat_lock:
                if status == "ok":
                    stats.done += 1
                elif status == "skip":
                    stats.skipped += 1
                else:
                    stats.failed += 1
            rec = {"fid": pack["fid"], "zip": pack["zip_name"], "status": status,
                   "size": info if status == "ok" else None,
                   "err": None if status == "ok" else str(info),
                   "worker": wid, "secs": round(dt, 1),
                   "ts": datetime.datetime.now().isoformat(timespec="seconds")}
            with _state_lock:
                state_fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            if status == "ok":
                log("OK   %s %.2fMB %.0fs" % (pack["zip_name"], (info or 0) / 1048576.0, dt))
            elif status == "fail":
                log("FAIL %s %s" % (pack["zip_name"], info))

            # 占空比：突发额度是「会被耗尽的配额 + 静默若干分钟恢复」，不是恒定速率上限。
            # 一旦这一本明显慢，就主动让出 rest_secs 秒等额度回血，再冲下一本。
            kbps = (info or 0) / 1024.0 / max(dt, 0.001) if status == "ok" else 0.0
            if args.rest_secs > 0 and (status != "ok" or kbps < args.rest_below_kbps):
                log("REST %ds（上一本 %.0f KB/s / 状态=%s，让出额度）"
                    % (args.rest_secs, kbps, status))
                time.sleep(args.rest_secs)

    t0 = time.time()
    threads = [threading.Thread(target=worker, args=(i,), daemon=True)
               for i in range(max(1, args.workers))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    snap = stats.snapshot()
    log("FINISH done=%d fail=%d skip=%d bytes=%.2fGB elapsed=%.1fmin avg=%.2fMB/s stalls=%d throttled=%d"
        % (snap["done"], snap["failed"], snap["skipped"], snap["bytes"] / 1073741824.0,
           (time.time() - t0) / 60.0, snap["avg_mbps"], snap["stalls"], snap["throttles"]))
    state_fh.close()
    stop.set()


if __name__ == "__main__":
    sys.exit(main())
