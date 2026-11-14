import json
import os
import threading
import tempfile
from pathlib import Path

import pyodbc
import pytest
import requests
from werkzeug.serving import make_server

from app import create_app

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="session")
def test_config():
    path = Path(
        os.environ.get(
            "SWIFTLET_TEST_CONFIG",
            Path(tempfile.gettempdir()) / "swiftletcare-test-env.json",
        )
    )
    if not path.exists():
        pytest.skip(
            "NOT RUN: prepare dedicated SQL Server with tools/prepare_application_tests.py"
        )
    config = json.loads(path.read_text())
    assert (
        config["database"].startswith("SwiftletCare_AppTest_")
        and config["port"] != 14330
    )
    return config


@pytest.fixture(scope="session")
def server(test_config):
    cfg = test_config
    values = {
        "MSSQL_HOST": "127.0.0.1",
        "MSSQL_PORT": str(cfg["port"]),
        "MSSQL_DATABASE": cfg["database"],
        "MSSQL_APP_USER": cfg["app_user"],
        "MSSQL_APP_PASSWORD": cfg["app_password"],
    }
    previous = {k: os.environ.get(k) for k in values}
    os.environ.update(values)
    app = create_app(
        {
            "TESTING": False,
            "SECRET_KEY": cfg["secret_key"],
            "SIMULATOR_TOKEN": cfg["simulator_token"],
            "DB_TIMEZONE": "UTC",
        }
    )
    service = make_server("127.0.0.1", 0, app, threaded=True)
    thread = threading.Thread(target=service.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{service.server_port}"
    service.shutdown()
    thread.join(timeout=10)
    service.server_close()
    for k, v in previous.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v


class Client:
    def __init__(self, server, config, username="apptest_admin"):
        self.base = server
        self.session = requests.Session()
        token = self.session.get(server + "/api/auth", timeout=10).json()["data"][
            "csrf_token"
        ]
        response = self.session.post(
            server + "/api/auth/login",
            headers={"X-CSRF-Token": token},
            json={"username": username, "password": config["login_password"]},
            timeout=10,
        )
        assert response.status_code == 200, response.text
        self.csrf = response.json()["data"]["csrf_token"]

    def request(self, method, path, **kwargs):
        return self.session.request(
            method,
            self.base + "/api" + path,
            headers={"X-CSRF-Token": self.csrf},
            timeout=20,
            **kwargs,
        )

    def data(self, method, path, **kwargs):
        r = self.request(method, path, **kwargs)
        assert r.status_code in (200, 201), r.text
        assert r.json()["success"]
        return r.json()["data"]


@pytest.fixture
def client(server, test_config):
    c = Client(server, test_config)
    yield c
    c.session.close()


@pytest.fixture
def sql(test_config):
    c = test_config
    conn = pyodbc.connect(
        f"DRIVER={{ODBC Driver 18 for SQL Server}};SERVER=127.0.0.1,{c['port']};DATABASE={c['database']};UID=sa;PWD={c['sa_password']};Encrypt=yes;TrustServerCertificate=yes;",
        autocommit=True,
        timeout=5,
    )
    yield conn
    conn.close()


@pytest.fixture
def fixture_data(client):
    import uuid

    managers = client.data("GET", "/managers")
    uid = next(m["UserID"] for m in managers if m["Role"] == "ADMIN")
    house = client.data(
        "POST",
        "/farms",
        json={
            "name": "QA Nhà yến " + uuid.uuid4().hex[:8],
            "address": "Thủ Đức",
            "manager_id": uid,
            "status": "ACTIVE",
        },
    )["HouseId"]
    zone = client.data(
        "POST",
        "/areas",
        json={
            "name": "Khu vực QA",
            "house_id": house,
            "description": "",
            "status": "ACTIVE",
        },
    )["ZoneId"]
    ids = {}
    for kind in ("SENSOR", "FAN", "HUMIDIFIER", "LIGHT"):
        ids[kind] = client.data(
            "POST",
            "/devices",
            json={
                "name": kind + " QA",
                "zone_id": zone,
                "device_type": kind,
                "status": "ACTIVE",
            },
        )["DeviceId"]
    thresholds = {
        "MinTemperature": 26,
        "MaxTemperature": 32,
        "MinHumidity": 70,
        "MaxHumidity": 90,
    }
    client.data("POST", "/thresholds/" + str(zone), json=thresholds)
    return {
        "house": house,
        "zone": zone,
        "manager": uid,
        "thresholds": thresholds,
        **ids,
    }
