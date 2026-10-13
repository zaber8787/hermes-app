"""Disposable-store regression for old terminal rows and active rows."""
import sqlite3
import tempfile
import time
from pathlib import Path

from compat import ledger_retention


def run():
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        old, recent = time.time() - 100 * 86400, time.time()
        n = sqlite3.connect(home / "notification-events.sqlite")
        n.executescript("CREATE TABLE events(event_id TEXT PRIMARY KEY,read_at REAL,created_at REAL);"
                        "CREATE TABLE deliveries(delivery_id TEXT PRIMARY KEY,event_id TEXT,state TEXT,updated_at REAL);"
                        "CREATE TABLE read_events(event_id TEXT,reader TEXT);")
        n.executemany("INSERT INTO events VALUES(?,?,?)", [("old", old, old),
                      ("active", None, old), ("recent", recent, recent)])
        n.executemany("INSERT INTO deliveries VALUES(?,?,?,?)", [("d1", "old", "shown", old),
                      ("d2", "active", "pending", old), ("d3", "recent", "shown", recent)])
        n.execute("INSERT INTO read_events VALUES('old','reader')")
        n.execute("INSERT INTO read_events VALUES('old','reader2')")
        n.commit(); n.close()
        w = sqlite3.connect(home / "wake_ledger.db")
        w.executescript("CREATE TABLE wake_batches(batch_id TEXT PRIMARY KEY,state TEXT,terminal_at REAL);"
                        "CREATE TABLE wake_consumption(delivery_key TEXT PRIMARY KEY,batch_id TEXT);"
                        "CREATE TABLE selfwake_audit(seq INTEGER PRIMARY KEY,at REAL);")
        w.executemany("INSERT INTO wake_batches VALUES(?,?,?)", [("old", "terminal", old),
                      ("active", "accepted", old), ("recent", "terminal", recent)])
        w.executemany("INSERT INTO wake_consumption VALUES(?,?)", [("k1", "old"), ("k2", "active")])
        w.executemany("INSERT INTO selfwake_audit VALUES(?,?)", [(1, old), (2, recent)])
        w.commit(); w.close()
        c = sqlite3.connect(home / "cron_bridge.db")
        c.executescript("CREATE TABLE receipts(delivery_key TEXT PRIMARY KEY,status TEXT,updated_at REAL);"
                        "CREATE TABLE pending(delivery_key TEXT PRIMARY KEY);")
        c.executemany("INSERT INTO receipts VALUES(?,?,?)", [("old", "delivered", old),
                      ("active", "queued", old), ("recent", "delivered", recent)])
        c.execute("INSERT INTO pending VALUES('active')")
        c.commit(); c.close()
        counts = ledger_retention.prune_home(home, now=time.time())
        assert counts == {"notification": 1, "wake": 1, "cron": 1}, counts
        for path, table, expected in (("notification-events.sqlite", "events", 2),
                                      ("wake_ledger.db", "wake_batches", 2),
                                      ("cron_bridge.db", "receipts", 2)):
            db = sqlite3.connect(home / path)
            assert db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == expected
            assert db.execute("SELECT COUNT(*) FROM retention_archive").fetchone()[0] >= 1
            if table == "events":
                assert db.execute("SELECT COUNT(*) FROM retention_archive"
                                  " WHERE source_table='read_events'").fetchone()[0] == 2
            db.close()
    print("PASS retention: old terminal archived, active/recent retained")


if __name__ == "__main__":
    run()
