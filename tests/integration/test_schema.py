EXPECTED_TABLES = {
    "brands",
    "size_charts",
    "products",
    "variants",
    "chart_measurements",
    "product_attributes",
    "gold_labels",
    "query_labels",
    "extraction_runs",
    "request_log",
    "profiles",
    "owned_items",
    "style_preferences",
}


def test_catalog_and_account_tables_exist(db_cursor):
    db_cursor.execute(
        "select table_name from information_schema.tables "
        "where table_schema = 'public' and table_type = 'BASE TABLE'"
    )
    actual_tables = {row[0] for row in db_cursor.fetchall()}
    missing = EXPECTED_TABLES - actual_tables
    assert not missing, f"missing tables: {missing}"


def test_variant_measurements_view_exists(db_cursor):
    db_cursor.execute(
        "select 1 from information_schema.views "
        "where table_schema = 'public' and table_name = 'variant_measurements'"
    )
    assert db_cursor.fetchone() is not None, "variant_measurements view is missing"


def test_rls_enabled_and_signup_trigger_exists(db_cursor):
    db_cursor.execute(
        "select relname, relrowsecurity from pg_class "
        "join pg_namespace on pg_namespace.oid = pg_class.relnamespace "
        "where pg_namespace.nspname = 'public' and relkind = 'r'"
    )
    rls_by_table = dict(db_cursor.fetchall())
    missing_rls = {name for name in EXPECTED_TABLES if not rls_by_table.get(name, False)}
    assert not missing_rls, f"RLS not enabled on: {missing_rls}"

    db_cursor.execute(
        "select 1 from pg_trigger "
        "where tgname = 'on_auth_user_created' and tgrelid = 'auth.users'::regclass"
    )
    assert db_cursor.fetchone() is not None, "signup trigger on_auth_user_created is missing"
