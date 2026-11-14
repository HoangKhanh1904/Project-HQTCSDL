"""Provision only a dedicated, labelled container. Never touches the user's SQL instance.

Run from repository root. Credentials stay in ignored .test-env.json.
"""

import json
import argparse
import re
import secrets
import subprocess
import sys
import time
import uuid
from pathlib import Path

import pyodbc
from werkzeug.security import generate_password_hash

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "database"))
import complete_database as baseline  # noqa: E402 - existing database deployment module


def execute(conn, sql, params=()):
    cur = conn.cursor()
    cur.execute(sql, params)
    results = []
    while True:
        if cur.description:
            columns = [c[0] for c in cur.description]
            results.append([dict(zip(columns, row)) for row in cur.fetchall()])
        if not cur.nextset():
            break
    cur.close()
    return results


def deploy(conn, database, upgrade=True):
    assert re.fullmatch(r"SwiftletCare_AppTest_[a-f0-9]+", database)
    files = (
        baseline.DEPLOY_FILES
        if upgrade
        else [
            "create_tables.sql",
            "alter_table.sql",
            "runtime_migration.sql",
            "concurrency/sp_acknowledge_alert.sql",
            "concurrency/sp_get_environment_threshold.sql",
            "concurrency/sp_update_environment_threshold.sql",
            "procedures/sp_insert_sensor_reading.sql",
            "procedures/sp_transition_alert.sql",
            "procedures/sp_resolve_alert.sql",
            "procedures/sp_reopen_alert.sql",
            "procedures/sp_create_environment_threshold.sql",
            "procedures/sp_get_latest_sensor_readings.sql",
            "procedures/sp_get_sensor_history.sql",
            "procedures/sp_get_unresolved_alerts.sql",
            "procedures/sp_get_zone_dashboard.sql",
        ]
    )
    for path in files:
        sql = (
            (ROOT / "database" / path)
            .read_text(encoding="utf-8-sig")
            .replace("USE SwiftletCare;", f"USE [{database}];")
        )
        for batch in re.split(r"^\s*GO\s*$", sql, flags=re.M | re.I):
            if batch.strip():
                execute(conn, batch)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--resume-container",
        help="Resume a dedicated container created by this script after a startup timeout.",
    )
    args = parser.parse_args()
    config_path = ROOT / ".test-env.json"
    if config_path.exists():
        print(
            "Dedicated test environment already configured; use tests without reprovisioning."
        )
        return
    tag = uuid.uuid4().hex[:12]
    container = "hqtcsdl-app-tests-" + tag
    sa_password, app_password, login_password = [
        secrets.token_urlsafe(24) + "!aA1" for _ in range(3)
    ]
    port = 14339
    if args.resume_container:
        info = json.loads(
            subprocess.check_output(["docker", "inspect", args.resume_container])
        )[0]
        if info["Config"]["Labels"].get("hqtcsdl.scope") != "application-test":
            raise RuntimeError("Refusing a non-test container.")
        container = args.resume_container
        sa_password = next(
            v.split("=", 1)[1]
            for v in info["Config"]["Env"]
            if v.startswith("MSSQL_SA_PASSWORD=")
        )
        port = int(info["NetworkSettings"]["Ports"]["1433/tcp"][0]["HostPort"])
    else:
        subprocess.run(
            [
                "docker",
                "run",
                "-d",
                "--name",
                container,
                "--label",
                "hqtcsdl.scope=application-test",
                "-e",
                "ACCEPT_EULA=Y",
                "-e",
                "MSSQL_PID=Developer",
                "-e",
                "MSSQL_SA_PASSWORD=" + sa_password,
                "-p",
                f"127.0.0.1:{port}:1433",
                "mcr.microsoft.com/mssql/server:2022-latest",
            ],
            check=True,
            capture_output=True,
        )
    connection = f"DRIVER={{ODBC Driver 18 for SQL Server}};SERVER=127.0.0.1,{port};UID=sa;PWD={sa_password};Encrypt=yes;TrustServerCertificate=yes;"
    for _ in range(90):
        try:
            conn = pyodbc.connect(connection, autocommit=True, timeout=2)
            break
        except pyodbc.Error:
            time.sleep(1)
    else:
        raise RuntimeError("Dedicated SQL Server did not become ready: " + container)
    database = "SwiftletCare_AppTest_" + tag
    execute(conn, f"CREATE DATABASE [{database}]")
    deploy(conn, database)
    execute(conn, f"USE [{database}]")
    execute(
        conn,
        "INSERT dbo.Users(UserName,PasswordHash,FullName,Role) VALUES (?,?,N'Application test admin','ADMIN'),(?,?,N'Application test staff','STAFF')",
        (
            "apptest_admin",
            generate_password_hash(login_password),
            "apptest_staff",
            generate_password_hash(login_password),
        ),
    )
    # Service login is not dbo/sysadmin. HTTP authorization controls end-user roles.
    execute(
        conn,
        f"CREATE LOGIN [apptest_{tag}] WITH PASSWORD='{app_password}'; CREATE USER [apptest_{tag}] FOR LOGIN [apptest_{tag}]; ALTER ROLE SwiftletAdmin ADD MEMBER [apptest_{tag}];",
    )
    config = {
        "container": container,
        "port": port,
        "database": database,
        "sa_password": sa_password,
        "app_user": "apptest_" + tag,
        "app_password": app_password,
        "login_password": login_password,
        "simulator_token": secrets.token_urlsafe(32),
        "secret_key": secrets.token_urlsafe(32),
    }
    config_path.write_text(json.dumps(config), encoding="utf-8")
    conn.close()
    print("Prepared dedicated SQL Server:", container, database, "on localhost", port)


if __name__ == "__main__":
    main()
