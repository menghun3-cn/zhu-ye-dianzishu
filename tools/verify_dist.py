import zipfile, os, hashlib

DIST = r"F:\asc_workspace\code\aicode\zhu-ye-dianzishu\dist"

def ls(path, prefixes=None, limit=40):
    z = zipfile.ZipFile(path)
    names = [n for n in z.namelist() if (prefixes is None or any(n.startswith(p) for p in prefixes))]
    return names[:limit], len(z.namelist())

for apk in ["zhu-ye-reader-arm64.apk", "zhu-ye-reader-universal.apk"]:
    p = os.path.join(DIST, apk)
    libs, total = ls(p, ["lib/"])
    print(f"== {apk}  size={os.path.getsize(p)}  entries={total}")
    for l in sorted(libs):
        print("   ", l)

p = os.path.join(DIST, "zhu-ye-reader-windows-x64.zip")
names, total = ls(p, ["flutter_assets/"], limit=15)
print(f"== windows zip  size={os.path.getsize(p)}  entries={total}")
z = zipfile.ZipFile(p)
top = sorted({n.split('/')[0] for n in z.namelist()})
print("   top-level:", top)
print("   sample:", names)
