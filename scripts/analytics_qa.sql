
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

-- TC01: KIEM TRA TONG SO CANH BAO
IF (SELECT COUNT(*) FROM dbo.Alerts) = 8
    PRINT N'TC01: PASS';
ELSE
    PRINT N'TC01: FAIL';
GO

-- TC02: KIEM TRA LOAI CANH BAO
DECLARE @HighTemp INT;
DECLARE @HighHumidity INT;

SELECT @HighTemp = COUNT(*)
FROM dbo.Alerts
WHERE AlertType = 'HIGH_TEMP';

SELECT @HighHumidity = COUNT(*)
FROM dbo.Alerts
WHERE AlertType = 'HIGH_HUMIDITY';

IF @HighTemp = 4 AND @HighHumidity = 4
    PRINT N'TC02: PASS';
ELSE
    PRINT N'TC02: FAIL';
GO

-- TC03: KIEM TRA NHIET DO KHONG HOP LE
SET XACT_ABORT OFF;

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity)
    SELECT TOP 1 DeviceId, 120, 80
    FROM dbo.Devices
    WHERE DeviceType = 'SENSOR';

    IF @@ROWCOUNT = 0
        PRINT N'TC03: FAIL - Khong co cam bien';
    ELSE
        PRINT N'TC03: FAIL - Chap nhan nhiet do sai';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    IF ERROR_NUMBER() = 547
       AND ERROR_MESSAGE() LIKE '%Ck_Readings_Temperature%'
        PRINT N'TC03: PASS';
    ELSE
        PRINT N'TC03: FAIL';
END CATCH;
GO

-- TC04: KIEM TRA DO AM KHONG HOP LE
SET XACT_ABORT OFF;

BEGIN TRY
    BEGIN TRANSACTION;

    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity)
    SELECT TOP 1 DeviceId, 29, 120
    FROM dbo.Devices
    WHERE DeviceType = 'SENSOR';

    IF @@ROWCOUNT = 0
        PRINT N'TC04: FAIL - Khong co cam bien';
    ELSE
        PRINT N'TC04: FAIL - Chap nhan do am sai';

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    IF ERROR_NUMBER() = 547
       AND ERROR_MESSAGE() LIKE '%Ck_Readings_Humidity%'
        PRINT N'TC04: PASS';
    ELSE
        PRINT N'TC04: FAIL';
END CATCH;
GO

-- TC05: KIEM TRA FUNCTION
DECLARE @BinhThuong NVARCHAR(20);
DECLARE @BatThuong NVARCHAR(20);

SELECT @BinhThuong =
    dbo.fn_KiemTraMoiTruong(29, 80);

SELECT @BatThuong =
    dbo.fn_KiemTraMoiTruong(35, 95);

IF @BinhThuong = N'Bình thường'
   AND @BatThuong = N'Bất thường'
    PRINT N'TC05: PASS';
ELSE
    PRINT N'TC05: FAIL';
GO
