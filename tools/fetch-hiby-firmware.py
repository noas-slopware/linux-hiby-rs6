#!/usr/bin/env python3
"""Ask HiBy's FOTA backend which firmware it offers an RS6, and fetch it.

The stock RS6 updater (/system/app/Abupdate, com.abupdate.fota_demo_iot 2.1.24 with the
ABUP "iot_libs" SDK 2.0.8) talks to the ABUP IoT FOTA API. This script speaks the same
protocol, from the Ghidra decompile of the app's dequickened DEX (docs: see the end of
this docstring):

  1. POST https://iotapi.abupdate.com/register/<productId>
       {"mid", "oem", "models", "platform", "deviceType", "sdkversion", "appversion",
        "version", "networkType", "timestamp", "sign"}
       sign = hex(HMAC-MD5(key=productSecret, msg=mid + productId + timestamp))
     -> {"status": 1000, "data": {"deviceId", "deviceSecret"}}
  2. POST https://iotapi.abupdate.com/product/<productId>/<deviceId>/ota/checkVersion
       {"mid", "version", "networkType", "timestamp", "sign"}
       sign = hex(HMAC-MD5(key=deviceSecret, msg=deviceId + productId + timestamp))
     -> {"status": 1000, "data": {"version": "<JSON string: versionName, fileSize,
         deltaID, md5sum, deltaUrl, segmentMd5, ...>", "releaseNotes": "<JSON string>",
         "policy": "<JSON string>"}}
  timestamp = Unix seconds (a JSON number); status 1000 = OK.

The registration is cached in a state file, so a device is registered once and every
later run only does checkVersion. The mid is what the app sends with ro.fota.midType=sn:
Build.MODEL + SERIAL.upper() + a Luhn-style check digit; this script makes up a random
8-hex-digit serial unless --serial is given (never use a real unit's serial).

productId/productSecret are not in this file: they come from your own firmware. Stock
Abupdate.apk carries them as resources (resources.arsc string/rs6_id and string/rs6_secret,
both prefixed "fota/"), which the manifest meta-data fota_configuration_product_id/_secret
point at and DefaultMainOtaConfig.init() strips of "fota/". Pass --dump with your EDL dump
zip (the APK is read out of system_b.bin with debugfs) or --apk with the APK itself. They
are only needed to register; after that the state file has what checkVersion needs.

Usage:
  fetch-hiby-firmware.py check (--dump ZIP | --apk APK) [--version V] [--follow] [-o DIR]
  fetch-hiby-firmware.py fetch (--dump ZIP | --apk APK) [--version V] [--follow] -o DIR
check registers once (cached), asks for an update and HEADs the package URL; fetch also
downloads it (resuming) and checks the server's md5 and sha (SHA-1 or SHA-256).

What the server hands out (2026-10-21): one A/B *delta* OTA per step, no full package.
1.80_20231018-1816 gets 1.90_20240819-2000 (108131139 bytes), 1.90 gets
2.10_20250826-1521 (96410706 bytes), 2.10 and unknown versions get status 2101 ("No new
updates were found"). Each delta only rewrites boot, system and vendor and needs the
previous version's images to apply (see payload-extract.py info).
Stdlib only (--dump also runs debugfs). Every server reply is treated as data and saved
next to the package.
"""
import argparse
import hashlib
import hmac
import http.client
import json
import os
import random
import struct
import sys
import time
import urllib.error
import urllib.request
import zipfile

BASE = "https://iotapi.abupdate.com"          # SDKConfig.init(), isTest == false
ABUPDATE_APK = "/system/app/Abupdate/Abupdate.apk"   # in the stock system image (system-as-root)
# system/build.prop "fota properties" of stock 1.80 (read by DefaultMainOtaConfig.init())
DEVICE = {"oem": "HiBy", "models": "RS6", "platform": "SDM660_9.0", "deviceType": "smartphone"}
MODEL = "RS6"                                 # ro.product.model -> Build.MODEL
DEFAULT_VERSION = "1.80_20231018-1816"        # ro.fota.version of stock 1.80
SDK_VERSION = "2.0.8"                         # literal in RegisterRequest / productSettingInfo
APP_VERSION = "2.1.24"                        # Abupdate versionName (sent as appversion)
GAP = 4.0                                     # seconds between requests to the server
UA = "Dalvik/2.1.0 (Linux; U; Android 9; RS6 Build/PKQ1.190821.001)"

_last = [0.0]


def throttle():
    wait = _last[0] + GAP - time.monotonic()
    if wait > 0:
        time.sleep(wait)
    _last[0] = time.monotonic()


def sign(msg, key):
    # engine.security.a.a(String, String): HmacMD5, key UTF-8, message ASCII, lowercase hex
    return hmac.new(key.encode("utf-8"), msg.encode("ascii"), hashlib.md5).hexdigest()


def check_digit(s):
    # fota_demo_iot.utils.d.b(String): from the right, even positions x3 + odd positions,
    # characters valued 0-9 / A-Z=10.. / a-z=10..; round up to the next multiple of 10
    def val(c):
        o = ord(c)
        if 48 <= o <= 57:
            return o - 48
        if 65 <= o <= 90:
            return o - 65 + 10
        if 97 <= o <= 122:
            return o - 97 + 10
        return o
    even = odd = 0
    for i, c in enumerate(reversed(s)):
        if i % 2 == 0:
            even += val(c)
        else:
            odd += val(c)
    t = even * 3 + odd
    return (t + 9) // 10 * 10 - t


def make_mid(serial):
    # fota_demo_iot.utils.d.c(): MODEL + SERIAL.upper() + d.b(d.e() + SERIAL.upper()),
    # d.e() is Build.MODEL ("R6PROII" maps to "R6PII", not us)
    s = serial.upper()
    return f"{MODEL}{s}{check_digit(MODEL + s)}"


def post(url, body, log=None):
    throttle()
    data = json.dumps(body, separators=(",", ":")).encode()
    req = urllib.request.Request(url, data=data, method="POST", headers={
        "Content-Type": "application/json; charset=UTF-8",   # JsonBody -> StringBody
        "User-Agent": UA,
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raw = e.read()
        print(f"HTTP {e.code} from {url}", file=sys.stderr)
    if log:
        with open(log, "ab") as f:
            f.write(b"POST " + url.encode() + b"\n" + raw + b"\n")
    try:
        return json.loads(raw)
    except ValueError:
        sys.exit(f"non-JSON reply from {url}: {raw[:200]!r}")


def maybe_json(v):
    if isinstance(v, str):
        try:
            return json.loads(v)
        except ValueError:
            return v
    return v


def apk_product(apk):
    """string/rs6_id and string/rs6_secret out of an Abupdate.apk's resources.arsc."""
    with zipfile.ZipFile(apk) as z:
        d = z.read("resources.arsc")

    def pool(off):
        _, hsz, _, n, _, flags, so, _ = struct.unpack_from("<HHIIIIII", d, off)
        offs = struct.unpack_from("<%dI" % n, d, off + hsz)
        out = []
        for o in offs:
            p = off + so + o
            if flags & 0x100:
                p += 2 if d[p] & 0x80 else 1
                n8 = d[p]
                p += 1
                if n8 & 0x80:
                    n8 = ((n8 & 0x7F) << 8) | d[p]
                    p += 1
                out.append(d[p:p + n8].decode("utf-8", "replace"))
            else:
                n16 = struct.unpack_from("<H", d, p)[0]
                p += 2
                if n16 & 0x8000:
                    n16 = ((n16 & 0x7FFF) << 16) | struct.unpack_from("<H", d, p)[0]
                    p += 2
                out.append(d[p:p + 2 * n16].decode("utf-16-le", "replace"))
        return out

    hsz = struct.unpack_from("<H", d, 2)[0]
    gstr = pool(hsz)
    pk = hsz + struct.unpack_from("<I", d, hsz + 4)[0]
    phsz, psz = struct.unpack_from("<HI", d, pk + 2)
    kso = struct.unpack_from("<I", d, pk + 12 + 256 + 8)[0]
    keys = pool(pk + kso)
    found = {}
    q = pk + phsz
    while q < pk + psz:
        t, h, s = struct.unpack_from("<HHI", d, q)
        if t == 0x201:
            cnt, es = struct.unpack_from("<II", d, q + 12)
            for i, o in enumerate(struct.unpack_from("<%dI" % cnt, d, q + h)):
                if o == 0xFFFFFFFF:
                    continue
                a = q + es + o
                esz, fl, key = struct.unpack_from("<HHI", d, a)
                if fl & 1:          # complex entry, not a plain string
                    continue
                vt, vd = struct.unpack_from("<BI", d, a + esz + 3)
                if keys[key] in ("rs6_id", "rs6_secret") and vt == 3:
                    found[keys[key]] = gstr[vd]
        q += s
    pid, sec = found["rs6_id"], found["rs6_secret"]
    return pid.replace("fota/", "").strip(), sec.replace("fota/", "").strip()


def dump_apk(dump, slot, out):
    """Copy Abupdate.apk out of system_<slot>.bin inside an EDL dump zip (debugfs)."""
    import shutil
    import subprocess
    import tempfile
    with zipfile.ZipFile(dump) as z:
        names = [n for n in z.namelist() if n.endswith(f"/system_{slot}.bin")
                 or n == f"system_{slot}.bin"]
        if not names:
            sys.exit(f"{dump}: no system_{slot}.bin")
        with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR", "/var/tmp")) as w:
            img = os.path.join(w, "system.img")
            with z.open(names[0]) as f, open(img, "wb") as o:
                while True:         # sparse: the 3 GiB image is mostly zeros
                    b = f.read(1 << 20)
                    if not b:
                        break
                    if b.count(0) == len(b):
                        o.seek(len(b), 1)
                    else:
                        o.write(b)
                o.truncate()
            subprocess.run(["debugfs", "-R", f"dump {ABUPDATE_APK} {out}", img],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not os.path.getsize(out):
        sys.exit(f"{dump}: {ABUPDATE_APK} not found in system_{slot}.bin")


def load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save_state(path, st):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f, indent=1)
    os.replace(tmp, path)


def register(st, args, pid, psec, log):
    mid = st.get("mid") or make_mid(args.serial or "%08X" % random.getrandbits(32))
    ts = int(time.time())
    body = {"mid": mid, **DEVICE, "sdkversion": SDK_VERSION, "appversion": APP_VERSION,
            "version": args.version, "networkType": "WIFI",
            "timestamp": ts, "sign": sign(f"{mid}{pid}{ts}", psec)}
    r = post(f"{BASE}/register/{pid}", body, log)
    data = r.get("data") if isinstance(r.get("data"), dict) else {}
    if r.get("status") != 1000 or not data.get("deviceId") or not data.get("deviceSecret"):
        sys.exit(f"register failed: {json.dumps(r)[:500]}")
    st.update(productId=pid, mid=mid, deviceId=data["deviceId"],
              deviceSecret=data["deviceSecret"], registered=ts)
    print(f"registered mid={mid} deviceId={st['deviceId']}")


def check(st, version, pid, log):
    did, dsec = st["deviceId"], st["deviceSecret"]
    ts = int(time.time())
    body = {"mid": st["mid"], "version": version, "networkType": "WIFI",
            "timestamp": ts, "sign": sign(f"{did}{pid}{ts}", dsec)}
    return post(f"{BASE}/product/{pid}/{did}/ota/checkVersion", body, log)


def head(url):
    throttle()
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers)


def fetch_range(url, part, size):
    """Append to part from where it stops; one request, returns bytes now on disk."""
    have = os.path.getsize(part) if os.path.exists(part) else 0
    throttle()
    hdr = {"User-Agent": UA}
    if have:
        hdr["Range"] = f"bytes={have}-"         # same resume trick as the app's DownloadTask
    req = urllib.request.Request(url, headers=hdr)
    with urllib.request.urlopen(req, timeout=120) as r:
        if have and r.status != 206:
            have = 0                            # server ignored Range: start over
        with open(part, "r+b" if have else "wb") as f:
            f.seek(have)
            f.truncate()
            done, t0 = have, time.monotonic()
            while done < size:
                b = r.read(1 << 20)
                if not b:
                    break
                f.write(b)
                done += len(b)
                if sys.stderr.isatty():
                    rate = (done - have) / max(time.monotonic() - t0, 1e-3) / 1e6
                    print(f"\r{done / 1e6:9.1f} / {size / 1e6:.1f} MB  {rate:5.2f} MB/s",
                          end="", file=sys.stderr)
    return done


def download(url, dest, size, md5, sha=""):
    part = dest + ".part"
    if os.path.exists(dest) and os.path.getsize(dest) == size:
        print(f"{dest} already there")
    else:
        # the CDN (iotdown-qn) drops long transfers: resume a few times before giving up
        for attempt in range(12):
            try:
                if fetch_range(url, part, size) >= size:
                    break
            except (OSError, http.client.HTTPException) as e:
                print(f"\n{type(e).__name__}: {e}", file=sys.stderr)
            print(f"\nconnection ended early, resuming ({attempt + 1})", file=sys.stderr)
            time.sleep(min(60, 5 * (attempt + 1)))
        print(file=sys.stderr)
        got = os.path.getsize(part) if os.path.exists(part) else 0
        if got != size:
            sys.exit(f"{part}: got {got} bytes, want {size}; rerun to resume")
        os.replace(part, dest)
    # the "sha" field is SHA-1 on older offers and SHA-256 on newer ones: go by length
    algo = {40: "sha1", 64: "sha256"}.get(len(sha))
    if sha and not algo:
        sys.exit(f"unknown hash in the offer: {sha}")
    h, h2 = hashlib.md5(), hashlib.new(algo or "sha256")
    with open(dest, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
            h2.update(b)
    if h.hexdigest() != md5.lower():
        sys.exit(f"{dest}: md5 {h.hexdigest()} != {md5} (server); delete it and rerun")
    if sha and h2.hexdigest() != sha.lower():
        sys.exit(f"{dest}: {algo} {h2.hexdigest()} != {sha} (server); delete it and rerun")
    print(f"md5 OK {md5}" + (f", {algo} OK {sha}" if sha else "") + f"  {dest}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("action", choices=["check", "fetch"])
    ap.add_argument("--version", default=DEFAULT_VERSION,
                    help="firmware version to claim (ro.fota.version), default %(default)s")
    ap.add_argument("--follow", action="store_true",
                    help="keep claiming the offered version until the server has nothing newer "
                         "(the server hands out one delta per step, e.g. 1.80 -> 1.90 -> 2.10)")
    ap.add_argument("--serial", help="serial for the mid on first registration (default: random)")
    ap.add_argument("--state", default=os.path.join(
        os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
        "hiby-rs6-fota", "device.json"), help="registration cache, default %(default)s")
    ap.add_argument("--dump", help="your EDL dump zip; productId/secret are read from "
                    "Abupdate.apk in its system image")
    ap.add_argument("--slot", default="b", help="dump slot to read (default %(default)s)")
    ap.add_argument("--apk", help="read productId/secret from this Abupdate.apk instead")
    ap.add_argument("-o", "--outdir", default=".", help="download directory")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    log = os.path.join(args.outdir, "server-replies.log")
    st = load_state(args.state)
    if not st.get("deviceSecret"):
        if args.apk:
            pid, psec = apk_product(args.apk)
        elif args.dump:
            import tempfile
            with tempfile.TemporaryDirectory() as w:
                apk = os.path.join(w, "Abupdate.apk")
                dump_apk(args.dump, args.slot, apk)
                pid, psec = apk_product(apk)
        else:
            sys.exit("first run: give --dump <EDL dump zip> or --apk <Abupdate.apk> so the "
                     "product id/secret can be read from your firmware")
        register(st, args, pid, psec, log)
        save_state(args.state, st)
    pid = st["productId"]

    version, hops = args.version, 0
    while True:
        offer = check_once(st, args, pid, version, log)
        if offer is None:
            if not hops:
                sys.exit(f"the server offers nothing for {version}")
            print(f"{version} is the newest the server knows")
            return
        hops += 1
        if args.action == "fetch":
            name = f"rs6-ota-{version}-to-{offer['versionName']}.zip"
            download(offer["url"], os.path.join(args.outdir, name), offer["size"], offer["md5"],
                     offer["sha"])
        if not args.follow:
            return
        version = offer["versionName"]
        print()


def check_once(st, args, pid, version, log):
    r = check(st, version, pid, log)
    if r.get("status") == 2101:               # "No new updates were found"
        return None
    if r.get("status") in (2001, 2103):       # PostRequest.b(): server forgot the device
        sys.exit(f"server says the registration is gone (status {r['status']}); "
                 f"delete {args.state} to register again")
    if r.get("status") != 1000:
        sys.exit(f"checkVersion: {json.dumps(r, ensure_ascii=False)[:800]}")
    data = r.get("data") or {}
    safe = maybe_json(data.get("safe")) or {}
    if isinstance(safe, dict) and safe.get("isEncrypt"):
        print(f"warning: server marks the package encrypted (safe={safe}); not handled",
              file=sys.stderr)
    ver = maybe_json(data.get("version")) or {}
    notes = maybe_json(data.get("releaseNotes")) or {}
    if not isinstance(ver, dict) or not ver.get("deltaUrl"):
        print(json.dumps(r, ensure_ascii=False, indent=1))
        sys.exit("no package in the reply")
    offer = {"versionName": ver.get("versionName"), "url": ver["deltaUrl"],
             "size": int(ver.get("fileSize", 0)),
             "md5": str(ver.get("md5sum", "")).rjust(32, "0"),  # VersionInfo zero-pads it
             "sha": ver.get("sha") or ""}   # SHA-1 (1.90 offer) or SHA-256 (2.10 offer)
    print(f"claimed version : {version}")
    print(f"offered version : {offer['versionName']}  (deltaID {ver.get('deltaID')})")
    if isinstance(notes, dict) and notes.get("publishDate"):
        print(f"published       : {notes.get('publishDate')}")
    print(f"url             : {offer['url']}")
    print(f"size            : {offer['size']}")
    print(f"md5             : {offer['md5']}")
    if offer["sha"]:
        print(f"sha             : {offer['sha']}")
    with open(os.path.join(args.outdir, f"offer-{version}.json"), "w") as f:
        json.dump(r, f, indent=1, ensure_ascii=False)
    code, hdrs = head(offer["url"])
    clen = hdrs.get("Content-Length")
    print(f"HEAD            : {code}, Content-Length {clen}, "
          f"Accept-Ranges {hdrs.get('Accept-Ranges')}")
    if code != 200 or (clen and int(clen) != offer["size"]):
        sys.exit("package URL does not match the offer")
    return offer

if __name__ == "__main__":
    main()
