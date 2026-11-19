#!/usr/bin/env python3
"""Download one reference file, verify it, and optionally unpack it into OUTDIR.

    fetch_reference.py --url URL --filename NAME --outdir DIR
                       [--md5 HEX] [--sha256 HEX] [--require-checksum]
                       [--unpack none|tar] [--keep-archive]

The file is streamed to OUTDIR/NAME while MD5 and SHA-256 are computed, so verifying a
multi-GB database costs no second read. Every checksum given must match, otherwise the
file is deleted and the script exits non-zero. With --require-checksum, a run without
any expected checksum is refused.

--unpack tar extracts the verified archive into OUTDIR with the system `tar` (faster than
Python's tarfile for 10+ GB archives) and removes the archive unless --keep-archive.

Whatever happens, OUTDIR/SOURCE.json records the URL, size, both observed checksums and
which of them were checked against an expected value, so an unpinned download can be
pinned afterwards by copying its sha256 into the manifest.

Standard library only, compatible with Python >= 3.6: the same script also runs inside
the InterProScan container, whose Python version is not ours to choose.
"""

import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.request

CHUNK = 8 * 1024 * 1024
USER_AGENT = "nf-meta-showcases-fetch-references/1.0"


def download(url, dest, attempts=30, timeout=120, backoff=5):
    """Stream url to dest; return (bytes, md5, sha256).

    Some servers drop long transfers without an HTTP error (download.cathdb.info cuts
    FunFam's 1.4 GB after a few MB), so a clean end of stream is not trusted: the byte
    count must reach the Content-Length. A short transfer is resumed with an HTTP Range
    request, the hashes carrying on over the appended bytes; a server that ignores the
    range (200 instead of 206) restarts the download from zero.
    """
    md5, sha256, size, total = hashlib.md5(), hashlib.sha256(), 0, None
    last = None
    with open(dest, "wb") as out:
        for attempt in range(1, attempts + 1):
            headers = {"User-Agent": USER_AGENT}
            if size:
                headers["Range"] = "bytes={}-".format(size)
            try:
                req = urllib.request.Request(url, headers=headers)
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    status = getattr(resp, "status", None) or 200  # file:// has no status
                    if size and status != 206:
                        print("server ignored the range request, restarting", file=sys.stderr)
                        out.seek(0)
                        out.truncate()
                        md5, sha256, size = hashlib.md5(), hashlib.sha256(), 0
                    length = resp.headers.get("Content-Length")
                    if total is None and length is not None and status == 200:
                        total = int(length)
                    while True:
                        try:
                            block = resp.read(CHUNK)
                        except Exception as exc:  # e.g. http.client.IncompleteRead
                            last = exc
                            break
                        if not block:
                            break
                        out.write(block)
                        md5.update(block)
                        sha256.update(block)
                        size += len(block)
                if total is None or size == total:
                    return size, md5.hexdigest(), sha256.hexdigest()
                if size > total:
                    raise SystemExit("{}: received {} bytes, more than Content-Length {}".format(url, size, total))
                last = last or "transfer ended at {} of {} bytes".format(size, total)
            except SystemExit:
                raise
            except Exception as exc:  # network errors of every kind: retry, then give up
                last = exc
            print("attempt {}/{}: {} ({} of {} bytes so far)".format(
                attempt, attempts, last, size, total if total is not None else "?"), file=sys.stderr)
            last = None
            time.sleep(min(60, backoff * attempt))
    raise SystemExit("download failed after {} attempts: {}".format(attempts, url))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    if argv is None and sys.argv[1:] == ["--selftest"]:
        return selftest()
    p.add_argument("--url", required=True)
    p.add_argument("--filename", required=True)
    p.add_argument("--outdir", required=True)
    p.add_argument("--md5", default="")
    p.add_argument("--sha256", default="")
    p.add_argument("--require-checksum", action="store_true")
    p.add_argument("--unpack", choices=["none", "tar"], default="none")
    p.add_argument("--keep-archive", action="store_true")
    a = p.parse_args(argv)
    return fetch(a)


def fetch(a):
    expected = {k: v.strip().lower() for k, v in (("md5", a.md5), ("sha256", a.sha256)) if v and v.strip() not in ("", "-")}
    if a.require_checksum and not expected:
        raise SystemExit(
            "{}: no md5 or sha256 in the manifest and --require-checksum is set. Run once "
            "with require_checksums false, then copy the sha256 from SOURCE.json / "
            "references.tsv into the manifest.".format(a.filename)
        )

    os.makedirs(a.outdir, exist_ok=True)
    dest = os.path.join(a.outdir, a.filename)
    size, md5, sha256 = download(a.url, dest)
    observed = {"md5": md5, "sha256": sha256}

    mismatched = {k: (v, observed[k]) for k, v in expected.items() if observed[k] != v}
    if mismatched:
        os.remove(dest)
        raise SystemExit(
            "{}: checksum mismatch -- {}. The file at {} is not the one this manifest pins.".format(
                a.filename,
                "; ".join("{} expected {} got {}".format(k, e, o) for k, (e, o) in mismatched.items()),
                a.url,
            )
        )
    if not expected:
        print("WARNING {}: no expected checksum, recorded sha256 {}".format(a.filename, sha256), file=sys.stderr)

    if a.unpack == "tar":
        subprocess.check_call(["tar", "-xf", dest, "-C", a.outdir, "--no-same-owner"])
        if not a.keep_archive:
            os.remove(dest)

    source = {
        "url": a.url,
        "filename": a.filename,
        "bytes": size,
        "md5": md5,
        "sha256": sha256,
        "verified": sorted(expected),
        "unpacked": a.unpack,
        "archive_kept": a.unpack == "none" or a.keep_archive,
        "downloaded": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    }
    with open(os.path.join(a.outdir, "SOURCE.json"), "w") as fh:
        json.dump(source, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print("{}: {} bytes, sha256 {}, verified: {}".format(a.filename, size, sha256, ", ".join(sorted(expected)) or "nothing"))


def selftest():
    """Local HTTP server that drops the first transfer of every file halfway, like
    download.cathdb.info does with FunFam, and honours Range requests."""
    import http.server
    import io
    import tarfile
    import tempfile
    import threading

    payload = os.urandom(3 * CHUNK + 12345)
    tar_buf = io.BytesIO()
    with tarfile.open(fileobj=tar_buf, mode="w:gz") as tf:
        info = tarfile.TarInfo("release/data/model.hmm")
        info.size = len(payload)
        tf.addfile(info, io.BytesIO(payload))
    files = {"/db.bin": payload, "/db.tar.gz": tar_buf.getvalue()}
    served = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            body = files[self.path]
            start = 0
            rng = self.headers.get("Range")
            if rng:
                start = int(rng.split("=")[1].rstrip("-"))
                self.send_response(206)
                self.send_header("Content-Range", "bytes {}-{}/{}".format(start, len(body) - 1, len(body)))
            else:
                self.send_response(200)
            self.send_header("Content-Length", str(len(body) - start))
            self.end_headers()
            first = served.setdefault(self.path, 0) == 0
            served[self.path] += 1
            chunk = body[start:]
            # first request: send half, then close without error, like a dropped transfer
            self.wfile.write(chunk[: len(chunk) // 2] if first else chunk)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:{}".format(server.server_address[1])
    good_md5 = hashlib.md5(payload).hexdigest()
    good_sha = hashlib.sha256(payload).hexdigest()

    with tempfile.TemporaryDirectory() as tmp:
        # dropped transfer is resumed with Range; bytes and both checksums come out exact
        size, md5, sha = download(base + "/db.bin", os.path.join(tmp, "x"), backoff=0)
        assert (size, md5, sha) == (len(payload), good_md5, good_sha), (size, md5)
        assert served["/db.bin"] == 2, served

        # a pinned checksum passes; SOURCE.json records what was verified
        out = os.path.join(tmp, "ok")
        main(["--url", base + "/db.bin", "--filename", "db.bin", "--outdir", out,
              "--sha256", good_sha, "--md5", good_md5, "--require-checksum"])
        src = json.load(open(os.path.join(out, "SOURCE.json")))
        assert src["verified"] == ["md5", "sha256"] and src["bytes"] == len(payload), src

        # a wrong checksum fails and leaves no file behind
        bad = os.path.join(tmp, "bad")
        try:
            main(["--url", base + "/db.bin", "--filename", "db.bin", "--outdir", bad, "--sha256", "0" * 64])
        except SystemExit as exc:
            assert "checksum mismatch" in str(exc), exc
        else:
            raise AssertionError("checksum mismatch not detected")
        assert not os.path.exists(os.path.join(bad, "db.bin"))

        # --require-checksum refuses an unpinned row
        try:
            main(["--url", base + "/db.bin", "--filename", "db.bin", "--outdir", bad, "--require-checksum"])
        except SystemExit as exc:
            assert "no md5 or sha256" in str(exc), exc
        else:
            raise AssertionError("unpinned row not refused")

        # tar: verified, unpacked, archive removed
        tar_sha = hashlib.sha256(files["/db.tar.gz"]).hexdigest()
        out = os.path.join(tmp, "tar")
        main(["--url", base + "/db.tar.gz", "--filename", "db.tar.gz", "--outdir", out,
              "--sha256", tar_sha, "--unpack", "tar"])
        with open(os.path.join(out, "release", "data", "model.hmm"), "rb") as fh:
            assert fh.read() == payload
        assert not os.path.exists(os.path.join(out, "db.tar.gz"))

    server.shutdown()
    print("selftest OK")


if __name__ == "__main__":
    main()
