"""Tự động sinh dữ liệu mẫu thời gian thực cho Cảm biến và Lượt chim qua Stored Procedure."""

import os
import sys
import uuid
import random
from datetime import datetime, timezone, timedelta
from pathlib import Path
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
load_dotenv(ROOT / ".env")
sys.path.insert(0, str(ROOT / "swiftletcare_backend"))

from app import create_app, db  # noqa: E402


def seed_today_data():
    print("=" * 65)
    print("KHỞI TẠO DỮ LIỆU CẢM BIẾN VÀ LƯỢT CHIM (HÔM NAY)")
    print("=" * 65)

    vn_now = datetime.now(timezone(timedelta(hours=7)))

    with create_app().app_context():
        # 1. Lấy danh sách Devices loại SENSOR
        sensors = db.query("SELECT DeviceId, DeviceName, ZoneId FROM dbo.Devices WHERE DeviceType = 'SENSOR' AND Status = 'ACTIVE'")
        if not sensors:
            print("[CẢNH BÁO] Chưa có thiết bị SENSOR nào trong database.")
            return

        print(f"-> Tìm thấy {len(sensors)} cảm biến SENSOR đang hoạt động.")
        reading_count = 0

        # Gọi Stored Procedure dbo.sp_InsertSensorReading thay vì INSERT trực tiếp (tuân thủ phân quyền least privilege)
        for i in range(12):
            for s in sensors:
                temp = round(random.uniform(27.5, 31.8), 2)
                hum = round(random.uniform(78.0, 88.5), 2)
                co2 = round(random.uniform(500.0, 950.0), 1)
                lux = round(random.uniform(50.0, 320.0), 1)
                event_id = uuid.uuid4()

                try:
                    db.call_proc(
                        "dbo.sp_InsertSensorReading",
                        {
                            "DeviceId": s["DeviceId"],
                            "Temperature": temp,
                            "Humidity": hum,
                            "SourceEventId": event_id,
                            "CO2Ppm": co2,
                            "LightLux": lux,
                        }
                    )
                    reading_count += 1
                except Exception as ex:
                    print(f"Lỗi thêm reading sensor {s['DeviceId']}: {ex}")

        print(f"-> [THÀNH CÔNG] Đã ghi nhận {reading_count} số đo cảm biến (Nhiệt độ, Độ ẩm, CO2, Ánh sáng) hôm nay qua Stored Procedure.")

        # 2. Lấy danh sách Nhà yến
        houses = db.query("SELECT HouseId, HouseName FROM dbo.SwiftletHouses WHERE Status = 'ACTIVE'")
        if not houses:
            print("[CẢNH BÁO] Chưa có nhà yến nào.")
            return

        bird_count = 0
        # Gọi Stored Procedure dbo.sp_InsertBirdMovement để thêm lượt chim
        for i in range(15):
            obs_time = vn_now - timedelta(hours=(15 - i) * 0.8)
            obs_str = obs_time.strftime("%Y-%m-%d %H:%M:%S")

            for h in houses:
                direction = random.choice(["IN", "OUT", "IN"])
                count = random.randint(2, 10)
                event_id = uuid.uuid4()

                try:
                    db.call_proc(
                        "dbo.sp_InsertBirdMovement",
                        {
                            "HouseId": h["HouseId"],
                            "Direction": direction,
                            "BirdCount": count,
                            "ObservedAt": obs_str,
                            "SourceType": "SIMULATED",
                            "SourceEventId": event_id,
                        }
                    )
                    bird_count += 1
                except Exception as ex:
                    print(f"Lỗi thêm bird movement: {ex}")

        print(f"-> [THÀNH CÔNG] Đã ghi nhận {bird_count} lượt chim ra/vào hôm nay qua Stored Procedure.")
        print("\n=> DỮ LIỆU ĐÃ SẴN SÀNG! Bạn thao tác trên Web như sau:")
        print("   1. Vào 'Dữ liệu cảm biến' (/sensors) -> Bấm nút 'Áp dụng' -> Biểu đồ & bảng xuất hiện!")
        print("   2. Vào 'Lượt chim ra / vào' (/birds) -> Chọn Nhà yến -> Bấm nút 'Áp dụng' -> Bảng thống kê xuất hiện!")


if __name__ == "__main__":
    try:
        seed_today_data()
    except Exception as e:
        print("[LỖI KẾT NỐI DB]:", e)
