"""Lớp duy nhất biết TÊN procedure và TÊN tham số T-SQL.

!!! CHỐT SAU KHI ĐỌC thư mục database/ của TV1 !!!
Tên procedure và các cột kết quả (Success, Code, Message, ReadingId, AlertCount,
ThresholdStatus, Duplicate) lấy từ file giao việc, nhưng TÊN THAM SỐ là phỏng đoán.
Sai tên tham số thì SQL Server báo lỗi ngay khi gọi - chỉ cần sửa ở đây.
"""
from . import db

SP_INSERT_READING = "dbo.sp_InsertSensorReading"
INSERT_READING_PARAMS = {              # khóa trong code -> tên tham số T-SQL
    "device_id": "DeviceId",
    "temperature": "Temperature",
    "humidity": "Humidity",
    "co2_ppm": "CO2ppm",               # tùy chọn: chỉ truyền khi có giá trị
    "light_lux": "LightLux",           # tùy chọn: chỉ truyền khi có giá trị
    "source_event_id": "SourceEventId",
}
_OPTIONAL = {"co2_ppm", "light_lux"}


def insert_reading(reading):
    """Gọi sp_InsertSensorReading. Bỏ tham số tùy chọn khi None để tương thích bản proc cũ
    (chỉ có T/H). Trả về dict của dòng kết quả đầu tiên có cột Success."""
    params = {INSERT_READING_PARAMS[k]: v for k, v in reading.items()
              if k in INSERT_READING_PARAMS and not (k in _OPTIONAL and v is None)}
    for result_set in db.call_proc(SP_INSERT_READING, params):
        if result_set and "Success" in result_set[0]:
            return result_set[0]
    return None
