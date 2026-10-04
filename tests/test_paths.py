import os
import shlex
import subprocess

import pytest

from app.files.paths import (PathError, check_local, check_remote, local_within, norm_local, norm_remote, q,
                             unique_name)
from app.files.transfer import RateMeter, eta_seconds

from .conftest import BASH

ROOTS = ["/home/u/compress/in", "/home/u/compress/out"]


@pytest.mark.parametrize("path", [
    "/home/u/compress/in", "/home/u/compress/in/a.mkv", "~/compress/out/x y/z.mkv",
    "/home/u/compress/in/./sub/../a.mkv",
])
def test_remote_allowed(path):
    assert check_remote(path, ROOTS, "/home/u").startswith("/home/u/compress/")


@pytest.mark.parametrize("path", [
    "/home/u/compress/in/../../.ssh/id_rsa", "/home/u/compress", "/home/u/compress/inbox",
    "/etc/passwd", "relative/a.mkv", "~/../other", "", "/home/u/compress/in/\x00x",
])
def test_remote_rejected(path):
    with pytest.raises(PathError):
        check_remote(path, ROOTS, "/home/u")


def test_norm_remote_tilde():
    assert norm_remote("~", "/home/u") == "/home/u"
    assert norm_remote("~/a//b/", "/home/u") == "/home/u/a/b"
    with pytest.raises(PathError):
        norm_remote("~/a", None)


def test_local_roots(tmp_path):
    root = tmp_path / "Movies"
    (root / "sub").mkdir(parents=True)
    other = tmp_path / "Movies2"
    other.mkdir()
    roots = [norm_local(str(root))]
    assert check_local(str(root / "sub"), roots).endswith("/Movies/sub")
    for bad in [str(root / ".." / "Movies2"), str(other), str(tmp_path), str(root) + "2"]:
        with pytest.raises(PathError):
            check_local(bad, roots)


def test_local_backslashes_and_case():
    if os.name != "nt":
        pytest.skip("Windows path semantics")
    assert norm_local("D:\\Movies\\a b\\x.mkv") == "D:/Movies/a b/x.mkv"
    assert local_within("d:/movies/A.mkv", "D:/Movies")
    assert not local_within("D:/MoviesX/a.mkv", "D:/Movies")
    assert norm_local("\\\\?\\D:\\Movies\\x.mkv") == "D:/Movies/x.mkv"


def test_local_junction_escape(tmp_path):
    """A link inside a root that points outside must be rejected."""
    root = tmp_path / "root"
    root.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    link = root / "link"
    try:
        if os.name == "nt":
            subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(outside)], check=True, capture_output=True)
        else:
            link.symlink_to(outside)
    except Exception:
        pytest.skip("cannot create junction/symlink")
    with pytest.raises(PathError):
        check_local(str(link), [norm_local(str(root))])


AWKWARD = ["movie (2019).mkv", "it's here.mkv", "한글 영화.mkv", "a\"b.mkv", "$(rm -rf ~).mkv",
           "back`tick`.mkv", "semi;colon & amp.mkv", "-dash-first.mkv", "new\nline.mkv", "*glob?.mkv"]


@pytest.mark.parametrize("name", AWKWARD)
def test_quote_roundtrip(name):
    assert shlex.split(f"cmd {q('/x/' + name)}") == ["cmd", "/x/" + name]


@pytest.mark.skipif(not BASH, reason="bash not available")
def test_quote_through_real_shell():
    script = "printf '%s\\0' " + " ".join(q(n) for n in AWKWARD)
    out = subprocess.run([BASH, "-c", script], capture_output=True, check=True).stdout
    assert out.decode("utf-8").split("\0")[:-1] == AWKWARD


def test_unique_name():
    names = {"a.mkv", "a (1).mkv"}
    assert unique_name("a.mkv", lambda n: n in names) == "a (2).mkv"
    assert unique_name("folder", lambda n: False) == "folder (1)"
    assert unique_name(".hidden", lambda n: False) == ".hidden (1)"


def test_rate_meter_window():
    m = RateMeter(window=5)
    assert m.speed() is None
    m.add(0, 0)
    m.add(1, 100)
    assert m.speed() == 100
    for t in range(2, 21):
        m.add(t, 100 + (t - 1) * 1000)  # 1000 B/s after t=1
    assert m.speed() == pytest.approx(1000)
    assert m.samples[0][0] >= 20 - 5 - 1


def test_rate_meter_stall_and_eta():
    m = RateMeter(window=5)
    m.add(0, 0)
    m.add(5, 5000)
    m.add(10, 5000)  # stalled for 5 s
    assert m.speed() == 0
    assert eta_seconds(1000, 0) is None
    assert eta_seconds(1000, None) is None
    assert eta_seconds(1000, 250) == 4
    assert eta_seconds(0, None) == 0
