"""Stelis read probe (st-25h) — observe what a Python task ACTUALLY opens.

Injected by prepending this directory to PYTHONPATH, so `site` imports it at
interpreter startup, before any task code runs, and it inherits into every
Python subprocess the task spawns (dbt included — dbt is Python, launched
through uvx). Active ONLY when STELIS_TRACE names a log path; otherwise this
module is a no-op, so a traced build and an untraced one differ by exactly one
environment variable.

TWO mechanisms, because neither covers the other (verified 2026-08-23):

  - `open` audit events give DATA reads: the file the task opened, at the
    moment it opened it.
  - a sys.modules sweep at exit gives CODE reads. The audit events cannot:
    with a warm __pycache__ the .py is NEVER opened, only the .pyc, and the
    `import` event carries no path at all (args[1] is None in practice,
    because it fires before the loader resolves a file). Recording the .pyc
    as a dependency would be a wrong-skip generator, not a fix for one.

KNOWN BLIND SPOT, by construction: a C extension calling open(2) itself is
invisible here — duckdb reading a parquet file produces ZERO open events. That
half of the read set is a SQL problem, not a syscall problem, and wants a
different instrument (st-25h, ladder step 1b).

Log format is one TSV record per line, appended, line-buffered so a crashing
task still leaves its reads behind:

    open<TAB><abspath><TAB><mode>
    module<TAB><dotted.name><TAB><abspath>
    probe<TAB><message>          -- the probe reporting on itself

The probe must NEVER break a task: every hook body swallows its own errors.
"""

import os
import sys

_LOG_PATH = os.environ.get("STELIS_TRACE")


def _install(log_path):
    log = open(log_path, "a", buffering=1)  # line-buffered: survives a crash

    def emit(*fields):
        try:
            log.write("\t".join("" if f is None else str(f) for f in fields) + "\n")
        except Exception:
            pass  # a probe that breaks the task is worse than no probe

    # The interpreter's own installation is not this graph's business. This is
    # the one filter that lives HERE rather than in Racket, because it is a fact
    # about the runtime, not about the graph: everything else the task touches
    # is classified against the graph, where the declarations live.
    roots = tuple(
        os.path.realpath(p) + os.sep
        for p in {sys.prefix, sys.base_prefix, sys.exec_prefix, sys.base_exec_prefix}
    )

    seen = set()

    def hook(event, args):
        try:
            if event != "open":
                return
            path = args[0]
            if not isinstance(path, (str, bytes, os.PathLike)):
                return  # an already-open fd; nothing to name
            path = os.path.abspath(os.fsdecode(path))
            if path in seen:
                return
            seen.add(path)
            if path.startswith(roots):
                return
            # A .pyc is a CACHE OF a source file, never an input in its own
            # right — and with a warm __pycache__ it is the only thing opened
            # for an import. Recording it as a dependency would name the wrong
            # file; the module sweep below names the .py. Dropped here rather
            # than in Racket for the same reason as the prefix filter above:
            # it is a fact about the Python runtime, not about the graph.
            if os.path.basename(os.path.dirname(path)) == "__pycache__":
                return
            emit("open", path, args[1] if len(args) > 1 else None)
        except Exception:
            pass

    me = os.path.abspath(__file__)

    def sweep():
        # CODE dependence. Runs at normal interpreter exit only — a task killed
        # by a signal or os._exit loses this half, while the `open` half above
        # survives because it is line-buffered. Reported, not silently assumed.
        try:
            for name, mod in sorted(sys.modules.items()):
                f = getattr(mod, "__file__", None)
                if not f:
                    continue  # builtin or frozen: no file to depend on
                f = os.path.abspath(f)
                if f.startswith(roots) or f == me:
                    continue  # the probe is not a dependency of the task
                emit("module", name, f)
            emit("probe", "sweep-complete")
        except Exception:
            pass

    # A real sitecustomize elsewhere on the path would be SHADOWED by ours, and
    # silently: PYTHONPATH is searched first and `site` imports the name once.
    # Chain-load it rather than displace it, and say so in the log either way.
    _chain_load(emit)

    import atexit

    atexit.register(sweep)
    sys.addaudithook(hook)
    emit("probe", "installed pid=%d exe=%s" % (os.getpid(), sys.executable))


def _chain_load(emit):
    """Run any OTHER sitecustomize this one is standing in front of."""
    try:
        import importlib.util

        ours = os.path.realpath(os.path.dirname(__file__))
        others = [p for p in sys.path if p and os.path.realpath(p) != ours]
        spec = importlib.util.find_spec  # noqa: F841 - kept for readability below
        found = importlib.machinery.PathFinder.find_spec("sitecustomize", others)
        if found is None:
            return
        emit("probe", "chain-loading shadowed sitecustomize at %s" % found.origin)
        mod = importlib.util.module_from_spec(found)
        found.loader.exec_module(mod)
    except Exception as exc:  # a broken neighbour is not ours to raise
        emit("probe", "chain-load failed: %r" % (exc,))


if _LOG_PATH:
    import importlib.machinery  # noqa: E402 - only needed on the active path
    import importlib.util  # noqa: E402

    try:
        _install(_LOG_PATH)
    except Exception as _exc:
        # Never take the task down. A missing log is a visible failure downstream
        # (Racket reports "no trace"), which is the right way for this to fail.
        print("stelis probe: disabled (%r)" % (_exc,), file=sys.stderr)
