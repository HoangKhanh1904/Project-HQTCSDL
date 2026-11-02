
USE SwiftletCare;
GO

-- =========================================
-- PHAN 1: THONG KE CAM BIEN
-- =========================================

SELECT
    d.DeviceId,
    d.DeviceName,
    COUNT(r.ReadingId) AS SoLanDo,
    AVG(r.Temperature) AS NhietDoTrungBinh,
    AVG(r.Humidity) AS DoAmTrungBinh
FROM dbo.Devices AS d
JOIN dbo.SensorReadings AS r
    ON d.DeviceId = r.DeviceId
GROUP BY d.DeviceId, d.DeviceName;
GO

-- =========================================
-- PHAN 2: THONG KE CANH BAO
-- =========================================

SELECT
    AlertType AS LoaiCanhBao,
    COUNT(*) AS SoLuong
FROM dbo.Alerts
GROUP BY AlertType
ORDER BY SoLuong DESC;
GO

-- =========================================
-- PHAN 3: CTE PHAT HIEN BAT THUONG
-- =========================================

;WITH CanhBaoMoiTruong AS (
    SELECT
        h.HouseName,
        z.ZoneName,
        r.Temperature,
        r.Humidity,
        CASE
            WHEN r.Temperature > t.MaxTemperature
              OR r.Temperature < t.MinTemperature
              OR r.Humidity > t.MaxHumidity
              OR r.Humidity < t.MinHumidity
            THEN N'Bất thường'
            ELSE N'Bình thường'
        END AS TrangThai
    FROM dbo.SensorReadings AS r
    JOIN dbo.Devices AS d
        ON r.DeviceId = d.DeviceId
    JOIN dbo.Zones AS z
        ON d.ZoneId = z.ZoneId
    JOIN dbo.SwiftletHouses AS h
        ON z.HouseId = h.HouseId
    JOIN dbo.EnvironmentThresholds AS t
        ON z.ZoneId = t.ZoneId
)
SELECT *
FROM CanhBaoMoiTruong
WHERE TrangThai = N'Bất thường';
GO

-- =========================================
-- PHAN 4: FUNCTION KIEM TRA MOI TRUONG
-- Dung nguong mau: 26-32 C, 70-90%
-- =========================================

CREATE OR ALTER FUNCTION dbo.fn_KiemTraMoiTruong
(
    @NhietDo DECIMAL(5,2),
    @DoAm DECIMAL(5,2)
)
RETURNS NVARCHAR(20)
AS
BEGIN
    DECLARE @KetQua NVARCHAR(20);

    IF @NhietDo > 32 OR @NhietDo < 26
       OR @DoAm > 90 OR @DoAm < 70
        SET @KetQua = N'Bất thường';
    ELSE
        SET @KetQua = N'Bình thường';

    RETURN @KetQua;
END;
GO
-- PHAN 4B: KIEM TRA MOI TRUONG THEO ZONE

CREATE OR ALTER FUNCTION dbo.fn_KiemTraMoiTruongTheoZone
(
    @ZoneId INT,
    @NhietDo DECIMAL(5,2),
    @DoAm DECIMAL(5,2)
)
RETURNS NVARCHAR(30)
AS
BEGIN
    DECLARE @MinTemp DECIMAL(5,2);
    DECLARE @MaxTemp DECIMAL(5,2);
    DECLARE @MinHum DECIMAL(5,2);
    DECLARE @MaxHum DECIMAL(5,2);

    IF @ZoneId IS NULL
        RETURN N'Chưa cấu hình';

    IF @NhietDo IS NULL OR @DoAm IS NULL
        RETURN N'Chưa có dữ liệu';

    IF @NhietDo NOT BETWEEN -40 AND 100
       OR @DoAm NOT BETWEEN 0 AND 100
        RETURN N'Dữ liệu không hợp lệ';

    SELECT
        @MinTemp = MinTemperature,
        @MaxTemp = MaxTemperature,
        @MinHum = MinHumidity,
        @MaxHum = MaxHumidity
    FROM dbo.EnvironmentThresholds
    WHERE ZoneId = @ZoneId;

    IF @MinTemp IS NULL
        RETURN N'Chưa cấu hình';

    IF @NhietDo < @MinTemp OR @NhietDo > @MaxTemp
       OR @DoAm < @MinHum OR @DoAm > @MaxHum
        RETURN N'Bất thường';

    RETURN N'Bình thường';
END;
GO

-- =========================================
-- PHAN 5: KIEM TRA INDEX
-- =========================================

SELECT
    OBJECT_NAME(object_id) AS TenBang,
    name AS TenIndex,
    type_desc AS LoaiIndex
FROM sys.indexes
WHERE name IN (
    'IX_Readings_Device_Time',
    'IX_Alerts_Zone_Status',
    'IX_AlertActions_Alert_Time',
    'UX_Readings_Device_Event'
)
ORDER BY TenBang;
GO

-- =========================================
-- PHAN 6: QA TEST CASES
-- =========================================


-- Cac Test Case cu da duoc chuyen sang
-- scripts/qa_tests.sql
-- Khong su dung so luong du lieu mau co dinh.
GO

-- =========================================
-- PHAN 7: THONG KE LUOT CHIM IN / OUT
-- =========================================


-- =========================================
-- PHAN 7: THONG KE LUOT CHIM IN / OUT
-- =========================================

IF OBJECT_ID('dbo.BirdMovementEvents', 'U') IS NOT NULL
BEGIN
    EXEC sys.sp_executesql N'
        SELECT
            h.HouseName AS TenNhaYen,
            CAST(b.ObservedAt AS DATE) AS Ngay,
            SUM(CASE WHEN b.Direction = ''IN''
                THEN b.BirdCount ELSE 0 END) AS ChimVao,
            SUM(CASE WHEN b.Direction = ''OUT''
                THEN b.BirdCount ELSE 0 END) AS ChimRa,
            SUM(CASE WHEN b.Direction = ''IN''
                THEN b.BirdCount ELSE -b.BirdCount END)
                AS ChenhLechLuot
        FROM dbo.BirdMovementEvents b
        JOIN dbo.SwiftletHouses h
            ON b.HouseId = h.HouseId
        WHERE b.SourceType = ''SIMULATED''
        GROUP BY
            h.HouseId,
            h.HouseName,
            CAST(b.ObservedAt AS DATE)
        ORDER BY Ngay DESC, TenNhaYen;
    ';
END
ELSE
BEGIN
    PRINT 'PHAN 7: NOT TESTED - Chua co BirdMovementEvents';
END;
GO

-- =========================================
-- PHAN 8: CTE SO DO MOI NHAT
-- =========================================

;WITH LatestReading AS (
    SELECT
        DeviceId,
        Temperature,
        Humidity,
        RecordeAt,
        ROW_NUMBER() OVER (
            PARTITION BY DeviceId
            ORDER BY RecordeAt DESC, ReadingId DESC
        ) AS rn
    FROM dbo.SensorReadings
)
SELECT
    d.DeviceId,
    d.DeviceName,
    z.ZoneName,
    r.Temperature,
    r.Humidity,
    r.RecordeAt,
    CASE
        WHEN r.DeviceId IS NULL THEN N'NO_DATA'
        WHEN t.ZoneId IS NULL THEN N'UNCONFIGURED'
        ELSE dbo.fn_KiemTraMoiTruongTheoZone(
            z.ZoneId, r.Temperature, r.Humidity
        )
    END AS TrangThai
FROM dbo.Devices d
JOIN dbo.Zones z ON d.ZoneId = z.ZoneId
LEFT JOIN LatestReading r
    ON d.DeviceId = r.DeviceId AND r.rn = 1
LEFT JOIN dbo.EnvironmentThresholds t
    ON z.ZoneId = t.ZoneId
WHERE d.DeviceType = 'SENSOR'
ORDER BY d.DeviceId;
GO

-- =========================================
-- PHAN 9: CTE XEP HANG CANH BAO
-- =========================================

;WITH ThongKeCanhBao AS (
    SELECT
        h.HouseId,
        h.HouseName,
        z.ZoneId,
        z.ZoneName,
        COUNT(a.AlertId) AS SoCanhBao,
        SUM(CASE
            WHEN a.Status = 'PENDING' THEN 1
            ELSE 0
        END) AS SoChoXuLy
    FROM dbo.SwiftletHouses h
    JOIN dbo.Zones z
        ON h.HouseId = z.HouseId
    LEFT JOIN dbo.Alerts a
        ON z.ZoneId = a.ZoneId
    GROUP BY
        h.HouseId,
        h.HouseName,
        z.ZoneId,
        z.ZoneName
),
XepHang AS (
    SELECT
        *,
        DENSE_RANK() OVER (
            PARTITION BY HouseId
            ORDER BY SoCanhBao DESC
        ) AS HangCanhBao
    FROM ThongKeCanhBao
)
SELECT
    HouseName,
    ZoneName,
    SoCanhBao,
    SoChoXuLy,
    HangCanhBao
FROM XepHang
ORDER BY HouseName, HangCanhBao, ZoneName;
GO
