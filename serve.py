r"""Start the whole backend with one command.

    ..\..\.venv\Scripts\python.exe serve.py

Brings up two processes on one machine, one GPU and one interpreter:

    vlm/service.py         ->  127.0.0.1:8001   Qwen3-VL-4B, the advisory note
    main.py                ->  127.0.0.1:8000   RF-DETR, rules, dashboard

Two processes rather than one app, deliberately. A 4B model that OOMs or
wedges must not take the detector with it -- `assess.py` turns any VLM failure
into {"status": "disabled"} and the capture still gets a full verdict. That is
not theoretical: it is exactly what happened the morning the GPU disappeared
out from under the VLM, and it is why there was still something to demo.

What this script adds over two terminals is that every setting lives in ONE
place, both logs are prefixed and interleaved, and Ctrl+C stops both. The env
vars below were previously retyped into two shells, which is how a capture
ends up judged under a threshold nobody meant to set.

The VLM is started first and given a head start -- it loads ~8 GB -- but the
server is NOT blocked on it. If the VLM never comes up, captures still work
and simply carry no assessment.

    serve.py --no-vlm         detector only, skip the VLM entirely
    serve.py --ckpt <path>    a different checkpoint
    serve.py --host 0.0.0.0   bind wider (default is localhost + cloudflared)
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent      # weldz-server, and the repo root
APP = HERE.parent                           # weldz-app
REPO = APP.parent                           # the working tree above it

SERVER_DIR = HERE
VLM_DIR = HERE / "vlm"

# The interpreter running this script runs both children. That is the whole
# point of the consolidation: one venv with rfdetr, torch+cu128, transformers,
# fastapi and accelerate, rather than one per operating system.
PYTHON = sys.executable

# The checkpoint beside main.py wins when it is there -- that is what
# model.py itself defaults to, and it is the only one a fresh clone of this
# repo can rely on. The training run is the fallback for this machine, where
# the two are the same bytes.
LOCAL_CKPT = HERE / "checkpoint_best_ema.pth"
TRAINED_CKPT = (REPO / "train" / "rfdetr" / "runs" /
                "rfdetr_seg_small_1272" / "checkpoint_best_ema.pth")
DEFAULT_CKPT = LOCAL_CKPT if LOCAL_CKPT.exists() else TRAINED_CKPT

# Not left to the default. `store.ROOT` falls back to Path(""), which resolves
# to the CURRENT DIRECTORY -- so an unset value scatters day-folders wherever
# uvicorn happened to be launched, and the dashboard finds nothing.
# weldz-app/captures, NOT weldz-server/captures. Both exist on this machine:
# the second is the accident that happens when WELDZ_CAPTURES is unset, since
# store.ROOT then falls back to the current directory.
DEFAULT_CAPTURES = APP / "captures"

# The phone sends these itself; these are the fallback for an older build, and
# the reason a capture is turned before inference at all. See frame.py.
DEFAULT_ROTATE = "270"
DEFAULT_CROP = "1380"


def pump(stream, tag: str, colour: str) -> None:
    """Forward a child's output with a prefix, so two logs in one terminal can
    still be told apart at a glance."""
    reset = "\033[0m"
    for line in iter(stream.readline, ""):
        sys.stdout.write(f"{colour}{tag}{reset} {line}")
        sys.stdout.flush()
    stream.close()


def spawn(name: str, cwd: Path, args: list[str], env: dict,
          tag: str, colour: str) -> subprocess.Popen:
    print(f"  starting {name}: {' '.join(args)}")
    proc = subprocess.Popen(
        args,
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        # Children get their own group so our Ctrl+C handler can shut them
        # down in order rather than the console killing all three at once and
        # leaving a half-written capture.
        creationflags=(subprocess.CREATE_NEW_PROCESS_GROUP
                       if os.name == "nt" else 0),
    )
    threading.Thread(target=pump, args=(proc.stdout, tag, colour),
                     daemon=True).start()
    return proc


def stop(procs: list[tuple[str, subprocess.Popen]]) -> None:
    """Ask, then insist. A wedged model can ignore the first signal, and the
    port stays bound until the process is actually gone."""
    for name, p in reversed(procs):
        if p.poll() is not None:
            continue
        print(f"  stopping {name}")
        try:
            if os.name == "nt":
                p.send_signal(signal.CTRL_BREAK_EVENT)
            else:
                p.terminate()
        except Exception:                                          # noqa: BLE001
            pass

    deadline = time.time() + 12
    for name, p in reversed(procs):
        while p.poll() is None and time.time() < deadline:
            time.sleep(0.2)
        if p.poll() is None:
            print(f"  {name} did not stop; killing")
            p.kill()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--vlm-port", type=int, default=8001)
    ap.add_argument("--no-vlm", action="store_true",
                    help="detector only; captures carry no assessment")
    ap.add_argument("--ckpt", default=str(DEFAULT_CKPT))
    ap.add_argument("--captures", default=str(DEFAULT_CAPTURES))
    ap.add_argument("--rotate", default=DEFAULT_ROTATE)
    ap.add_argument("--crop", default=DEFAULT_CROP)
    ap.add_argument("--conf", default=None,
                    help="server-side threshold fallback; the app sends its own")
    ap.add_argument("--hf-home", default=os.environ.get("HF_HOME"),
                    help="where the VLM weights live; keeps them off C:")
    args = ap.parse_args()

    ckpt = Path(args.ckpt)
    if not ckpt.exists():
        raise SystemExit(f"checkpoint not found: {ckpt}\n"
                         f"pass --ckpt, or train one into "
                         f"{DEFAULT_CKPT.parent}")

    # Checked here rather than left to two separate failures later: both
    # children need CUDA, and finding out after an 8 GB load is a poor trade.
    try:
        import torch
        if not torch.cuda.is_available():
            raise SystemExit(
                f"no CUDA device for {PYTHON}\n"
                f"  torch {torch.__version__}, built with cuda="
                f"{torch.version.cuda}\n"
                f"A '+cpu' build reports False no matter what the driver does "
                f"-- check you are using the venv, not the system python.")
        print(f"  gpu: {torch.cuda.get_device_name(0)}")
    except ImportError:
        raise SystemExit(f"torch is not installed for {PYTHON}")

    base = os.environ.copy()
    if args.hf_home:
        base["HF_HOME"] = args.hf_home

    procs: list[tuple[str, subprocess.Popen]] = []
    vlm_url = ""

    print(f"\nweldz backend\n  python: {PYTHON}")

    if not args.no_vlm:
        if not (VLM_DIR / "service.py").exists():
            raise SystemExit(f"no service.py in {VLM_DIR}")
        vlm_env = dict(base)
        procs.append(("vlm", spawn(
            "vlm", VLM_DIR,
            [PYTHON, "-m", "uvicorn", "service:app",
             "--host", "127.0.0.1", "--port", str(args.vlm_port)],
            vlm_env, "[vlm]   ", "\033[35m")))
        vlm_url = f"http://127.0.0.1:{args.vlm_port}"
        # A head start, not a gate. The server tolerates the VLM being absent,
        # so blocking here would trade a working detector for a nicer log.
        time.sleep(2)

    server_env = dict(base)
    server_env.update({
        "WELDZ_CKPT": str(ckpt),
        "WELDZ_CAPTURES": str(Path(args.captures)),
        "WELDZ_ROTATE": str(args.rotate),
        "WELDZ_CROP": str(args.crop),
    })
    if vlm_url:
        server_env["WELDZ_VLM_URL"] = vlm_url
    else:
        # Explicitly cleared: a stale value in the shell would make the server
        # wait on a service this run deliberately did not start.
        server_env.pop("WELDZ_VLM_URL", None)
    if args.conf:
        server_env["WELDZ_CONF"] = str(args.conf)

    procs.append(("server", spawn(
        "server", SERVER_DIR,
        [PYTHON, "-m", "uvicorn", "main:app",
         "--host", args.host, "--port", str(args.port)],
        server_env, "[server]", "\033[36m")))

    print(f"\n  checkpoint : {ckpt.name}")
    print(f"  captures   : {server_env['WELDZ_CAPTURES']}")
    print(f"  geometry   : rotate {args.rotate}, crop {args.crop}")
    print(f"  assessment : {vlm_url or 'off (--no-vlm)'}")
    print(f"\n  dashboard  : http://{args.host}:{args.port}/")
    print(f"  tunnel     : cloudflared tunnel --url "
          f"http://localhost:{args.port}\n")
    print("  Ctrl+C stops both.\n")

    try:
        while True:
            for name, p in procs:
                code = p.poll()
                if code is not None:
                    # The server dying is fatal; the VLM dying is not, and
                    # saying which is which saves a panic mid-demo.
                    if name == "server":
                        print(f"\n  server exited ({code}) -- stopping")
                        stop(procs)
                        raise SystemExit(code or 1)
                    print(f"\n  {name} exited ({code}). Captures continue "
                          f"without an assessment.")
                    procs = [(n, q) for n, q in procs if n != name]
            time.sleep(0.4)
    except KeyboardInterrupt:
        print("\n  shutting down")
        stop(procs)


if __name__ == "__main__":
    main()
