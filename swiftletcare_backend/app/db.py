"""Kết nối SQL Server bằng pyodbc.

- Chỉ dùng tài khoản ít quyền (MSSQL_APP_USER). Từ chối `sa`, sysadmin và db_owner.
- Mỗi request một connection; khi có lỗi DB thì rollback và ĐÓNG connection (không tái sử dụng
  connection có thể đang ở trạng thái transaction hỏng, ví dụ XACT_STATE = -1).
- Chỉ gọi stored procedure có tên cố định trong code; mọi giá trị đi qua tham số `?`.
"""
import datetime
import decimal
import os
import re

import pyodbc
from flask import current_app, g

from .responses import ApiError

_PROC_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?$")
_PARAM_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_privilege_checked = False


def _odbc_value(value):
    return "{" + str(value).replace("}", "}}") + "}"


def _connection_string():
    user, password = os.getenv("MSSQL_APP_USER"), os.getenv("MSSQL_APP_PASSWORD")
    if not user or not password:
        raise ApiError(503, "DB_NOT_CONFIGURED", "Chưa cấu hình tài khoản SQL cho ứng dụng.")
    if user.strip().lower() == "sa":
        raise ApiError(503, "DB_UNSAFE_LOGIN", "Không được kết nối ứng dụng bằng tài khoản sa.")
    return (
        "DRIVER={ODBC Driver 18 for SQL Server};"
        f"SERVER={os.getenv('MSSQL_HOST', '127.0.0.1')},{os.getenv('MSSQL_PORT', '14330')};"
        f"DATABASE={os.getenv('MSSQL_DATABASE', 'SwiftletCare')};"
        f"UID={_odbc_value(user)};PWD={_odbc_value(password)};"
        "Encrypt=yes;TrustServerCertificate=yes;"
    )


def _assert_least_privilege(conn):
    """Kiểm tra 1 lần mỗi tiến trình: tài khoản không được là sysadmin hoặc db_owner."""
    global _privilege_checked
    if _privilege_checked:
        return
    cur = conn.cursor()
    cur.execute("SELECT IS_SRVROLEMEMBER('sysadmin'), IS_MEMBER('db_owner')")
    sysadmin, db_owner = cur.fetchone()
    if sysadmin == 1 or db_owner == 1:
        conn.close()
        raise ApiError(503, "DB_UNSAFE_LOGIN",
                       "Tài khoản SQL của ứng dụng có quyền quá cao (sysadmin/db_owner).")
    _privilege_checked = True


def _to_api_error(exc):
    state = exc.args[0] if exc.args else ""
    raw = str(exc.args[1]) if len(exc.args) > 1 else str(exc)
    current_app.logger.error("SQL Server error [%s]: %s", state, raw)  # chi tiết chỉ ở log
    if state in ("08001", "08S01", "HYT00", "28000", "08004"):
        return ApiError(503, "DB_UNAVAILABLE", "Không kết nối được cơ sở dữ liệu.")
    if state == "40001":
        return ApiError(409, "CONCURRENCY_CONFLICT", "Xung đột truy cập đồng thời, hãy thử lại.")
    if state == "23000":
        return ApiError(409, "DB_CONSTRAINT", "Dữ liệu vi phạm ràng buộc toàn vẹn.")
    return ApiError(500, "DB_ERROR", "Lỗi cơ sở dữ liệu.")


def get_db():
    if "db" not in g:
        try:
            conn = pyodbc.connect(_connection_string(), timeout=5)
            _assert_least_privilege(conn)
        except pyodbc.Error as exc:
            raise _to_api_error(exc)
        g.db = conn
    return g.db


def close_db(_exc=None):
    conn = g.pop("db", None)
    if conn is not None:
        try:
            conn.close()
        except pyodbc.Error:
            pass


def init_app(app):
    app.teardown_appcontext(close_db)


def _value(v):
    if isinstance(v, decimal.Decimal):
        return float(v)
    if isinstance(v, (datetime.datetime, datetime.date)):
        return v.isoformat()
    return v


def call_proc(name, params=None):
    """EXEC <name> @p1 = ?, @p2 = ? ... -> list[list[dict]] (mọi result set), rồi COMMIT.
    `params` là dict {tên_tham_số_T-SQL: giá_trị}."""
    params = params or {}
    if not _PROC_NAME.match(name) or not all(_PARAM_NAME.match(p) for p in params):
        raise ValueError("Tên procedure/tham số không hợp lệ")
    sql = f"EXEC {name}" + (" " + ", ".join(f"@{p} = ?" for p in params) if params else "")
    conn = get_db()
    try:
        cur = conn.cursor()
        cur.execute(sql, tuple(params.values()))
        result_sets = []
        while True:
            if cur.description is not None:
                cols = [c[0] for c in cur.description]
                result_sets.append(
                    [{c: _value(v) for c, v in zip(cols, row)} for row in cur.fetchall()])
            if not cur.nextset():
                break
        conn.commit()
        return result_sets
    except pyodbc.Error as exc:
        try:
            conn.rollback()
        finally:
            close_db()  # loại bỏ connection sau lỗi
        raise _to_api_error(exc)


def ping():
    conn = get_db()
    try:
        conn.cursor().execute("SELECT 1").fetchone()
    except pyodbc.Error as exc:
        close_db()
        raise _to_api_error(exc)
