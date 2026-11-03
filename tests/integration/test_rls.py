import json
import uuid
import psycopg
import pytest

# TODO: reuse however test_schema.py gets its connection string

@pytest.fixture
def conn():
    with psycopg.connect(DATABASE_URL) as c:
        yield c
        c.rollback()  # undoes setup + everything below

def act_as(cur, user_id):
    """Impersonate a user for the rest of this transaction."""
    cur.execute("SET LOCAL ROLE authenticated")
    cur.execute(
        "SELECT set_config('request.jwt.claims', %s, true)",
        (json.dumps({"sub": str(user_id), "role": "authenticated"}),),
    )

def test_user_cannot_read_another_users_rows(conn):
    user_a, user_b = uuid.uuid4(), uuid.uuid4()
    with conn.cursor() as cur:
        # --- setup as admin (RLS bypassed) ---
        # TODO: insert user_a and user_b (into auth.users, or wherever your FK points)
        # TODO: insert one row into an RLS-protected table owned by user_a

        # --- positive control ---
        act_as(cur, user_a)
        # TODO: select that row, assert exactly 1 result

        # --- the actual test ---
        act_as(cur, user_b)
        # TODO: select the same row, assert 0 results