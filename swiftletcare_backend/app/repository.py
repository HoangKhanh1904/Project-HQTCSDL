"""Sensor ingest adapter verified against database-upgrade 212466eb on SQL Server.

Only named parameters are used; the legacy fifth OUTPUT argument stays untouched.
"""

from . import db

SP_INSERT_READING = "dbo.sp_InsertSensorReading"
INSERT_READING_PARAMS = {  # khóa trong code -> tên tham số T-SQL
    "device_id": "DeviceId",
    "temperature": "Temperature",
    "humidity": "Humidity",
    "co2_ppm": "CO2Ppm",  # optional; exact SQL parameter spelling
    "light_lux": "LightLux",  # tùy chọn: chỉ truyền khi có giá trị
    "source_event_id": "SourceEventId",
}
_OPTIONAL = {"co2_ppm", "light_lux"}


def insert_reading(reading):
    """Gọi sp_InsertSensorReading. Bỏ tham số tùy chọn khi None để tương thích bản proc cũ
    (chỉ có T/H). Trả về dict của dòng kết quả đầu tiên có cột Success."""
    params = {
        INSERT_READING_PARAMS[k]: v
        for k, v in reading.items()
        if k in INSERT_READING_PARAMS and not (k in _OPTIONAL and v is None)
    }
    for result_set in db.call_proc(SP_INSERT_READING, params):
        if result_set and "Success" in result_set[0]:
            return result_set[0]
    return None
