"""Fixture tests for build_release_assets.py and publish-release.sh."""

import hashlib
import io
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

import build_release_assets as bra

HERE = Path(__file__).resolve().parent
COMMIT = "a" * 40
TAG = "v9.9.9-next.1"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def make_tar(path: Path, tui_name: str, tui: bytes, claimed: bytes | None = None):
    build = json.dumps({"tui_binary": tui_name,
                        "tui_binary_sha256": sha(claimed if claimed is not None else tui)}).encode()
    with tarfile.open(path, "w:gz") as tf:
        for name, data in ((tui_name, tui), ("build.json", build)):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))


def make_zip(path: Path, tui_name: str, tui: bytes):
    build = json.dumps({"tui_binary": tui_name, "tui_binary_sha256": sha(tui)})
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr(tui_name, tui)
        zf.writestr("build.json", build)


def fixture(root: Path, cli=("linux", "macos", "windows"),
            desktop=("linux", "macos", "windows"), bad_linux_tui=False) -> Path:
    """Build CI-artifact fixtures. Unlisted platforms have no files at all."""
    assets = root / "release-assets"
    assets.mkdir()
    if "linux" in cli:
        make_tar(assets / "veasel-Linux.tar.gz", "veasel-tui", b"linux-tui",
                 claimed=b"other" if bad_linux_tui else None)
    if "macos" in cli:
        make_tar(assets / "veasel-macOS.tar.gz", "veasel-tui", b"mac-tui")
    if "windows" in cli:
        make_zip(assets / "veasel-Windows.zip", "veasel-tui.exe", b"win-tui")
    # Loose, unverified TUI from a merged artifact must never be uploaded.
    (assets / "veasel-tui").write_bytes(b"WRONG-LOOSE-BINARY")
    names = {"linux": ("veasel-desktop-1.AppImage", "veasel-desktop-1.deb"),
             "macos": ("veasel-desktop-1.dmg",),
             "windows": ("veasel-desktop-1.exe",)}
    for platform in desktop:
        for name in names[platform]:
            (assets / name).write_bytes(name.encode())
    return assets


def res(**kw):
    base = {"linux": "", "macos": "", "windows": ""}
    base.update(kw)
    return base


ALL_OK = res(linux="success", macos="success", windows="success")


def stage(root, assets, cli=ALL_OK, lanes=ALL_OK):
    out = root / "release-upload"
    manifest = bra.stage(assets, out, TAG, "9.9.9-next.1", COMMIT, cli, lanes)
    return out, manifest


class StageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def notes(self):
        return (self.root / "RELEASE_NOTES.md").read_text()

    def assert_sums_cover(self, out, manifest):
        listed = [line.split("  ")[1] for line in (out / "SHA256SUMS").read_text().splitlines()]
        uploaded = sorted(p.name for p in out.iterdir() if p.name != "SHA256SUMS")
        self.assertEqual(sorted(listed), uploaded)
        subprocess.run(["sha256sum", "--check", "SHA256SUMS"], cwd=out, check=True,
                       capture_output=True)
        # Every manifest asset is uploaded and vice versa (release.json itself aside).
        self.assertEqual(sorted(a["name"] for a in manifest["assets"]),
                         [n for n in uploaded if n != "release.json"])

    def test_all_three_complete(self):
        out, manifest = stage(self.root, fixture(self.root))
        self.assertEqual({a["name"] for a in manifest["assets"]}, {
            "veasel-Linux.tar.gz", "veasel-macOS.tar.gz", "veasel-Windows.zip",
            "veasel-tui", "veasel-tui.exe", "veasel-desktop-1.AppImage",
            "veasel-desktop-1.deb", "veasel-desktop-1.dmg", "veasel-desktop-1.exe"})
        self.assertEqual(manifest["desktop"]["status"], "available")
        for p in ("linux", "macos", "windows"):
            self.assertEqual(manifest["platforms"][p]["status"], "published")
            self.assertEqual(manifest["platforms"][p]["desktop"]["status"], "published")
            self.assertIs(manifest["platforms"][p]["desktop"]["signed"], False)
        for a in manifest["assets"]:
            self.assertEqual(set(a) - {"signed"}, {"name", "size", "sha256", "platform", "arch", "kind"})
            self.assertEqual(a["size"], (out / a["name"]).stat().st_size)
            self.assertEqual(a["sha256"], sha((out / a["name"]).read_bytes()))
            self.assertEqual("signed" in a, a["kind"] == "desktop-installer")
        self.assertEqual((out / "veasel-tui").read_bytes(), b"linux-tui")
        self.assert_sums_cover(out, manifest)
        self.assertIn("UNSIGNED", self.notes())
        self.assertNotIn("Not included", self.notes())

    def test_linux_only(self):
        # macOS/Windows never reported (runner capacity) or failed; their stale
        # artifacts, if any, must not leak in.
        assets = fixture(self.root, cli=("linux", "windows"), desktop=("linux", "windows"))
        out, manifest = stage(self.root, assets,
                              cli=res(linux="success", windows="failure"),
                              lanes=res(linux="success", windows="skipped"))
        self.assertEqual({p.name for p in out.iterdir()}, {
            "veasel-Linux.tar.gz", "veasel-tui", "veasel-desktop-1.AppImage",
            "veasel-desktop-1.deb", "release.json", "SHA256SUMS"})
        pl = manifest["platforms"]
        self.assertEqual(pl["linux"]["status"], "published")
        self.assertEqual(pl["macos"]["status"], "unavailable")
        self.assertEqual(pl["macos"]["ci_result"], "none")
        self.assertEqual(pl["windows"]["status"], "failed")
        self.assertEqual(pl["windows"]["ci_result"], "failure")
        self.assertEqual(pl["windows"]["desktop"]["status"], "unavailable")
        self.assertEqual(manifest["desktop"]["status"], "partial")
        notes = self.notes()
        self.assertIn("Included platforms: Linux.", notes)
        self.assertIn("macOS CLI: unavailable", notes)
        self.assertIn("Windows CLI: failed", notes)
        self.assertIn("Windows Desktop: unavailable", notes)
        self.assert_sums_cover(out, manifest)

    def test_linux_plus_windows(self):
        assets = fixture(self.root, cli=("linux", "windows"), desktop=("linux", "windows"))
        out, manifest = stage(self.root, assets,
                              cli=res(linux="success", windows="success", macos="cancelled"),
                              lanes=res(linux="success", windows="success", macos="skipped"))
        self.assertIn("veasel-tui.exe", {p.name for p in out.iterdir()})
        self.assertEqual(manifest["platforms"]["macos"]["status"], "cancelled")
        self.assertIn("Included platforms: Linux, Windows.", self.notes())
        self.assertIn("macOS CLI: cancelled", self.notes())
        self.assert_sums_cover(out, manifest)

    def test_desktop_partial_per_lane(self):
        out, manifest = stage(self.root, fixture(self.root),
                              lanes=res(linux="success", macos="failure", windows="cancelled"))
        names = {p.name for p in out.iterdir()}
        self.assertIn("veasel-desktop-1.AppImage", names)
        self.assertNotIn("veasel-desktop-1.dmg", names)   # stale file present, not attached
        self.assertNotIn("veasel-desktop-1.exe", names)
        d = manifest["platforms"]
        self.assertEqual(d["macos"]["desktop"]["status"], "failed")
        self.assertEqual(d["windows"]["desktop"]["status"], "cancelled")
        self.assertEqual(manifest["desktop"]["status"], "partial")
        self.assertIn("macOS Desktop: failed", self.notes())
        self.assertIn("UNSIGNED", self.notes())
        self.assert_sums_cover(out, manifest)

    def test_no_desktop_at_all_has_no_unsigned_claim_of_inclusion(self):
        out, manifest = stage(self.root, fixture(self.root, desktop=()),
                              lanes=res(linux="failure", macos="failure", windows="failure"))
        self.assertEqual(manifest["desktop"]["status"], "unavailable")
        self.assertFalse([a for a in manifest["assets"] if a["kind"] == "desktop-installer"])
        self.assertNotIn("UNSIGNED", self.notes())
        self.assertIn("Linux Desktop: failed", self.notes())

    def test_linux_must_succeed(self):
        for bad in ("failure", "cancelled", "skipped", ""):
            with self.subTest(bad=bad):
                root = self.root / (bad or "empty")
                root.mkdir()
                with self.assertRaises(bra.ReleaseError):
                    stage(root, fixture(root), cli=res(linux=bad, macos="success", windows="success"))

    def test_claimed_success_without_archive_fails(self):
        with self.assertRaises(bra.ReleaseError):
            stage(self.root, fixture(self.root, cli=("linux", "windows")))

    def test_desktop_success_without_installers_fails(self):
        with self.assertRaises(bra.ReleaseError):
            stage(self.root, fixture(self.root, desktop=("linux", "macos")))

    def test_tui_provenance_mismatch_fails(self):
        with self.assertRaises(bra.ReleaseError):
            stage(self.root, fixture(self.root, bad_linux_tui=True))

    def test_parse_results(self):
        self.assertEqual(bra.parse_results("linux=success,windows=", "x"),
                         {"linux": "success", "macos": "", "windows": ""})
        with self.assertRaises(bra.ReleaseError):
            bra.parse_results("beos=success", "x")


FAKE_GH = r'''#!/usr/bin/env python3
import base64, json, os, sys
from pathlib import Path
state_path = Path(os.environ["FAKE_GH_STATE"])
state = json.loads(state_path.read_text())
args = sys.argv[1:]
def save(): state_path.write_text(json.dumps(state))
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
if args[0] == "release" and args[1] == "create":
    tag = args[2]
    files = [a for i, a in enumerate(args[3:], 3) if os.path.isfile(a) and args[i-1] != '--notes-file']
    rel = {"id": 100 + len(state["releases"]), "tag_name": tag, "draft": True,
           "target_commitish": args[args.index("--target") + 1], "assets": {}}
    for i, f in enumerate(files):
        rel["assets"][str(rel["id"] * 100 + i)] = {"name": os.path.basename(f),
            "data": base64.b64encode(Path(f).read_bytes() if not os.environ.get("FAKE_CORRUPT") else b"x").decode()}
    state["releases"].append(rel); save(); sys.exit(0)
if args[0] != "api": sys.exit("unsupported " + " ".join(args))
rest = args[1:]
if "-X" in rest:
    method = rest[rest.index("-X") + 1]; url = [a for a in rest if a.startswith("repos/")][0]
    rid = int(url.split("/releases/")[1].split("/")[0])
    if method == "DELETE":
        state["releases"] = [r for r in state["releases"] if r["id"] != rid]
    else:
        next(r for r in state["releases"] if r["id"] == rid)["draft"] = False
    save(); sys.exit(0)
url = [a for a in rest if a.startswith("repos/")][0]
if url.endswith("/assets"):
    rid = int(url.split("/releases/")[1].split("/")[0])
    rel = next(r for r in state["releases"] if r["id"] == rid)
    for aid, a in rel["assets"].items(): print(f"{aid}\t{a['name']}")
elif "/releases/assets/" in url:
    aid = url.rsplit("/", 1)[1]
    for r in state["releases"]:
        if aid in r["assets"]:
            sys.stdout.buffer.write(base64.b64decode(r["assets"][aid]["data"]))
else:
    jq = rest[rest.index("--jq") + 1]
    for r in state["releases"]:
        if r["tag_name"] != os.environ["RELEASE_TAG"]: continue
        if ".draft == true" in jq:
            if r["draft"]: print(r["id"])
        else:
            print(f"{r['id']}\t{str(r['draft']).lower()}\t{r['target_commitish']}")
'''


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.root = Path(self.tmp.name)
        self.out, _ = stage(self.root, fixture(self.root))
        bindir = self.root / "bin"
        bindir.mkdir()
        (bindir / "gh").write_text(FAKE_GH)
        (bindir / "gh").chmod(0o755)
        self.state = self.root / "state.json"
        self.state.write_text(json.dumps({"releases": []}))
        self.log = self.root / "gh.log"
        self.env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}",
                        FAKE_GH_STATE=str(self.state), FAKE_GH_LOG=str(self.log),
                        RELEASE_TAG=TAG, RELEASE_VERSION="9.9.9-next.1",
                        RELEASE_COMMIT=COMMIT, GH_REPO="o/r", RUNNER_TEMP=str(self.root))

    def tearDown(self):
        self.tmp.cleanup()

    def run_publish(self, **extra):
        return subprocess.run(
            ["bash", str(HERE / "publish-release.sh"), str(self.out), str(self.root / "RELEASE_NOTES.md")],
            env=dict(self.env, **extra), capture_output=True, text=True)

    def releases(self):
        return json.loads(self.state.read_text())["releases"]

    def test_fresh_publish_goes_draft_verify_publish_without_clobber(self):
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        (rel,) = self.releases()
        self.assertFalse(rel["draft"])
        log = self.log.read_text()
        self.assertIn("--draft", log)
        self.assertNotIn("--clobber", log)
        self.assertNotIn("release upload", log)

    def test_relative_upload_dir_works_like_ci(self):
        # CI calls `publish-release.sh release-upload RELEASE_NOTES.md` from the
        # workspace root. The script cd's into its download dir during
        # verification, so a relative path must be resolved up front.
        result = subprocess.run(
            ["bash", str(HERE / "publish-release.sh"), self.out.name, "RELEASE_NOTES.md"],
            cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        (rel,) = self.releases()
        self.assertFalse(rel["draft"])

    def test_rerun_same_assets_verifies_and_skips(self):
        self.assertEqual(self.run_publish().returncode, 0)
        self.log.write_text("")
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("nothing to do", result.stdout)
        self.assertNotIn("release create", self.log.read_text())
        self.assertNotIn("PATCH", self.log.read_text())

    def test_rerun_with_different_assets_fails_loudly(self):
        self.assertEqual(self.run_publish().returncode, 0)
        (self.out / "veasel-tui").write_bytes(b"rebuilt")  # non-identical rebuild
        # keep SHA256SUMS consistent with the rebuilt set
        sums = "".join(f"{sha((self.out / p.name).read_bytes())}  {p.name}\n"
                       for p in sorted(self.out.iterdir()) if p.name != "SHA256SUMS")
        (self.out / "SHA256SUMS").write_text(sums)
        result = self.run_publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to overwrite", result.stderr + result.stdout)

    def test_tag_points_at_other_commit_fails(self):
        self.assertEqual(self.run_publish().returncode, 0)
        result = self.run_publish(RELEASE_COMMIT="b" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("collision", result.stderr + result.stdout)

    def test_linux_only_set_publishes_and_rerun_skips(self):
        root = self.root / "lo"
        root.mkdir()
        self.out, _ = stage(root, fixture(root, cli=("linux",), desktop=("linux",)),
                            cli=res(linux="success"), lanes=res(linux="success"))
        self.assertEqual(self.run_publish().returncode, 0)
        again = self.run_publish()
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertIn("nothing to do", again.stdout)

    def test_short_sha_is_rejected(self):
        result = self.run_publish(RELEASE_COMMIT=COMMIT[:7])
        self.assertNotEqual(result.returncode, 0)

    def test_short_sha_on_existing_release_is_not_a_match(self):
        self.state.write_text(json.dumps({"releases": [{
            "id": 5, "tag_name": TAG, "draft": False,
            "target_commitish": COMMIT[:7], "assets": {}}]}))
        result = self.run_publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("collision", result.stderr + result.stdout)

    def test_corrupted_upload_is_never_published(self):
        result = self.run_publish(FAKE_CORRUPT="1")
        self.assertNotEqual(result.returncode, 0)
        (rel,) = self.releases()
        self.assertTrue(rel["draft"])

    def test_leftover_draft_is_replaced(self):
        self.state.write_text(json.dumps({"releases": [{
            "id": 5, "tag_name": TAG, "draft": True,
            "target_commitish": COMMIT, "assets": {}}]}))
        self.assertEqual(self.run_publish().returncode, 0)
        (rel,) = self.releases()
        self.assertFalse(rel["draft"])

    def test_inconsistent_sums_rejected_before_any_gh_call(self):
        (self.out / "stray.bin").write_bytes(b"x")
        result = self.run_publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
