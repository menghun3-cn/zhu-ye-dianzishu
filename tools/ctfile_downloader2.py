# -*- coding: utf-8 -*-
"""城通网盘（ctfile）批量下载器 v3 —— 「不静默、踩地板」策略（2026-09-28 重测后改写）。

实测（2026-09-28，_diag_sustain.py / _diag_parallel.py）：
  * 爆发额度约 **9MB**（不是 30~100MB）：满速 ~1MB/s 只能持续 ~9s；
  * 额度耗尽后 **16KB/s 是可以一直用的速率**，不是「被封」——连续 600s 稳定不掉；
  * 额度**按账号共享，不按 CDN 主机**：两条不同线路会同时掉到 16KB/s，
    所以「换主机 / 多线程」拿不到额外额度（已验证）；
  * 静默 R 秒的收益 = 回血 R×16KB/s，超过 **576s 就是净亏**（900s 静默净亏 5.4MB）。

v2 的错误（本次修正）：
  * 把 HTTP **503/403/410 也当成「限速」**去静默 300~900s。实测那是**链接失效**——
    静默 900s 后重试 11s 就下完了，纯浪费（一天里 40% 时间耗在这上面）。
  * 默认走「长静默 + 探测」，但探测阈值 500KB/s 只在爆发期存在 → 等于永远判「未恢复」。

v3 策略：
  1. `--rest-max 0`（默认新配置）：**遇到限速不静默**，直接重握手继续踩 16KB/s 地板。
  2. **403/404/410/503 = 链接失效**，立刻重握手，绝不静默；用 max-relinks 封顶防空转。
  3. 慢块判定放宽到 <6.5KB/s（16KB/s 地板不能被误判成限速）。
  4. `--rest-max > 0` 时保留 v2 的「静默 + 探测」路径（上限务必 <=576s）。
  5. 单本 active 时长上限默认 10800s（地板速率下 100MB 要约 6400 活跃秒）。
  6. .part 断点续传；zip CRC 校验通过才原子改名落盘。

用法：
  python ctfile_downloader2.py --manifest data/manifest.jsonl --root E:\\chinabook \\
         --state data/download-state.jsonl --workers 1 --loop \\
         --rest-min 0 --rest-max 0 --max-relinks 5 --pack-timeout 10800
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

CHUNK_MAX = 4 * 1024 * 1024      # 4MB，留足 threshold 余量
CHUNK_MIN = 512 * 1024
READ_PIECE = 64 * 1024
PROGRESS_EVERY = 60              # 秒

_log_lock = threading.Lock()
_state_lock = threading.Lock()
_stat_lock = threading.Lock()


def now():
    return datetime.datetime.now().strftime("%H:%M:%S")


class Throttled(Exception):
    """限速信号：慢块检测判定当前连接已被 16KB/s 限速。"""


class Stats:
    def __init__(self, total):
        self.done = 0
        self.failed = 0
        self.skipped = 0
        self.bytes = 0
        self.total = total
        self.throttles = 0
        self.rests = 0
        self.t0 = time.time()
        self.last_err = ""
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
                "done": self.done, "failed": self.failed, "skipped": self.skipped,
                "bytes": self.bytes, "total": self.total,
                "throttles": self.throttles, "rests": self.rests,
                "elapsed_sec": int(el),
                "avg_kbps": round(self.bytes / el / 1024.0, 1) if el > 0 else 0,
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
    """全局退避闸门。"""

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


class Pacer:
    """握手节流。"""

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
        req.add_header("X-Requested-With", "XMLHttpRequest")
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


def probe_speed(sess, down, page, off, size, probe_bytes, timeout):
    """小 Range 请求测速。返回 (kbps, range_ok)。"""
    end = min(off + probe_bytes - 1, max(size - 1, off))
    t0 = time.time()
    n = 0
    try:
        resp = sess.get(down, ref=page, rng="bytes=%d-%d" % (off, end), timeout=timeout)
        if getattr(resp, "status", 206) == 200 and off > 0:
            return 0.0, False          # 服务端忽略 Range，链路已失效，需要重握手
        while n < probe_bytes:
            b = resp.read(min(READ_PIECE, probe_bytes - n))
            if not b:
                break
            n += len(b)
        dt = time.time() - t0
        if n <= 0 or dt <= 0:
            return 0.0, True
        return n / dt / 1024.0, True
    except Exception:
        return 0.0, False


def wait_recovered(sess, down, page, off, size, args, log, gate):
    """长静默 + 低频探测，直到额度回血。返回 True=恢复，False=超时。"""
    waited = 0
    log("REST off=%d 静默等待额度回血（min=%ds max=%ds probe=%ds/%dKB/>=%.0fKB/s）"
        % (off, args.rest_min, args.rest_max, args.probe_interval,
           args.probe_bytes // 1024, args.probe_kbps))
    while waited < args.rest_max:
        gate.wait()
        if waited < args.rest_min:
            step = min(args.rest_min - waited, 30)
            time.sleep(step)
            waited += step
            continue
        kbps, ok = probe_speed(sess, down, page, off, size,
                               args.probe_bytes, args.probe_timeout)
        if ok and kbps >= args.probe_kbps:
            log("RECOVER off=%d probe=%.0fKB/s（静默 %ds 后恢复）" % (off, kbps, waited))
            return True
        log("PROBE off=%d %.0fKB/s ok=%s（未恢复，已静默 %ds/%ds）"
            % (off, kbps, ok, waited, args.rest_max))
        time.sleep(args.probe_interval)
        waited += args.probe_interval
    log("REST-TIMEOUT 静默 %ds 仍未恢复，跳过本轮" % waited)
    return False


def download_pack(pack, root, sess, log, stats, gate, pacer, args):
    """返回 (status, info, active_secs)。status: ok/skip/fail。"""
    final = os.path.join(root, pack["zip_name"])
    if os.path.exists(final) and os.path.getsize(final) > 0:
        return "skip", 0, 0.0

    tmpdir = os.path.join(root, ".tmp")
    os.makedirs(tmpdir, exist_ok=True)
    part = os.path.join(tmpdir, pack["zip_name"] + ".part")

    try:
        down, size, page, threshold, host = resolve(pack, sess, pacer)
    except Exception as e:
        return "fail", "handshake: %s" % e, 0.0

    chunk = max(CHUNK_MIN, min(threshold if threshold > 0 else CHUNK_MAX, CHUNK_MAX))

    t_start = time.time()
    active = 0.0
    off = os.path.getsize(part) if os.path.exists(part) else 0
    if off > size:
        os.remove(part)
        off = 0
    fh = open(part, "ab" if off > 0 else "wb")

    rest_cycles = 0
    relinks = 0
    since_relink = 0  # 距上次重握手又下了多少字节（>4MB 就清零 relinks 计数）
    try:
        while off < size:
            if active > args.pack_timeout:
                return "fail", "active timeout %.0fs @%.1f%%" % (
                    active, 100.0 * off / max(size, 1)), active
            gate.wait()
            end = min(off + chunk - 1, size - 1)
            t_chunk = time.time()
            got_chunk = 0
            throttled = False
            relink = False
            try:
                resp = sess.get(down, ref=page, rng="bytes=%d-%d" % (off, end),
                                timeout=args.stall_secs)
                if getattr(resp, "status", 206) == 200 and off > 0:
                    log("RANGE-IGNORED %s off=%d，重新握手" % (pack["zip_name"], off))
                    relink = True
                else:
                    while True:
                        piece = resp.read(READ_PIECE)
                        if not piece:
                            break
                        fh.write(piece)
                        off += len(piece)
                        got_chunk += len(piece)
                        since_relink += len(piece)
                        stats.add_bytes(len(piece))
                        dt = time.time() - t_chunk
                        active += 0  # active 在窗口判定处累加
                        if dt > args.slow_window and got_chunk < args.slow_bytes:
                            raise Throttled(
                                "slow block: %dB in %.1fs (%.0f KB/s)"
                                % (got_chunk, dt, got_chunk / dt / 1024))
            except (socket.timeout, TimeoutError) as e:
                throttled = True
                stats.throttles += 1
                log("STALL %s off=%d sock-timeout" % (pack["zip_name"], off))
            except Throttled as e:
                throttled = True
                stats.throttles += 1
                log("THROTTLE %s off=%d %s host=%s" % (pack["zip_name"], off, e, host))
            except urllib.error.HTTPError as e:
                if e.code in (403, 404, 410, 503):
                    # 403/404/410/503 = 链接失效或主机拒绝，**不是限速**。
                    # 实测：503 后静默 900s 是纯浪费，直接重握手往往几秒就下完。
                    relink = True
                    log("HTTP%s %s off=%d，链接失效/主机拒绝 → 直接重握手（不静默）"
                        % (e.code, pack["zip_name"], off))
                else:
                    raise
            active += time.time() - t_chunk

            if throttled:
                fh.flush()
                if args.rest_max > 0:
                    rest_cycles += 1
                    stats.rests += 1
                    if rest_cycles > args.max_rest_cycles:
                        return "fail", "rest-cycles>%d @%.1f%% (host=%s)" % (
                            args.max_rest_cycles, 100.0 * off / max(size, 1), host), active
                    fh.close()
                    if not wait_recovered(sess, down, page, off, size, args, log, gate):
                        return "fail", "no-recovery @%.1f%%" % (
                            100.0 * off / max(size, 1)), active
                    fh = open(part, "ab")
                    continue
                # rest-max<=0：不静默（实测 16KB/s 地板可持续下载，静默>576s 是净亏）
                relink = True

            if relink:
                if since_relink > 4 * 1024 * 1024:
                    # 上次重握手后又实打实下了 4MB+ ⇒ 之前的 relinks 是正常换链，不该计入封顶
                    relinks = 0
                    since_relink = 0
                relinks += 1
                if relinks > args.max_relinks:
                    fh.close()
                    return "fail", "relink>%d @%.1f%% (host=%s)" % (
                        args.max_relinks, 100.0 * off / max(size, 1), host), active
                if throttled and args.relink_backoff > 0:
                    time.sleep(args.relink_backoff)
                fh.close()
                try:
                    down, size, page, threshold, host = resolve(pack, sess, pacer)
                    chunk = max(CHUNK_MIN, min(threshold if threshold > 0 else CHUNK_MAX, CHUNK_MAX))
                except Exception as e:
                    return "fail", "re-resolve: %s" % e, active
                if off > size:
                    os.remove(part)
                    off = 0
                    fh = open(part, "wb")
                else:
                    fh = open(part, "ab")
    except Exception as e:
        try:
            fh.close()
        except Exception:
            pass
        return "fail", "%s: %s" % (type(e).__name__, e), active
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
        return "fail", "非法 zip: %s" % e, active

    os.replace(part, final)
    return "ok", size, active


def load_state(path):
    done, failed = set(), set()
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
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
    return done, failed


def run_pass(packs, done, args, log, stats, gate, pacer, state_fh):
    todo = [p for p in packs if p["fid"] in args._failed_only] if args.retry_failed_only \
        else [p for p in packs if p["fid"] not in done]
    # 优先续传已经下了一半的（.part 存在）—— 半成品最划算，先收尾
    tmpdir = os.path.join(args.root, ".tmp")
    todo.sort(key=lambda p: 0 if os.path.exists(
        os.path.join(tmpdir, p["zip_name"] + ".part")) else 1)
    if not todo:
        log("PASS nothing to do")
        return
    log("PASS begin todo=%d" % len(todo))
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
            status, info, active = "fail", "unknown", 0.0
            for attempt in range(1, args.max_attempts + 1):
                status, info, active = download_pack(
                    pack, args.root, sess, log, stats, gate, pacer, args)
                if status in ("ok", "skip"):
                    break
                log("RETRY %s attempt=%d/%d err=%s"
                    % (pack["zip_name"], attempt, args.max_attempts, info))
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
                    if status == "fail":
                        args._failed_only.add(pack["fid"])
            rec = {"fid": pack["fid"], "zip": pack["zip_name"], "status": status,
                   "size": info if status == "ok" else None,
                   "err": None if status == "ok" else str(info),
                   "worker": wid, "secs": round(dt, 1), "active": round(active, 1),
                   "ts": datetime.datetime.now().isoformat(timespec="seconds")}
            with _state_lock:
                state_fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            if status == "ok":
                log("OK   %s %.2fMB %.0fs(活跃 %.0fs)"
                    % (pack["zip_name"], (info or 0) / 1048576.0, dt, active))
            elif status == "fail":
                log("FAIL %s %s" % (pack["zip_name"], info))

    threads = [threading.Thread(target=worker, args=(i,), daemon=True)
               for i in range(max(1, args.workers))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--workers", type=int, default=1)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--delay", type=float, default=0.5)
    ap.add_argument("--proxy", action="store_true")
    ap.add_argument("--max-attempts", type=int, default=2)
    ap.add_argument("--stall-secs", type=int, default=20)
    ap.add_argument("--slow-window", type=float, default=8.0)
    ap.add_argument("--slow-bytes", type=int, default=256 * 1024)
    ap.add_argument("--pack-timeout", type=int, default=1800,
                    help="单本**活跃下载**时长上限（秒），不含静默等待")
    ap.add_argument("--max-rest-cycles", type=int, default=4,
                    help="单本最多容忍多少轮限速静默，超过跳下一本")
    ap.add_argument("--retry-failed-only", action="store_true")
    ap.add_argument("--rest-min", type=int, default=900,
                    help="限速后最少静默秒数（<30min 的静默基本没用）")
    ap.add_argument("--rest-max", type=int, default=5400,
                    help="限速后最多静默秒数，超过放弃本轮")
    ap.add_argument("--probe-interval", type=int, default=300,
                    help="静默期探测间隔秒")
    ap.add_argument("--probe-bytes", type=int, default=256 * 1024)
    ap.add_argument("--probe-kbps", type=float, default=500.0,
                    help="探测速率达到此值才算额度回血")
    ap.add_argument("--probe-timeout", type=int, default=60)
    ap.add_argument("--max-relinks", type=int, default=5,
                    help="单本最多重握手多少次（403/404/410/503，或静默关闭时的限速）")
    ap.add_argument("--relink-backoff", type=int, default=5,
                    help="因限速而重握手时的退避秒数（防打崩服务器）")
    ap.add_argument("--resolve-gap", type=float, default=1.5)
    ap.add_argument("--cooldown", type=int, default=10)
    ap.add_argument("--loop", action="store_true", help="跑完一轮后继续下一轮（永续）")
    ap.add_argument("--loop-rest", type=int, default=300, help="轮与轮之间静默秒数")
    args = ap.parse_args()
    args._failed_only = set()

    os.makedirs(args.root, exist_ok=True)
    os.makedirs(os.path.dirname(os.path.abspath(args.state)), exist_ok=True)
    logdir = os.path.join(os.path.dirname(os.path.abspath(args.state)), "logs")
    log = Logger(os.path.join(logdir, "dl2-%s.log" % datetime.date.today().isoformat()))

    packs = []
    with open(args.manifest, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                packs.append(json.loads(line))
    if args.limit:
        packs = packs[:args.limit]

    done, failed = load_state(args.state)
    args._failed_only = set(failed)

    log("START v3 packs=%d already_ok=%d failed_known=%d workers=%d limit=%s root=%s"
        % (len(packs), len(done), len(failed), args.workers, args.limit or "-", args.root))

    stats = Stats(len(packs))
    stats.done = len(done)
    stats.skipped = len(done)
    gate = Gate()
    pacer = Pacer(args.resolve_gap)
    state_fh = open(args.state, "a", encoding="utf-8", buffering=1)
    prog_path = os.path.join(os.path.dirname(os.path.abspath(args.state)), "progress2.json")
    stop = threading.Event()

    def monitor():
        while not stop.wait(PROGRESS_EVERY):
            snap = stats.snapshot()
            remaining = snap["total"] - snap["done"] - snap["failed"]
            snap["remaining"] = remaining
            snap["updated_at"] = datetime.datetime.now().isoformat(timespec="seconds")
            try:
                tmp = prog_path + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump(snap, f, ensure_ascii=False, indent=2)
                os.replace(tmp, prog_path)
            except Exception:
                pass
            log("PROGRESS done=%d fail=%d skip=%d win=%.0fKB/s avg=%.0fKB/s "
                "throttles=%d rests=%d remaining=%d"
                % (snap["done"], snap["failed"], snap["skipped"], snap["win_kbps"],
                   snap["avg_kbps"], snap["throttles"], snap["rests"], remaining))
            stats.roll_window()

    threading.Thread(target=monitor, daemon=True).start()

    t0 = time.time()
    passes = 0
    while True:
        run_pass(packs, done, args, log, stats, gate, pacer, state_fh)
        passes += 1
        # 重新读状态，让下一轮只补漏
        done, failed = load_state(args.state)
        args._failed_only = set(failed)
        snap = stats.snapshot()
        log("PASS-END #%d done=%d fail=%d bytes=%.2fMB elapsed=%.1fmin"
            % (passes, snap["done"], snap["failed"], snap["bytes"] / 1048576.0,
               (time.time() - t0) / 60.0))
        if not args.loop:
            break
        remaining = len(packs) - len(done)
        if remaining <= 0:
            log("ALL-COMPLETE 全部下载完成")
            break
        log("LOOP-REST %ds（下一轮只补漏，剩余 %d 本）" % (args.loop_rest, remaining))
        time.sleep(args.loop_rest)

    snap = stats.snapshot()
    log("FINISH done=%d fail=%d skip=%d bytes=%.2fMB elapsed=%.1fmin throttles=%d rests=%d"
        % (snap["done"], snap["failed"], snap["skipped"], snap["bytes"] / 1048576.0,
           (time.time() - t0) / 60.0, snap["throttles"], snap["rests"]))
    state_fh.close()
    stop.set()


if __name__ == "__main__":
    sys.exit(main())
