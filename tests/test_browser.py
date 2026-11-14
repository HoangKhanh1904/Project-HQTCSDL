import uuid
import re
import os
import tempfile
from datetime import datetime
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest
from playwright.sync_api import sync_playwright, expect

from test_application_integration import ingest, reading

pytestmark = [pytest.mark.integration, pytest.mark.browser]
ARTIFACTS = Path(
    os.environ.get(
        "SWIFTLET_TEST_ARTIFACTS",
        Path(tempfile.gettempdir()) / "swiftletcare-test-artifacts",
    )
)


def sensor_browser_login(page, server, test_config):
    page.goto(server + "/login")
    page.locator("#loginForm input[name=username]").fill("apptest_admin")
    page.locator("#loginForm input[name=password]").fill(test_config["login_password"])
    page.locator("#loginForm button").click()
    expect(page.locator("#workspace")).to_be_visible()
    page.goto(server + "/sensors")
    expect(page.locator("#chartPanel")).to_be_visible()
    expect(page.locator("#refresh")).to_be_enabled()


def sensor_browser_load(page, device, button):
    with page.expect_response(
        lambda response: (
            "/api/metrics?" in response.url
            and parse_qs(urlsplit(response.url).query).get("device_id") == [str(device)]
        )
    ) as pending:
        button.click()
    response = pending.value
    assert response.status == 200
    return response.json()["data"], parse_qs(urlsplit(response.url).query)


@pytest.mark.parametrize("width,timezone", [(1440, "Asia/Ho_Chi_Minh"), (390, "UTC")])
def test_sensor_default_period_includes_new_readings_and_refresh(
    server, test_config, client, fixture_data, sql, width, timezone
):
    f = fixture_data
    first = ingest(server, test_config, "readings", reading(f))
    assert first.status_code == 201
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        context = browser.new_context(
            viewport={"width": width, "height": 900}, timezone_id=timezone
        )
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        try:
            sensor_browser_login(page, server, test_config)
            page.locator("#filters select[name=device_id]").select_option(
                str(f["SENSOR"])
            )
            rows, initial = sensor_browser_load(
                page, f["SENSOR"], page.locator("#filters button")
            )
            assert [r["ReadingId"] for r in rows] == [first.json()["data"]["ReadingId"]]
            expect(page.locator("#historyChart circle")).to_have_count(1)
            assert (
                datetime.fromisoformat(initial["to"][0].replace("Z", "+00:00"))
                - datetime.fromisoformat(initial["from"][0].replace("Z", "+00:00"))
            ).total_seconds() == 86400
            for metric in ("CO2Ppm", "LightLux"):
                page.locator("#chartMetric").select_option(metric)
                expect(page.locator("#historyChart circle")).to_have_count(0)
            second = ingest(
                server,
                test_config,
                "readings",
                reading(f, temperature=0, humidity=0, co2_ppm=0, light_lux=0),
            )
            assert second.status_code == 201
            rows, refreshed = sensor_browser_load(
                page, f["SENSOR"], page.locator("#refresh")
            )
            assert (
                len(rows) == 2
                and rows[0]["ReadingId"] == second.json()["data"]["ReadingId"]
            )
            assert refreshed["to"][0] > initial["to"][0]
            end = datetime.fromisoformat(refreshed["to"][0].replace("Z", "+00:00"))
            newest = datetime.fromisoformat(rows[0]["RecordeAt"])
            assert newest < end
            assert abs(end.timestamp() * 1000 - page.evaluate("Date.now()")) < 5000
            for metric, count in [
                ("Temperature", 2),
                ("Humidity", 2),
                ("CO2Ppm", 1),
                ("LightLux", 1),
            ]:
                page.locator("#chartMetric").select_option(metric)
                expect(page.locator("#historyChart circle")).to_have_count(count)
                assert "NaN" not in page.locator("#historyChart").inner_html()
            assert page.locator("#historyChart circle").get_attribute("cy") == "210"
            dashboard = client.data("GET", f"/dashboard/zones?zone_id={f['zone']}")[
                "zones"
            ][0]
            stored = sql.execute(
                "SELECT TOP(1) Temperature,Humidity,CO2Ppm,LightLux FROM dbo.SensorReadings WHERE DeviceId=? ORDER BY RecordeAt DESC,ReadingId DESC",
                f["SENSOR"],
            ).fetchone()
            assert tuple(stored) == (0, 0, 0, 0)
            assert dashboard["temperature"] == rows[0]["Temperature"] == 0
            assert dashboard["humidity"] == rows[0]["Humidity"] == 0
            assert page.evaluate(
                "document.documentElement.scrollWidth <= window.innerWidth"
            )
            assert not errors, errors
        finally:
            browser.close()


@pytest.mark.parametrize("width,timezone", [(1440, "UTC"), (390, "Asia/Ho_Chi_Minh")])
def test_sensor_manual_period_preserves_half_open_midnight_boundaries(
    server, test_config, client, fixture_data, sql, width, timezone
):
    f = fixture_data
    ids = []
    for stamp, temp, co2 in [
        ("2026-11-10T16:59:59.999", 0, None),
        ("2026-11-10T17:00:00.000", 29, 0),
        ("2026-11-10T17:00:00.001", 31, 420),
    ]:
        ids.append(
            sql.execute(
                "INSERT dbo.SensorReadings(DeviceId,Temperature,Humidity,CO2Ppm,LightLux,RecordeAt) OUTPUT inserted.ReadingId VALUES (?,?,80,?,0,?)",
                f["SENSOR"],
                temp,
                co2,
                stamp,
            ).fetchval()
        )
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        page = browser.new_page(
            viewport={"width": width, "height": 900}, timezone_id=timezone
        )
        try:
            sensor_browser_login(page, server, test_config)
            page.locator("#filters select[name=device_id]").select_option(
                str(f["SENSOR"])
            )
            local_from, local_to = (
                ("2026-11-10T16:59:59.999", "2026-11-10T17:00:00")
                if timezone == "UTC"
                else ("2026-11-10T23:59:59.999", "2026-11-11T00:00:00")
            )
            page.locator("#filters input[name=from]").fill(local_from)
            page.locator("#filters input[name=to]").fill(local_to[:16])
            chosen = [
                page.locator(f"#filters input[name={key}]").input_value()
                for key in ("from", "to")
            ]
            rows, bounds = sensor_browser_load(
                page, f["SENSOR"], page.locator("#filters button")
            )
            assert [r["ReadingId"] for r in rows] == [ids[0]]
            assert bounds["to"] == ["2026-11-10T17:00:00.000Z"]
            expect(page.locator("#historyChart circle")).to_have_count(1)
            rows, again = sensor_browser_load(
                page, f["SENSOR"], page.locator("#refresh")
            )
            assert again == bounds and [r["ReadingId"] for r in rows] == [ids[0]]
            assert [
                page.locator(f"#filters input[name={key}]").input_value()
                for key in ("from", "to")
            ] == chosen
            # Moving only the exclusive end by 1 ms includes equality at midnight,
            # while the row exactly at the new end remains excluded.
            page.locator("#filters input[name=to]").fill(local_to + ".001")
            rows, _ = sensor_browser_load(
                page, f["SENSOR"], page.locator("#filters button")
            )
            assert [r["ReadingId"] for r in rows] == [ids[1], ids[0]]
            page.locator("#filters input[name=to]").fill(local_to + ".002")
            rows, _ = sensor_browser_load(page, f["SENSOR"], page.locator("#refresh"))
            assert [r["ReadingId"] for r in rows] == list(reversed(ids))
            dashboard = client.data("GET", f"/dashboard/zones?zone_id={f['zone']}")[
                "zones"
            ][0]
            assert dashboard["temperature"] == rows[0]["Temperature"] == 31
            assert page.evaluate(
                "document.documentElement.scrollWidth <= window.innerWidth"
            )
        finally:
            browser.close()


def test_real_browser_create_reload_search_and_mobile(
    server, test_config, fixture_data, sql
):
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        context = browser.new_context(viewport={"width": 1440, "height": 1000})
        context.tracing.start(screenshots=True, snapshots=True)
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        try:
            page.goto(server + "/farms")
            page.get_by_label("Tên đăng nhập", exact=True).fill("apptest_admin")
            page.get_by_label("Mật khẩu", exact=True).fill(
                test_config["login_password"]
            )
            page.get_by_role("button", name="Đăng nhập", exact=True).click()
            expect(page.locator("#workspace")).to_be_visible()
            page.goto(server + "/farms")
            name = "Nhà yến hồi quy " + uuid.uuid4().hex[:8]
            page.get_by_label("Tên", exact=True).fill(name)
            page.get_by_label("Địa chỉ", exact=True).fill("Thủ Đức, TP.HCM")
            page.get_by_role("button", name="Lưu", exact=True).click()
            expect(page.locator("#tableBody")).to_contain_text(name)
            page.reload()
            expect(page.locator("#tableBody")).to_contain_text(name)
            page.get_by_label("Tìm kiếm", exact=True).fill(name)
            expect(page.locator("#tableBody tr")).to_have_count(1)
            row = page.locator("#tableBody tr").filter(has_text=name)
            row.get_by_role("button", name="Sửa", exact=True).click()
            changed = name + " đã sửa"
            page.get_by_label("Tên", exact=True).fill(changed)
            page.get_by_role("button", name="Lưu", exact=True).click()
            expect(page.locator("#tableBody")).to_contain_text(changed)
            # Untrusted strings stay text, including after reload.
            row = page.locator("#tableBody tr").filter(has_text=changed)
            row.get_by_role("button", name="Sửa", exact=True).click()
            page.get_by_label("Địa chỉ", exact=True).fill(
                "<img src=x onerror=alert(1)>"
            )
            page.get_by_role("button", name="Lưu", exact=True).click()
            expect(page.locator("#tableBody")).to_contain_text(
                "<img src=x onerror=alert(1)>"
            )
            assert page.locator("#tableBody img").count() == 0
            # Push the edited house beyond the first 50 rows, then search globally.
            for index in range(55):
                sql.execute(
                    "INSERT dbo.SwiftletHouses(HouseName,ManagerId) VALUES (?,?)",
                    f"Trang sau {index}",
                    fixture_data["manager"],
                )
            page.reload()
            expect(page.locator("#tableBody")).not_to_contain_text(changed)
            page.get_by_label("Tìm kiếm", exact=True).fill(changed)
            expect(page.locator("#tableBody")).to_contain_text(changed)
            expect(page.locator("#tableBody tr")).to_have_count(1)
            page.locator("#filters select[name=status]").select_option("INACTIVE")
            expect(page.locator("#tableBody")).to_contain_text(
                "Chưa có dữ liệu phù hợp"
            )
            page.locator("#filters select[name=status]").select_option("ACTIVE")
            expect(page.locator("#tableBody")).to_contain_text(changed)
            p = reading(fixture_data, temperature=35, co2_ppm=420, light_lux=12)
            assert ingest(server, test_config, "readings", p).status_code == 201
            page.goto(server + "/")
            expect(page.locator("#tableBody")).to_contain_text("Vượt ngưỡng")
            page.screenshot(
                path=str(ARTIFACTS / "dashboard-desktop.png"), full_page=True
            )
            page.goto(server + "/sensors")
            expect(page.locator("#chartPanel")).to_be_visible()
            expect(page.locator("#chartNote")).to_contain_text("số đo")
            page.screenshot(path=str(ARTIFACTS / "history-desktop.png"), full_page=True)
            page.set_viewport_size({"width": 390, "height": 844})
            page.goto(server + "/farms")
            expect(page.locator("#workspace")).to_be_visible()
            assert page.evaluate(
                "document.documentElement.scrollWidth <= window.innerWidth"
            )
            page.screenshot(path=str(ARTIFACTS / "farms-mobile.png"), full_page=True)
            assert not errors, errors
        finally:
            context.tracing.stop(path=str(ARTIFACTS / "browser-trace.zip"))
            browser.close()


def test_browser_threshold_events_control_and_error_state(
    server, test_config, fixture_data
):
    f = fixture_data
    p = reading(f, temperature=35)
    assert ingest(server, test_config, "readings", p).status_code == 201
    event = {
        "house_id": f["house"],
        "zone_id": f["zone"],
        "event_type": "ABNORMAL_SOUND",
        "severity": "WARNING",
        "message": "Âm thanh mô phỏng",
        "event_time": "2026-01-01T00:00:00Z",
        "source_event_id": str(uuid.uuid4()),
    }
    eid = ingest(server, test_config, "events", event).json()["data"]["EventId"]
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        context = browser.new_context(viewport={"width": 1280, "height": 900})
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda e: errors.append(str(e)))

        def row(identifier):
            return page.locator("#tableBody tr").filter(
                has=page.locator(
                    "td:first-child", has_text=re.compile("^" + str(identifier) + "$")
                )
            )

        try:
            page.goto(server + "/login")
            page.get_by_label("Tên đăng nhập", exact=True).fill("apptest_admin")
            page.get_by_label("Mật khẩu", exact=True).fill(
                test_config["login_password"]
            )
            page.get_by_role("button", name="Đăng nhập", exact=True).click()
            expect(page.locator("#workspace")).to_be_visible()
            page.goto(server + "/areas")
            row(f["zone"]).get_by_role("button", name="Ngưỡng", exact=True).click()
            page.get_by_label("Nhiệt độ tối đa", exact=True).fill("33")
            page.get_by_role("button", name="Lưu ngưỡng", exact=True).click()
            expect(page.locator("#message")).to_contain_text("Đã lưu ngưỡng")
            page.goto(server + "/events")
            row(eid).get_by_role("button", name="Xác nhận", exact=True).click()
            expect(row(eid)).to_contain_text("Đã xác nhận")
            page.goto(server + "/controls")
            row(f["FAN"]).get_by_role("button", name="Chế độ AUTO", exact=True).click()
            expect(row(f["FAN"])).to_contain_text("Tự động")
            row(f["FAN"]).get_by_role("button", name="Áp dụng AUTO", exact=True).click()
            expect(row(f["FAN"])).to_contain_text("Bật")
            row(f["FAN"]).get_by_role(
                "button", name="Thủ công: Tắt", exact=True
            ).click()
            expect(row(f["FAN"])).to_contain_text("Thủ công")
            row(f["FAN"]).get_by_role("button", name="Lịch sử", exact=True).click()
            expect(page.locator("#tableHead")).to_contain_text("Mã nhật ký")
            expect(page.locator("#tableBody tr")).to_have_count(2)
            expect(page.locator("#tableBody")).to_contain_text("Mô phỏng")
            page.set_viewport_size({"width": 390, "height": 844})
            assert page.evaluate(
                "document.documentElement.scrollWidth <= window.innerWidth"
            )
            # Fault-state UI test deliberately intercepts only a failed response.
            # Successful E2E paths above always use real SQL/HTTP.
            page.route(
                "**/api/dashboard/zones",
                lambda route: route.fulfill(
                    status=503,
                    content_type="application/json",
                    body='{"success":false,"code":"DB_UNAVAILABLE","message":"Không kết nối DB"}',
                ),
            )
            page.goto(server + "/")
            expect(page.locator("#message")).to_have_class("error")
            expect(page.locator("#message")).to_contain_text("chưa xác nhận mới")
            assert not errors, errors
        finally:
            browser.close()
