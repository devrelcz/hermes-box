# Runs several hermes CLI commands in one Python process, inside the Hermes
# image. A `hermes ...` started on its own spends 4 to 10 seconds importing
# Hermes before it does anything, and install.sh and setup.sh used to start
# about twenty of them: a minute of a new server's setup. lib/hermes.sh runs
# this file; see hermes_batch there.
#
# stdin:  one command per line, without the leading "hermes", its arguments
#         quoted the way a POSIX shell would read them
# stdout: a JSON array with one object per command, in order:
#         {"line": <the line as given>, "code": <exit code>, "out": <stdout>,
#          "err": <stderr>, "seconds": <how long it took>}
#
# A command that fails does not stop the ones after it. Anything printed
# outside a command (warnings while Hermes loads) goes to stderr, so that
# stdout stays valid JSON.
import contextlib
import glob
import io
import json
import os
import shlex
import site
import sys
import time


def run(hermes_main, line: str) -> dict:
    started = time.monotonic()
    out, err = io.StringIO(), io.StringIO()
    sys.argv = ["hermes", *shlex.split(line)]
    code = 0
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            result = hermes_main()
            code = result if isinstance(result, int) else 0
        except SystemExit as exc:
            code = exc.code if isinstance(exc.code, int) else (0 if exc.code is None else 1)
        except Exception as exc:  # one broken command must not lose the others' results
            code = 1
            print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
    return {"line": line, "code": code, "out": out.getvalue(), "err": err.getvalue(),
            "seconds": round(time.monotonic() - started, 2)}


def main() -> None:
    lines = [line for line in sys.stdin.read().splitlines() if line.strip()]

    # What /opt/hermes/.venv/bin/hermes sets up before it starts the CLI.
    root = "/opt/hermes"
    os.chdir(root)
    sys.path.insert(0, root)
    for packages in glob.glob(f"{root}/.venv/lib/python3*/site-packages"):
        os.environ.setdefault("HERMES_SITE", packages)
        site.addsitedir(packages)

    # The results go out on the real stdout; everything else that would
    # write there (including child processes) writes to stderr instead.
    results_out = os.fdopen(os.dup(1), "w")
    os.dup2(2, 1)
    sys.stdout = sys.stderr

    from hermes_cli.main import main as hermes_main

    results = [run(hermes_main, line) for line in lines]
    json.dump(results, results_out)
    results_out.write("\n")
    results_out.flush()


if __name__ == "__main__":
    main()
