import uuid
import re
from pathlib import Path

import pytest
from playwright.sync_api import sync_playwright, expect

from test_application_integration import ingest, reading

pytestmark = [pytest.mark.integration, pytest.mark.browser]
ARTIFACTS = Path(__file__).resolve().parents[1] / ".test-artifacts"


def test_real_browser_create_reload_search_and_mobile(
    server, test_config, fixture_data
):
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        context = browser.new_context(viewport={"width": 1440, "height": 1000})
        context.tracing.start(screenshots=True, snapshots=True)
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        ARTIFACTS.mkdir(exist_ok=True)
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
    rid = ingest(server, test_config, "readings", p).json()["data"]["ReadingId"]
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
            page.once("dialog", lambda dialog: dialog.accept(str(rid)))
            row(f["FAN"]).get_by_role("button", name="Áp dụng AUTO", exact=True).click()
            expect(row(f["FAN"])).to_contain_text("Bật")
            row(f["FAN"]).get_by_role(
                "button", name="Thủ công: Tắt", exact=True
            ).click()
            expect(row(f["FAN"])).to_contain_text("Thủ công")
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
