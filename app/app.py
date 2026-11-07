import os
import time
from contextlib import contextmanager

import psycopg2
from psycopg2.extras import RealDictCursor
from flask import Flask, jsonify, request

app = Flask(__name__)

MAX_NOTE_LEN = 500


def get_conn():
    # Saari DB settings environment variables se aati hain (hardcoded nahi)
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        sslmode=os.environ.get("DB_SSLMODE", "prefer"),
        connect_timeout=5,
    )


@contextmanager
def db():
    conn = get_conn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            yield cur
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_db(retries=10, delay=3):
    """Table banata hai. DB tayyar na ho to retry karta hai."""
    for attempt in range(1, retries + 1):
        try:
            with db() as cur:
                # advisory lock: kai instances ek saath start hon to race na ho
                cur.execute("SELECT pg_advisory_xact_lock(42)")
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS notes (
                        id SERIAL PRIMARY KEY,
                        content TEXT NOT NULL,
                        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                    )
                    """
                )
            app.logger.info("Database ready")
            return
        except psycopg2.OperationalError as exc:
            app.logger.warning("DB not ready (%s/%s): %s", attempt, retries, exc)
            time.sleep(delay)
    raise RuntimeError("Database not reachable after retries")


@app.get("/api/health")
def health():
    try:
        with db() as cur:
            cur.execute("SELECT 1")
        return jsonify(status="ok", db="up"), 200
    except Exception:
        app.logger.exception("Health check failed")
        return jsonify(status="degraded", db="down"), 503


@app.get("/api/notes")
def list_notes():
    with db() as cur:
        cur.execute("SELECT id, content, created_at FROM notes ORDER BY id DESC LIMIT 100")
        rows = cur.fetchall()
    for r in rows:
        r["created_at"] = r["created_at"].isoformat()
    return jsonify(rows)


@app.post("/api/notes")
def add_note():
    data = request.get_json(silent=True) or {}
    content = str(data.get("content", "")).strip()
    if not content:
        return jsonify(error="content is required"), 400
    if len(content) > MAX_NOTE_LEN:
        return jsonify(error=f"content max {MAX_NOTE_LEN} characters"), 400
    with db() as cur:
        # Parameterized query -> SQL injection se bachao
        cur.execute(
            "INSERT INTO notes (content) VALUES (%s) RETURNING id, content, created_at",
            (content,),
        )
        row = cur.fetchone()
    row["created_at"] = row["created_at"].isoformat()
    return jsonify(row), 201


@app.errorhandler(psycopg2.Error)
def db_error(exc):
    app.logger.exception("Database error")
    return jsonify(error="database error"), 500


# gunicorn --preload ki wajah se yeh sirf ek baar chalta hai
init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
