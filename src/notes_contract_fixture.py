"""Cross-repo contract fixture for st-whm: stand up a REAL beeatlas notes store
from beeatlas's own SQLAlchemy models, run the REAL notes_harvest.export_notes
over it, and report what it emitted — so a Racket test (notes-digest-contract-
test.rkt) can assert stelis's notes-store-keys agrees with the harvest.

Run inside beeatlas's uv/3.14 runtime (it imports notes_store + notes_harvest):

    uv run --directory <beeatlas>/data python <this> <beeatlas>/data <out-dir>

Building the store from `Base.metadata.create_all` (not a hand-rolled schema)
means the fixture can't drift from the real models. Two independent full builds
are produced under <out-dir>:

  s0/  — the base fixture (varied status + multi-note species)
  s1/  — s0 with ONE note's body_html edited

Each build writes notes.db + notes/<canonical_name>.json. For each state we
print, as JSON on stdout, {canonical_name: {"count": N, "sha": <hex>}} over the
emitted files — the keyset, the per-species note count, and a content hash the
Racket side uses for the field-sensitivity half (which species' output MOVED
between s0 and s1). The db paths are <out-dir>/s0/notes.db and .../s1/notes.db,
which the Racket side digests with notes-store-keys.
"""

import contextlib
import datetime
import hashlib
import io
import json
import sys
from pathlib import Path


def _now(day):
    return datetime.datetime(2026, 7, day, 0, 0, 0, tzinfo=datetime.timezone.utc)


# The fixture, as (note_id, canonical_name, author_login, body_html, status, day).
# Chosen to exercise every branch the harvest keyset depends on:
#   - apis mellifera: TWO approved notes (count 2), distinct authors
#   - osmia lignaria: one approved + one removed by the SAME species (count 1 — the
#     digest/harvest must count APPROVED only, not "species has any note")
#   - bombus vosnesenskii: removed-only  -> no file, no key
#   - megachile perihirta: pending-only  -> no file, no key
# The INNER JOIN users case (an orphan author_id) is UNREACHABLE here: author_id is
# a FK to users.id with foreign_keys=ON, so it can't exist in a real store. The
# unit test (notes-digest-test.rkt) covers it against a hand-rolled FK-less store.
_USERS = {"alice": 100, "bob": 101, "curator": 102}
_NOTES = [
    (1, "apis mellifera", "alice", "<p>honey bee one</p>", "approved", 1),
    (2, "apis mellifera", "bob", "<p>honey bee two</p>", "approved", 2),
    (3, "osmia lignaria", "curator", "<p>mason bee</p>", "approved", 3),
    (6, "osmia lignaria", "alice", "<p>retracted</p>", "removed", 6),
    (4, "bombus vosnesenskii", "alice", "<p>bumble</p>", "removed", 4),
    (5, "megachile perihirta", "bob", "<p>leafcutter</p>", "pending", 5),
]
# s1 = s0 with exactly this note's body_html edited — a field the harvest emits AND
# the digest hashes, so the species' harvest output AND its digest key must move.
_EDIT_NOTE_ID = 1
_EDITED_HTML = "<p>honey bee one (revised)</p>"


def build_store(db_path, models, edit=False):
    """Create the schema from the real models and insert the fixture. When *edit*,
    note _EDIT_NOTE_ID gets _EDITED_HTML. Uses beeatlas's own make_engine (WAL),
    then checkpoints so DuckDB's sqlite scanner reads a complete main db file."""
    Base, Note, User, make_engine = models
    from sqlalchemy.orm import Session

    engine = make_engine(db_path)
    Base.metadata.create_all(engine)
    with Session(engine) as session:
        users = {}
        for login, uid in _USERS.items():
            u = User(id=uid, inat_user_id=uid, inat_login=login,
                     created_at=_now(1), updated_at=_now(1))
            session.add(u)
            users[login] = u
        session.flush()  # persist users before the notes that FK-reference them
        for nid, name, login, html, status, day in _NOTES:
            if edit and nid == _EDIT_NOTE_ID:
                html = _EDITED_HTML
            session.add(Note(
                id=nid, canonical_name=name, author_id=users[login].id,
                body="md", body_html=html, status=status,
                created_at=_now(day), updated_at=_now(day)))
        session.commit()
    # Fold the -wal back into the main file so the read-only DuckDB scan on the
    # Racket side sees every committed row deterministically (the contract under
    # test is query/field agreement, not live-wal visibility).
    with engine.connect() as conn:
        conn.exec_driver_sql("PRAGMA wal_checkpoint(TRUNCATE)")
    engine.dispose()


def summarize(notes_dir):
    """{canonical_name: {count, sha}} over the harvest's emitted per-species files."""
    out = {}
    for f in sorted(Path(notes_dir).glob("*.json")):
        raw = f.read_bytes()
        out[f.stem] = {
            "count": len(json.loads(raw)),
            "sha": hashlib.sha256(raw).hexdigest(),
        }
    return out


def main():
    data_dir, out_dir = sys.argv[1], Path(sys.argv[2])
    sys.path.insert(0, data_dir)  # so `import notes_store` / `notes_harvest` resolve

    from notes_store.models import Base, Note, User
    from notes_store.db import make_engine
    from notes_harvest import export_notes
    models = (Base, Note, User, make_engine)

    result = {}
    for state, edit in (("s0", False), ("s1", True)):
        state_dir = out_dir / state
        state_dir.mkdir(parents=True, exist_ok=True)
        db_path = state_dir / "notes.db"
        build_store(str(db_path), models, edit=edit)
        # Swallow export_notes' own progress prints so stdout carries ONLY our JSON.
        with contextlib.redirect_stdout(io.StringIO()):
            export_notes(engine=make_engine(str(db_path)), assets_dir=state_dir)
        result[state] = summarize(state_dir / "notes")

    print(json.dumps(result))


if __name__ == "__main__":
    main()
