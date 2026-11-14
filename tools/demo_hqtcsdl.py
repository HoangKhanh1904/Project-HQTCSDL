"""Script hỗ trợ demo nhanh các tính năng môn HQTCSDL (Cursor, Deadlock, Isolation)."""

import argparse
import os
import sys
from pathlib import Path
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
load_dotenv(ROOT / ".env")
sys.path.insert(0, str(ROOT / "swiftletcare_backend"))

from app import create_app, db  # noqa: E402


def demo_cursor():
    print("=" * 70)
    print("DEMO CHƯƠNG 1: T-SQL CURSOR (dbo.sp_AuditZoneSensorsWithCursor)")
    print("=" * 70)
    print("Đang thực thi Stored Procedure duyệt Cursor qua các khu vực (Zone)...")
    with create_app().app_context():
        results = db.call_proc("dbo.sp_AuditZoneSensorsWithCursor", {"HouseId": None})
        rows = results[0] if results else []
        print(f"\n-> Đã kiểm tra xong qua Cursor. Tổng số khu vực: {len(rows)}\n")
        header = f"{'Zone ID':<8} | {'Tên khu vực':<20} | {'Nhà yến':<20} | {'Nhiệt độ':<9} | {'Độ ẩm':<7} | {'Trạng thái':<10}"
        print(header)
        print("-" * len(header))
        for r in rows:
            temp = f"{r.get('CurrentTemperature')}°C" if r.get('CurrentTemperature') is not None else "N/A"
            hum = f"{r.get('CurrentHumidity')}%" if r.get('CurrentHumidity') is not None else "N/A"
            print(f"{r.get('ZoneId'):<8} | {r.get('ZoneName',''):<20} | {r.get('HouseName',''):<20} | {temp:<9} | {hum:<7} | {r.get('AuditStatus',''):<10}")
            if r.get('ActionTaken'):
                print(f"   └─ Hành động: {r.get('ActionTaken')}")
        print("\n[THÀNH CÔNG] Procedure đã hoàn thành vòng đời Cursor: DECLARE -> OPEN -> FETCH NEXT -> WHILE -> CLOSE -> DEALLOCATE.")


def show_deadlock_guide():
    print("=" * 70)
    print("DEMO CHƯƠNG 3: KHÓA CHẾT (DEADLOCK) - 05_deadlock.sql")
    print("=" * 70)
    print("""
Để demo Deadlock một cách trực quan nhất cho giảng viên, bạn thực hiện như sau:
1. Mở SSMS (SQL Server Management Studio) hoặc Azure Data Studio.
2. Mở 2 cửa sổ Query (Session 1 và Session 2) kết nối vào database SwiftletCare.

Bước 1: Chuẩn bị dữ liệu tài khoản demo:
    USE SwiftletCare;
    EXEC sc_isolation.sp_Fixture N'demo_dl', 'RESET';

Bước 2: Chạy đồng thời để quan sát DEADLOCK (@Fix = 0):
    - Cửa sổ Query 1: EXEC sc_isolation.sp_deadlock_T1 N'demo_dl', 0;
    - Cửa sổ Query 2: EXEC sc_isolation.sp_deadlock_T2 N'demo_dl', 0;
    => Bấm F5 ở cả 2 tab gần như cùng lúc!
    => Kết quả: Sau ~3 giây, một bên sẽ báo lỗi 1205:
       "Transaction was deadlocked on lock resources with another process
        and has been chosen as the deadlock victim. Rerun the transaction."

Bước 3: Chạy giải pháp KHẮC PHỤC (@Fix = 1 - Quy tắc cấp khóa theo thứ tự):
    - Reset: EXEC sc_isolation.sp_Fixture N'demo_dl', 'RESET';
    - Cửa sổ Query 1: EXEC sc_isolation.sp_deadlock_T1 N'demo_dl', 1;
    - Cửa sổ Query 2: EXEC sc_isolation.sp_deadlock_T2 N'demo_dl', 1;
    => Bấm F5 ở cả 2 tab!
    => Kết quả: Cả 2 Session đều SUCCESS! Session 2 tự động xếp hàng chờ
       Session 1 giải phóng khóa, hoàn toàn không bị deadlock.
""")


def main():
    parser = argparse.ArgumentParser(description="Demo các tính năng HQTCSDL")
    parser.add_argument("--feature", choices=["cursor", "deadlock", "all"], default="all")
    args = parser.parse_args()

    if args.feature in ("cursor", "all"):
        try:
            demo_cursor()
        except Exception as e:
            print(f"[LƯU Ý] Không thể chạy Procedure trực tiếp (yêu cầu SQL Server đang chạy): {e}")
            print("File procedure nằm tại: database/procedures/sp_audit_zone_sensors.sql")

    if args.feature in ("deadlock", "all"):
        show_deadlock_guide()


if __name__ == "__main__":
    main()
