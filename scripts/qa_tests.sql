USE SwiftletCare;
GO

-- TV4: ANALYTICS & QA
-- KIEM THU TU DONG SWIFTLETCARE
-- 4 INDEX + CAC TEST CASE QA

-- =========================================
-- QA23: KIEM TRA 4 INDEX
-- =========================================

USE SwiftletCare;
GO

DECLARE @KetQua TABLE (
    TenIndex VARCHAR(100),
    TrangThai VARCHAR(10)
);

-- INDEX 01: SENSOR READINGS
INSERT INTO @KetQua
SELECT 'IX_Readings_Device_Time',
CASE
    WHEN EXISTS (
        SELECT 1
        FROM sys.indexes i
        WHERE i.object_id = OBJECT_ID('dbo.SensorReadings')
          AND i.name = 'IX_Readings_Device_Time'
          AND i.type = 2
          AND i.is_unique = 0
          AND i.has_filter = 0
          AND i.is_disabled = 0
          AND (
              SELECT COUNT(*)
              FROM sys.index_columns ic
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
          ) = 5
          AND (
              SELECT STRING_AGG(
                  CONCAT(c.name, ':', ic.is_descending_key),
                  ','
              ) WITHIN GROUP (ORDER BY ic.key_ordinal)
              FROM sys.index_columns ic
              JOIN sys.columns c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
                AND ic.key_ordinal > 0
          ) = 'DeviceId:0,RecordeAt:1,ReadingId:1'
          AND (
              SELECT STRING_AGG(c.name, ',')
                     WITHIN GROUP (ORDER BY c.name)
              FROM sys.index_columns ic
              JOIN sys.columns c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
                AND ic.is_included_column = 1
          ) = 'Humidity,Temperature'
    )
    THEN 'PASS' ELSE 'FAIL'
END;

-- INDEX 02: ALERTS
INSERT INTO @KetQua
SELECT 'IX_Alerts_Zone_Status',
CASE
    WHEN EXISTS (
        SELECT 1
        FROM sys.indexes i
        WHERE i.object_id = OBJECT_ID('dbo.Alerts')
          AND i.name = 'IX_Alerts_Zone_Status'
          AND i.type = 2
          AND i.is_unique = 0
          AND i.has_filter = 0
          AND i.is_disabled = 0
          AND (
              SELECT STRING_AGG(
                  CONCAT(c.name, ':', ic.is_descending_key),
                  ','
              ) WITHIN GROUP (ORDER BY ic.key_ordinal)
              FROM sys.index_columns ic
              JOIN sys.columns c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
                AND ic.key_ordinal > 0
          ) = 'ZoneId:0,Status:0'
          AND (
              SELECT COUNT(*)
              FROM sys.index_columns ic
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
          ) = 2
    )
    THEN 'PASS' ELSE 'FAIL'
END;

-- INDEX 03: ALERT ACTIONS
INSERT INTO @KetQua
SELECT 'IX_AlertActions_Alert_Time',
CASE
    WHEN EXISTS (
        SELECT 1
        FROM sys.indexes i
        WHERE i.object_id = OBJECT_ID('dbo.AlertActions')
          AND i.name = 'IX_AlertActions_Alert_Time'
          AND i.type = 2
          AND i.is_unique = 0
          AND i.has_filter = 0
          AND i.is_disabled = 0
          AND (
              SELECT STRING_AGG(
                  CONCAT(c.name, ':', ic.is_descending_key),
                  ','
              ) WITHIN GROUP (ORDER BY ic.key_ordinal)
              FROM sys.index_columns ic
              JOIN sys.columns c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
                AND ic.key_ordinal > 0
          ) = 'AlertId:0,ActionAt:0,ActionId:0'
          AND (
              SELECT COUNT(*)
              FROM sys.index_columns ic
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
          ) = 3
    )
    THEN 'PASS' ELSE 'FAIL'
END;

-- INDEX 04: UNIQUE FILTERED INDEX
INSERT INTO @KetQua
SELECT 'UX_Readings_Device_Event',
CASE
    WHEN EXISTS (
        SELECT 1
        FROM sys.indexes i
        WHERE i.object_id = OBJECT_ID('dbo.SensorReadings')
          AND i.name = 'UX_Readings_Device_Event'
          AND i.type = 2
          AND i.is_unique = 1
          AND i.has_filter = 1
          AND i.is_disabled = 0
          AND UPPER(
              REPLACE(REPLACE(REPLACE(REPLACE(
              REPLACE(REPLACE(REPLACE(
                  i.filter_definition,
                  '[',''),']',''),'(',''),')',''),
                  ' ',''),CHAR(10),''),CHAR(13),'')
          ) = 'SOURCEEVENTIDISNOTNULL'
          AND (
              SELECT STRING_AGG(
                  CONCAT(c.name, ':', ic.is_descending_key),
                  ','
              ) WITHIN GROUP (ORDER BY ic.key_ordinal)
              FROM sys.index_columns ic
              JOIN sys.columns c
                ON c.object_id = ic.object_id
               AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
                AND ic.key_ordinal > 0
          ) = 'DeviceId:0,SourceEventId:0'
          AND (
              SELECT COUNT(*)
              FROM sys.index_columns ic
              WHERE ic.object_id = i.object_id
                AND ic.index_id = i.index_id
          ) = 2
    )
    THEN 'PASS' ELSE 'FAIL'
END;

-- HIEN THI KET QUA
SELECT TenIndex, TrangThai
FROM @KetQua;

-- BAO LOI NEU TEST KHONG DAT
IF (SELECT COUNT(*) FROM @KetQua
    WHERE TrangThai = 'PASS') <> 4
BEGIN
    THROW 51023, 'QA23 FAIL: Index sai cau truc hoac bi thieu', 1;
END;

PRINT 'QA23 PASS: Ca 4 Index deu dung';
GO

USE SwiftletCare;
GO

-- QA09: KIEM TRA FUNCTION VOI NULL
-- Tao du lieu test rieng, rollback sau khi kiem tra

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @UserId INT;
    DECLARE @HouseId INT;
    DECLARE @ZoneId INT;
    DECLARE @KetQua NVARCHAR(30);

    -- Tao user test
    INSERT INTO dbo.Users
        (UserName, PasswordHash, FullName, Role)
    VALUES
        (CONCAT('qa_', REPLACE(
            CONVERT(VARCHAR(36), NEWID()), '-', '')),
         'TEST_ONLY', N'QA Test User', 'STAFF');

    SET @UserId = SCOPE_IDENTITY();

    -- Tao nha yen test
    INSERT INTO dbo.SwiftletHouses
        (HouseName, ManagerId)
    VALUES (N'QA Test House', @UserId);

    SET @HouseId = SCOPE_IDENTITY();

    -- Tao Zone test
    INSERT INTO dbo.Zones (HouseId, ZoneName)
    VALUES (@HouseId, N'QA Test Zone');

    SET @ZoneId = SCOPE_IDENTITY();

    -- Tao nguong rieng
    INSERT INTO dbo.EnvironmentThresholds
        (ZoneId, MinTemperature, MaxTemperature,
         MinHumidity, MaxHumidity)
    VALUES (@ZoneId, 25, 33, 65, 95);

    -- Kiem tra input NULL
    SELECT @KetQua =
        dbo.fn_KiemTraMoiTruongTheoZone(
            @ZoneId, NULL, 80
        );

    IF @KetQua IS NULL
       OR @KetQua <> N'Chưa có dữ liệu'
        THROW 51009,
            'QA09 FAIL: Xu ly NULL khong dung', 1;

    -- Khong giu lai du lieu test
    ROLLBACK TRANSACTION;

    PRINT 'QA09: PASS';

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

USE SwiftletCare;
GO

-- QA04: KIEM TRA GIA TRI BIEN MIN/MAX
-- Du lieu test rieng, rollback sau khi kiem tra

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @UserId INT;
    DECLARE @HouseId INT;
    DECLARE @ZoneId INT;
    DECLARE @DeviceId INT;

    -- Tao user test
    INSERT INTO dbo.Users
        (UserName, PasswordHash, FullName, Role)
    VALUES
        (CONCAT('qa_', REPLACE(
            CONVERT(VARCHAR(36), NEWID()), '-', '')),
         'TEST_ONLY', N'QA Test User', 'STAFF');

    SET @UserId = SCOPE_IDENTITY();

    -- Tao nha yen va khu vuc test
    INSERT INTO dbo.SwiftletHouses
        (HouseName, ManagerId)
    VALUES (N'QA04 Test House', @UserId);

    SET @HouseId = SCOPE_IDENTITY();

    INSERT INTO dbo.Zones
        (HouseId, ZoneName)
    VALUES (@HouseId, N'QA04 Zone');

    SET @ZoneId = SCOPE_IDENTITY();

    -- Nguong: 25-33 C, 65-95%
    INSERT INTO dbo.EnvironmentThresholds
        (ZoneId, MinTemperature, MaxTemperature,
         MinHumidity, MaxHumidity)
    VALUES (@ZoneId, 25, 33, 65, 95);

    -- Tao cam bien
    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneId, N'QA04 Sensor', 'SENSOR');

    SET @DeviceId = SCOPE_IDENTITY();

    -- Thu dung gia tri MIN va MAX
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity)
    VALUES
        (@DeviceId, 25, 65),
        (@DeviceId, 33, 95);

    -- Kiem tra da ghi du 2 readings
    IF (
        SELECT COUNT(*)
        FROM dbo.SensorReadings
        WHERE DeviceId = @DeviceId
    ) <> 2
        THROW 51004,
            'QA04 FAIL: Khong ghi du readings', 1;

    -- MIN phai la Binh thuong
    IF dbo.fn_KiemTraMoiTruongTheoZone(
        @ZoneId, 25, 65
    ) <> N'Bình thường'
        THROW 51004,
            'QA04 FAIL: Sai gia tri MIN', 1;

    -- MAX phai la Binh thuong
    IF dbo.fn_KiemTraMoiTruongTheoZone(
        @ZoneId, 33, 95
    ) <> N'Bình thường'
        THROW 51004,
            'QA04 FAIL: Sai gia tri MAX', 1;

    -- Don du lieu test
    ROLLBACK TRANSACTION;

    PRINT 'QA04: PASS';

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

USE SwiftletCare;
GO

-- QA05: KIEM TRA LATEST SENSOR READING
-- Fixture rieng, rollback sau kiem thu

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @UserId INT;
    DECLARE @HouseId INT;
    DECLARE @ZoneId INT;
    DECLARE @DeviceId INT;
    DECLARE @ExpectedId BIGINT;
    DECLARE @ActualId BIGINT;
    DECLARE @OldTime DATETIME2;
    DECLARE @NewTime DATETIME2;

    SET @NewTime = SYSDATETIME();
    SET @OldTime = DATEADD(MINUTE, -10, @NewTime);

    -- Tao du lieu QA rieng
    INSERT INTO dbo.Users
        (UserName, PasswordHash, FullName, Role)
    VALUES (
        CONCAT('qa05_', REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', '')),
        'TEST_ONLY',
        N'QA05 Test User',
        'STAFF'
    );

    SET @UserId = SCOPE_IDENTITY();

    INSERT INTO dbo.SwiftletHouses (HouseName, ManagerId)
    VALUES (N'QA05 Test House', @UserId);

    SET @HouseId = SCOPE_IDENTITY();

    INSERT INTO dbo.Zones (HouseId, ZoneName)
    VALUES (@HouseId, N'QA05 Zone');

    SET @ZoneId = SCOPE_IDENTITY();

    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneId, N'QA05 Sensor', 'SENSOR');

    SET @DeviceId = SCOPE_IDENTITY();

    -- Reading cu
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity, RecordeAt)
    VALUES (@DeviceId, 27, 75, @OldTime);

    -- Reading moi thu nhat
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity, RecordeAt)
    VALUES (@DeviceId, 29, 80, @NewTime);

    -- Reading moi thu hai: cung thoi gian
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity, RecordeAt)
    VALUES (@DeviceId, 30, 85, @NewTime);

    SET @ExpectedId = SCOPE_IDENTITY();

    -- Lay reading moi nhat bang CTE
    ;WITH LatestReading AS (
        SELECT
            ReadingId,
            DeviceId,
            ROW_NUMBER() OVER (
                PARTITION BY DeviceId
                ORDER BY RecordeAt DESC, ReadingId DESC
            ) AS rn
        FROM dbo.SensorReadings
        WHERE DeviceId = @DeviceId
    )
    SELECT @ActualId = ReadingId
    FROM LatestReading
    WHERE rn = 1;

    -- Assert ket qua
    IF @ActualId IS NULL
       OR @ActualId <> @ExpectedId
        THROW 51005,
            'QA05 FAIL: Latest reading khong dung',
            1;

    -- Xoa fixture bang rollback
    ROLLBACK TRANSACTION;

    PRINT 'QA05: PASS';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

USE SwiftletCare;
GO

-- QA06: CAM BIEN CHUA CO SO DO
-- Tao du lieu test rieng va ROLLBACK

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @UserId INT;
    DECLARE @HouseId INT;
    DECLARE @ZoneId INT;
    DECLARE @DeviceId INT;
    DECLARE @TrangThai VARCHAR(20);

    -- Tao user QA
    INSERT INTO dbo.Users
        (UserName, PasswordHash, FullName, Role)
    VALUES (
        CONCAT('qa06_', REPLACE(
            CONVERT(VARCHAR(36), NEWID()), '-', '')),
        'TEST_ONLY',
        N'QA06 Test User',
        'STAFF'
    );

    SET @UserId = SCOPE_IDENTITY();

    -- Tao nha yen
    INSERT INTO dbo.SwiftletHouses
        (HouseName, ManagerId)
    VALUES (N'QA06 Test House', @UserId);

    SET @HouseId = SCOPE_IDENTITY();

    -- Tao khu vuc
    INSERT INTO dbo.Zones
        (HouseId, ZoneName)
    VALUES (@HouseId, N'QA06 Zone');

    SET @ZoneId = SCOPE_IDENTITY();

    -- Tao nguong moi truong
    INSERT INTO dbo.EnvironmentThresholds
        (ZoneId, MinTemperature, MaxTemperature,
         MinHumidity, MaxHumidity)
    VALUES (@ZoneId, 26, 32, 70, 90);

    -- Tao cam bien KHONG co reading
    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneId, N'QA06 Sensor', 'SENSOR');

    SET @DeviceId = SCOPE_IDENTITY();

    -- Kiem tra reading moi nhat
    ;WITH LatestReading AS (
        SELECT
            DeviceId,
            ReadingId,
            ROW_NUMBER() OVER (
                PARTITION BY DeviceId
                ORDER BY RecordeAt DESC, ReadingId DESC
            ) AS rn
        FROM dbo.SensorReadings
        WHERE DeviceId = @DeviceId
    )
    SELECT @TrangThai =
        CASE
            WHEN r.ReadingId IS NULL THEN 'NO_DATA'
            ELSE 'HAS_DATA'
        END
    FROM dbo.Devices d
    LEFT JOIN LatestReading r
        ON d.DeviceId = r.DeviceId
       AND r.rn = 1
    WHERE d.DeviceId = @DeviceId;

    -- Assert ket qua
    IF @TrangThai IS NULL
       OR @TrangThai <> 'NO_DATA'
        THROW 51006,
            'QA06 FAIL: Sensor khong tra NO_DATA', 1;

    ROLLBACK TRANSACTION;

    PRINT 'QA06: PASS';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

USE SwiftletCare;
GO

-- QA07: ZONE CHUA CO NGUONG MOI TRUONG
-- Du lieu test rieng, rollback sau kiem thu

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @UserId INT;
    DECLARE @HouseId INT;
    DECLARE @ZoneId INT;
    DECLARE @DeviceId INT;
    DECLARE @KetQua NVARCHAR(30);

    -- 1. Tao user QA
    INSERT INTO dbo.Users
        (UserName, PasswordHash, FullName, Role)
    VALUES (
        CONCAT('qa07_', REPLACE(
            CONVERT(VARCHAR(36), NEWID()), '-', '')),
        'TEST_ONLY',
        N'QA07 Test User',
        'STAFF'
    );

    SET @UserId = SCOPE_IDENTITY();

    -- 2. Tao nha yen
    INSERT INTO dbo.SwiftletHouses
        (HouseName, ManagerId)
    VALUES (N'QA07 Test House', @UserId);

    SET @HouseId = SCOPE_IDENTITY();

    -- 3. Tao Zone KHONG co nguong
    INSERT INTO dbo.Zones
        (HouseId, ZoneName)
    VALUES (@HouseId, N'QA07 Zone');

    SET @ZoneId = SCOPE_IDENTITY();

    -- 4. Tao cam bien
    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneId, N'QA07 Sensor', 'SENSOR');

    SET @DeviceId = SCOPE_IDENTITY();

    -- 5. Them mot so do hop le
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity)
    VALUES (@DeviceId, 29, 80);

    -- 6. Kiem tra reading duoc ghi
    IF (SELECT COUNT(*)
        FROM dbo.SensorReadings
        WHERE DeviceId = @DeviceId) <> 1
        THROW 51007,
            'QA07 FAIL: Khong ghi duoc reading', 1;

    -- 7. Dam bao Zone chua co nguong
    IF EXISTS (
        SELECT 1
        FROM dbo.EnvironmentThresholds
        WHERE ZoneId = @ZoneId
    )
        THROW 51007,
            'QA07 FAIL: Zone da co nguong', 1;

    -- 8. Kiem tra Function
    SET @KetQua =
        dbo.fn_KiemTraMoiTruongTheoZone(
            @ZoneId, 29, 80
        );

    IF @KetQua IS NULL
       OR @KetQua <> N'Chưa cấu hình'
        THROW 51007,
            'QA07 FAIL: Sai trang thai', 1;

    -- 9. Don du lieu test
    ROLLBACK TRANSACTION;

    PRINT 'QA07: PASS';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

USE SwiftletCare;
GO

-- QA08: KIEM TRA CTE PHAT HIEN BAT THUONG
-- Fixture rieng, rollback sau kiem thu

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @UserId INT;
    DECLARE @HouseId INT;
    DECLARE @ZoneId INT;
    DECLARE @DeviceId INT;
    DECLARE @SoBatThuong INT;

    -- Tao user test
    INSERT INTO dbo.Users
        (UserName, PasswordHash, FullName, Role)
    VALUES (
        CONCAT('qa08_', REPLACE(
            CONVERT(VARCHAR(36), NEWID()), '-', '')),
        'TEST_ONLY',
        N'QA08 Test User',
        'STAFF'
    );

    SET @UserId = SCOPE_IDENTITY();

    -- Tao nha yen
    INSERT INTO dbo.SwiftletHouses
        (HouseName, ManagerId)
    VALUES (N'QA08 Test House', @UserId);

    SET @HouseId = SCOPE_IDENTITY();

    -- Tao Zone
    INSERT INTO dbo.Zones (HouseId, ZoneName)
    VALUES (@HouseId, N'QA08 Zone');

    SET @ZoneId = SCOPE_IDENTITY();

    -- Nguong rieng: 25-33 C, 65-95%
    INSERT INTO dbo.EnvironmentThresholds
        (ZoneId, MinTemperature, MaxTemperature,
         MinHumidity, MaxHumidity)
    VALUES (@ZoneId, 25, 33, 65, 95);

    -- Tao cam bien
    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneId, N'QA08 Sensor', 'SENSOR');

    SET @DeviceId = SCOPE_IDENTITY();

    -- Tao 5 readings
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity)
    VALUES
        (@DeviceId, 29, 80),
        (@DeviceId, 34, 80),
        (@DeviceId, 29, 60),
        (@DeviceId, 34, 96),
        (@DeviceId, 25, 65);

    -- CTE phat hien bat thuong
    ;WITH AbnormalReadings AS (
        SELECT
            r.ReadingId,
            r.Temperature,
            r.Humidity
        FROM dbo.SensorReadings r
        JOIN dbo.Devices d
            ON r.DeviceId = d.DeviceId
        JOIN dbo.EnvironmentThresholds t
            ON d.ZoneId = t.ZoneId
        WHERE r.DeviceId = @DeviceId
          AND (
              r.Temperature < t.MinTemperature
              OR r.Temperature > t.MaxTemperature
              OR r.Humidity < t.MinHumidity
              OR r.Humidity > t.MaxHumidity
          )
    )
    SELECT @SoBatThuong = COUNT(*)
    FROM AbnormalReadings;

    -- Assert
    IF @SoBatThuong <> 3
        THROW 51008,
            'QA08 FAIL: So readings bat thuong khong dung', 1;

    -- Don du lieu test
    ROLLBACK TRANSACTION;

    PRINT 'QA08: PASS';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

USE SwiftletCare;
GO

-- QA10: KIEM TRA HAI GIA TRI CUNG BAT THUONG
-- Fixture rieng, rollback sau khi test

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @UserId INT;
    DECLARE @HouseId INT;
    DECLARE @ZoneId INT;
    DECLARE @DeviceId INT;
    DECLARE @ReadingId BIGINT;
    DECLARE @HighTemp INT;
    DECLARE @HighHumidity INT;

    -- Tao user test
    INSERT INTO dbo.Users
        (UserName, PasswordHash, FullName, Role)
    VALUES (
        CONCAT('qa10_', REPLACE(
            CONVERT(VARCHAR(36), NEWID()), '-', '')),
        'TEST_ONLY', N'QA10 Test User', 'STAFF'
    );

    SET @UserId = SCOPE_IDENTITY();

    -- Tao nha yen test
    INSERT INTO dbo.SwiftletHouses
        (HouseName, ManagerId)
    VALUES (N'QA10 Test House', @UserId);

    SET @HouseId = SCOPE_IDENTITY();

    -- Tao khu vuc
    INSERT INTO dbo.Zones (HouseId, ZoneName)
    VALUES (@HouseId, N'QA10 Zone');

    SET @ZoneId = SCOPE_IDENTITY();

    -- Cau hinh nguong
    INSERT INTO dbo.EnvironmentThresholds
        (ZoneId, MinTemperature, MaxTemperature,
         MinHumidity, MaxHumidity)
    VALUES (@ZoneId, 26, 32, 70, 90);

    -- Tao cam bien
    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneId, N'QA10 Sensor', 'SENSOR');

    SET @DeviceId = SCOPE_IDENTITY();

    -- Them reading voi ca hai gia tri vuot nguong
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity)
    VALUES (@DeviceId, 35, 95);

    SET @ReadingId = SCOPE_IDENTITY();

    -- Kiem tra hai loai vi pham
    SELECT
        @HighTemp = CASE
            WHEN r.Temperature > t.MaxTemperature
            THEN 1 ELSE 0 END,
        @HighHumidity = CASE
            WHEN r.Humidity > t.MaxHumidity
            THEN 1 ELSE 0 END
    FROM dbo.SensorReadings r
    JOIN dbo.Devices d
        ON r.DeviceId = d.DeviceId
    JOIN dbo.EnvironmentThresholds t
        ON d.ZoneId = t.ZoneId
    WHERE r.ReadingId = @ReadingId;

    -- Assert
    IF @HighTemp IS NULL
       OR @HighHumidity IS NULL
       OR @HighTemp <> 1
       OR @HighHumidity <> 1
        THROW 51010,
            'QA10 FAIL: Khong phat hien du 2 vi pham', 1;

    -- Don du lieu test
    ROLLBACK TRANSACTION;

    PRINT 'QA10: PASS';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

USE SwiftletCare;
GO

-- QA11: THONG KE ALERT THEO LOAI VA TRANG THAI
-- Fixture rieng, rollback sau kiem thu

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @UserId INT;
    DECLARE @HouseId INT;
    DECLARE @ZoneId INT;
    DECLARE @DeviceId INT;
    DECLARE @ReadingId BIGINT;
    DECLARE @i INT = 1;

    DECLARE @Actual TABLE (
        AlertType VARCHAR(30),
        Status VARCHAR(20),
        SoLuong INT
    );

    DECLARE @Expected TABLE (
        AlertType VARCHAR(30),
        Status VARCHAR(20),
        SoLuong INT
    );

    -- Tao user test
    INSERT INTO dbo.Users
        (UserName, PasswordHash, FullName, Role)
    VALUES (
        CONCAT('qa11_', REPLACE(
            CONVERT(VARCHAR(36), NEWID()), '-', '')),
        'TEST_ONLY', N'QA11 Test User', 'STAFF'
    );

    SET @UserId = SCOPE_IDENTITY();

    -- Tao nha yen
    INSERT INTO dbo.SwiftletHouses
        (HouseName, ManagerId)
    VALUES (N'QA11 Test House', @UserId);

    SET @HouseId = SCOPE_IDENTITY();

    -- Tao Zone
    INSERT INTO dbo.Zones (HouseId, ZoneName)
    VALUES (@HouseId, N'QA11 Zone');

    SET @ZoneId = SCOPE_IDENTITY();

    -- Tao cam bien
    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneId, N'QA11 Sensor', 'SENSOR');

    SET @DeviceId = SCOPE_IDENTITY();

    -- Tao 4 readings va 4 alerts
    WHILE @i <= 4
    BEGIN
        INSERT INTO dbo.SensorReadings
            (DeviceId, Temperature, Humidity)
        VALUES (
            @DeviceId,
            CASE WHEN @i = 4 THEN 29 ELSE 35 END,
            CASE WHEN @i = 4 THEN 95 ELSE 80 END
        );

        SET @ReadingId = SCOPE_IDENTITY();

        INSERT INTO dbo.Alerts
            (ZoneId, ReadingId, AlertType,
             Message, Status, ResolvedAt)
        VALUES (
            @ZoneId,
            @ReadingId,
            CASE WHEN @i = 4
                 THEN 'HIGH_HUMIDITY'
                 ELSE 'HIGH_TEMP' END,
            N'QA11 test alert',
            CASE
                WHEN @i <= 2 THEN 'PENDING'
                WHEN @i = 3 THEN 'ACKNOWLEDGED'
                ELSE 'RESOLVED'
            END,
            CASE WHEN @i = 4
                 THEN SYSDATETIME()
                 ELSE NULL END
        );

        SET @i = @i + 1;
    END;

    -- Ket qua thuc te
    INSERT INTO @Actual
        (AlertType, Status, SoLuong)
    SELECT
        AlertType,
        Status,
        COUNT(*)
    FROM dbo.Alerts
    WHERE ZoneId = @ZoneId
    GROUP BY AlertType, Status;

    -- Ket qua mong doi
    INSERT INTO @Expected
        (AlertType, Status, SoLuong)
    VALUES
        ('HIGH_TEMP', 'PENDING', 2),
        ('HIGH_TEMP', 'ACKNOWLEDGED', 1),
        ('HIGH_HUMIDITY', 'RESOLVED', 1);

    -- So sanh hai chieu, khong bo sot nhom thua
    IF EXISTS (
        SELECT * FROM @Expected
        EXCEPT
        SELECT * FROM @Actual
    )
    OR EXISTS (
        SELECT * FROM @Actual
        EXCEPT
        SELECT * FROM @Expected
    )
        THROW 51011,
            'QA11 FAIL: Thong ke Alert sai', 1;

    -- Don du lieu test
    ROLLBACK TRANSACTION;

    PRINT 'QA11: PASS';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

USE SwiftletCare;
GO

-- =========================================
-- QA03: KIEM TRA DU LIEU KHONG HOP LE
-- Test rieng, rollback sau kiem tra
-- =========================================

SET XACT_ABORT OFF;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @UserId INT;
    DECLARE @HouseId INT;
    DECLARE @ZoneId INT;
    DECLARE @DeviceId INT;
    DECLARE @TempRejected BIT = 0;
    DECLARE @HumidityRejected BIT = 0;

    -- Tao user test
    INSERT INTO dbo.Users
        (UserName, PasswordHash, FullName, Role)
    VALUES (
        CONCAT('qa03_', REPLACE(
            CONVERT(VARCHAR(36), NEWID()), '-', '')),
        'TEST_ONLY',
        N'QA03 Test User',
        'STAFF'
    );

    SET @UserId = SCOPE_IDENTITY();

    -- Tao nha yen test
    INSERT INTO dbo.SwiftletHouses
        (HouseName, ManagerId)
    VALUES (N'QA03 Test House', @UserId);

    SET @HouseId = SCOPE_IDENTITY();

    -- Tao khu vuc test
    INSERT INTO dbo.Zones
        (HouseId, ZoneName)
    VALUES (@HouseId, N'QA03 Zone');

    SET @ZoneId = SCOPE_IDENTITY();

    -- Tao cam bien test
    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneId, N'QA03 Sensor', 'SENSOR');

    SET @DeviceId = SCOPE_IDENTITY();

    -- TEST 1: NHIET DO 120 C
    BEGIN TRY
        INSERT INTO dbo.SensorReadings
            (DeviceId, Temperature, Humidity)
        VALUES (@DeviceId, 120, 80);
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() = 547
           AND ERROR_MESSAGE()
               LIKE '%Ck_Readings_Temperature%'
            SET @TempRejected = 1;
        ELSE
            THROW;
    END CATCH;

    -- TEST 2: DO AM 120%
    BEGIN TRY
        INSERT INTO dbo.SensorReadings
            (DeviceId, Temperature, Humidity)
        VALUES (@DeviceId, 29, 120);
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() = 547
           AND ERROR_MESSAGE()
               LIKE '%Ck_Readings_Humidity%'
            SET @HumidityRejected = 1;
        ELSE
            THROW;
    END CATCH;

    -- KIEM TRA KET QUA
    IF @TempRejected <> 1
       OR @HumidityRejected <> 1
        THROW 51003,
            'QA03 FAIL: Du lieu sai khong bi tu choi',
            1;

    -- Dam bao khong luu reading sai
    IF EXISTS (
        SELECT 1
        FROM dbo.SensorReadings
        WHERE DeviceId = @DeviceId
    )
        THROW 51003,
            'QA03 FAIL: Da luu reading khong hop le',
            1;

    -- Don du lieu test
    ROLLBACK TRANSACTION;

    PRINT 'QA03: PASS';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    PRINT 'QA03: FAIL';
    THROW;
END CATCH;
GO

SET XACT_ABORT ON;
GO

USE SwiftletCare;
GO

-- =========================================
-- QA12: KHONG DEM TRUNG ALERT
-- =========================================

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @UserId INT;
    DECLARE @HouseId INT;
    DECLARE @ZoneId INT;
    DECLARE @DeviceId INT;
    DECLARE @ReadingId BIGINT;
    DECLARE @SoDo INT;
    DECLARE @SoBatThuong INT;
    DECLARE @SoAlert INT;

    -- Tao user test
    INSERT INTO dbo.Users
        (UserName, PasswordHash, FullName, Role)
    VALUES (
        CONCAT('qa12_', REPLACE(
            CONVERT(VARCHAR(36), NEWID()), '-', '')),
        'TEST_ONLY', N'QA12 User', 'STAFF'
    );

    SET @UserId = SCOPE_IDENTITY();

    -- Tao nha yen va Zone rieng
    INSERT INTO dbo.SwiftletHouses
        (HouseName, ManagerId)
    VALUES (N'QA12 House', @UserId);

    SET @HouseId = SCOPE_IDENTITY();

    INSERT INTO dbo.Zones (HouseId, ZoneName)
    VALUES (@HouseId, N'QA12 Zone');

    SET @ZoneId = SCOPE_IDENTITY();

    -- Nguong moi truong
    INSERT INTO dbo.EnvironmentThresholds
        (ZoneId, MinTemperature, MaxTemperature,
         MinHumidity, MaxHumidity)
    VALUES (@ZoneId, 26, 32, 70, 90);

    -- Tao cam bien
    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneId, N'QA12 Sensor', 'SENSOR');

    SET @DeviceId = SCOPE_IDENTITY();

    -- 3 so do: 2 bat thuong, 1 binh thuong
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity)
    VALUES
        (@DeviceId, 35, 80),
        (@DeviceId, 36, 85),
        (@DeviceId, 29, 80);

    -- Lay ReadingId cua so do bat thuong
    SELECT TOP 1 @ReadingId = ReadingId
    FROM dbo.SensorReadings
    WHERE DeviceId = @DeviceId
      AND Temperature = 35;

    -- Tao dung 1 Alert
    INSERT INTO dbo.Alerts
        (ZoneId, ReadingId, AlertType,
         Message, Status)
    VALUES (
        @ZoneId, @ReadingId,
        'HIGH_TEMP', N'QA12 Test Alert',
        'PENDING'
    );

    -- Thong ke, dung DISTINCT de tranh dem trung
    SELECT
        @SoDo = COUNT(DISTINCT r.ReadingId),
        @SoBatThuong = COUNT(DISTINCT
            CASE
                WHEN r.Temperature < t.MinTemperature
                  OR r.Temperature > t.MaxTemperature
                  OR r.Humidity < t.MinHumidity
                  OR r.Humidity > t.MaxHumidity
                THEN r.ReadingId
            END),
        @SoAlert = COUNT(DISTINCT a.AlertId)
    FROM dbo.SensorReadings r
    JOIN dbo.Devices d
        ON r.DeviceId = d.DeviceId
    JOIN dbo.EnvironmentThresholds t
        ON d.ZoneId = t.ZoneId
    LEFT JOIN dbo.Alerts a
        ON a.ZoneId = d.ZoneId
    WHERE d.DeviceId = @DeviceId;

    -- Xem ket qua
    SELECT
        @SoDo AS TongSoDo,
        @SoBatThuong AS SoDoBatThuong,
        @SoAlert AS SoCanhBao;

    -- Kiem tra
    IF @SoDo IS NULL OR @SoDo <> 3
       OR @SoBatThuong IS NULL OR @SoBatThuong <> 2
       OR @SoAlert IS NULL OR @SoAlert <> 1
        THROW 51012,
            'QA12 FAIL: Thong ke bi trung Alert',
            1;

    -- Don du lieu test
    ROLLBACK TRANSACTION;

    PRINT 'QA12: PASS';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

USE SwiftletCare;
GO

-- =========================================
-- QA13: CHONG LUU TRUNG SOURCE EVENT
-- =========================================

SET XACT_ABORT OFF;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @UserId INT;
    DECLARE @HouseId INT;
    DECLARE @ZoneId INT;
    DECLARE @DeviceId INT;
    DECLARE @EventId UNIQUEIDENTIFIER = NEWID();
    DECLARE @DuplicateRejected BIT = 0;
    DECLARE @SoBanGhi INT;

    -- Tao User test
    INSERT INTO dbo.Users
        (UserName, PasswordHash, FullName, Role)
    VALUES (
        CONCAT('qa13_', REPLACE(
            CONVERT(VARCHAR(36), NEWID()), '-', '')),
        'TEST_ONLY',
        N'QA13 Test User',
        'STAFF'
    );

    SET @UserId = SCOPE_IDENTITY();

    -- Tao nha yen test
    INSERT INTO dbo.SwiftletHouses
        (HouseName, ManagerId)
    VALUES (N'QA13 Test House', @UserId);

    SET @HouseId = SCOPE_IDENTITY();

    -- Tao Zone test
    INSERT INTO dbo.Zones (HouseId, ZoneName)
    VALUES (@HouseId, N'QA13 Zone');

    SET @ZoneId = SCOPE_IDENTITY();

    -- Tao cam bien test
    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneId, N'QA13 Sensor', 'SENSOR');

    SET @DeviceId = SCOPE_IDENTITY();

    -- LAN 1: GUI SU KIEN
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity, SourceEventId)
    VALUES
        (@DeviceId, 29, 80, @EventId);

    -- LAN 2: GUI LAI CUNG EVENT
    BEGIN TRY
        INSERT INTO dbo.SensorReadings
            (DeviceId, Temperature, Humidity, SourceEventId)
        VALUES
            (@DeviceId, 29, 80, @EventId);
    END TRY
    BEGIN CATCH
        -- Loi trung khoa UNIQUE
        IF ERROR_NUMBER() IN (2601, 2627)
           AND ERROR_MESSAGE()
               LIKE '%UX_Readings_Device_Event%'
            SET @DuplicateRejected = 1;
        ELSE
            THROW;
    END CATCH;

    -- Dem so ban ghi cung EventId
    SELECT @SoBanGhi = COUNT(*)
    FROM dbo.SensorReadings
    WHERE DeviceId = @DeviceId
      AND SourceEventId = @EventId;

    -- Kiem tra
    IF @DuplicateRejected <> 1
       OR @SoBanGhi <> 1
        THROW 51013,
            'QA13 FAIL: Khong ngan duoc event trung',
            1;

    -- Xem ket qua
    SELECT
        @SoBanGhi AS SoBanGhiDaLuu,
        @DuplicateRejected AS DaChanTrung;

    -- Don du lieu test
    ROLLBACK TRANSACTION;

    PRINT 'QA13: PASS';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    PRINT 'QA13: FAIL';
    THROW;
END CATCH;
GO

SET XACT_ABORT ON;
GO

USE SwiftletCare;
GO

-- QA20: KIEM TRA LOC THOI GIAN [START, END)
-- Du lieu test rieng, ROLLBACK sau khi kiem tra

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @UserId INT;
    DECLARE @HouseId INT;
    DECLARE @ZoneId INT;
    DECLARE @DeviceId INT;
    DECLARE @SoDo INT;

    DECLARE @StartTime DATETIME2 = '2026-01-15T10:00:00';
    DECLARE @EndTime DATETIME2 = '2026-01-15T11:00:00';

    -- Tao user test
    INSERT INTO dbo.Users
        (UserName, PasswordHash, FullName, Role)
    VALUES (
        CONCAT('qa20_', REPLACE(
            CONVERT(VARCHAR(36), NEWID()), '-', '')),
        'TEST_ONLY', N'QA20 User', 'STAFF'
    );

    SET @UserId = SCOPE_IDENTITY();

    -- Tao nha yen
    INSERT INTO dbo.SwiftletHouses
        (HouseName, ManagerId)
    VALUES (N'QA20 House', @UserId);

    SET @HouseId = SCOPE_IDENTITY();

    -- Tao Zone
    INSERT INTO dbo.Zones (HouseId, ZoneName)
    VALUES (@HouseId, N'QA20 Zone');

    SET @ZoneId = SCOPE_IDENTITY();

    -- Tao cam bien
    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneId, N'QA20 Sensor', 'SENSOR');

    SET @DeviceId = SCOPE_IDENTITY();

    -- Tao 3 so do tai cac moc thoi gian
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity, RecordeAt)
    VALUES
        (@DeviceId, 27, 75, '2026-01-15T09:59:00'),
        (@DeviceId, 29, 80, '2026-01-15T10:00:00'),
        (@DeviceId, 30, 85, '2026-01-15T11:00:00');

    -- Loc theo [Start, End)
    SELECT @SoDo = COUNT(*)
    FROM dbo.SensorReadings
    WHERE DeviceId = @DeviceId
      AND RecordeAt >= @StartTime
      AND RecordeAt < @EndTime;

    -- Phai co dung 1 so do
    IF @SoDo <> 1
        THROW 51020,
            'QA20 FAIL: Loc thoi gian khong dung', 1;

    -- Don du lieu test
    ROLLBACK TRANSACTION;

    PRINT 'QA20: PASS';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

USE SwiftletCare;
GO

-- =========================================
-- QA21: LOC HOUSE / ZONE / DEVICE
-- VA KIEM TRA AVG / MIN / MAX
-- =========================================

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @UserId INT;
    DECLARE @HouseId INT;
    DECLARE @ZoneId INT;
    DECLARE @DeviceA INT;
    DECLARE @DeviceB INT;

    DECLARE @SoLanDo INT;
    DECLARE @AvgTemp DECIMAL(10,2);
    DECLARE @MinTemp DECIMAL(10,2);
    DECLARE @MaxTemp DECIMAL(10,2);
    DECLARE @AvgHum DECIMAL(10,2);

    -- Tao User test
    INSERT INTO dbo.Users
        (UserName, PasswordHash, FullName, Role)
    VALUES (
        CONCAT('qa21_', REPLACE(
            CONVERT(VARCHAR(36), NEWID()), '-', '')),
        'TEST_ONLY',
        N'QA21 User',
        'STAFF'
    );

    SET @UserId = SCOPE_IDENTITY();

    -- Tao nha yen test
    INSERT INTO dbo.SwiftletHouses
        (HouseName, ManagerId)
    VALUES (N'QA21 House', @UserId);

    SET @HouseId = SCOPE_IDENTITY();

    -- Tao Zone
    INSERT INTO dbo.Zones (HouseId, ZoneName)
    VALUES (@HouseId, N'QA21 Zone');

    SET @ZoneId = SCOPE_IDENTITY();

    -- Tao Sensor A
    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneId, N'QA21 Sensor A', 'SENSOR');

    SET @DeviceA = SCOPE_IDENTITY();

    -- Tao Sensor B
    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneId, N'QA21 Sensor B', 'SENSOR');

    SET @DeviceB = SCOPE_IDENTITY();

    -- Du lieu cho Sensor A
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity)
    VALUES
        (@DeviceA, 26, 70),
        (@DeviceA, 28, 80),
        (@DeviceA, 30, 90);

    -- Du lieu cho Sensor B
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity)
    VALUES (@DeviceB, 35, 85);

    -- Thong ke co loc House / Zone / Device
    SELECT
        @SoLanDo = COUNT(r.ReadingId),
        @AvgTemp = AVG(r.Temperature),
        @MinTemp = MIN(r.Temperature),
        @MaxTemp = MAX(r.Temperature),
        @AvgHum = AVG(r.Humidity)
    FROM dbo.SensorReadings r
    JOIN dbo.Devices d
        ON r.DeviceId = d.DeviceId
    JOIN dbo.Zones z
        ON d.ZoneId = z.ZoneId
    JOIN dbo.SwiftletHouses h
        ON z.HouseId = h.HouseId
    WHERE h.HouseId = @HouseId
      AND z.ZoneId = @ZoneId
      AND d.DeviceId = @DeviceA;

    -- Hien thi ket qua
    SELECT
        @SoLanDo AS SoLanDo,
        @AvgTemp AS AvgNhietDo,
        @MinTemp AS MinNhietDo,
        @MaxTemp AS MaxNhietDo,
        @AvgHum AS AvgDoAm;

    -- Kiem tra tu dong
    IF @SoLanDo IS NULL OR @SoLanDo <> 3
       OR @AvgTemp IS NULL OR @AvgTemp <> 28
       OR @MinTemp IS NULL OR @MinTemp <> 26
       OR @MaxTemp IS NULL OR @MaxTemp <> 30
       OR @AvgHum IS NULL OR @AvgHum <> 80
        THROW 51021,
            'QA21 FAIL: Thong ke cam bien sai', 1;

    -- Khong giu lai du lieu test
    ROLLBACK TRANSACTION;

    PRINT 'QA21: PASS';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

USE SwiftletCare;
GO

-- =========================================
-- QA01: KIEM TRA DATABASE VA CAC BANG
-- =========================================

BEGIN TRY

    -- Kiem tra dung database
    IF DB_NAME() <> 'SwiftletCare'
        THROW 51001,
            'QA01 FAIL: Sai database', 1;

    -- Danh sach 9 bang can co
    DECLARE @Expected TABLE (
        TableName SYSNAME
    );

    INSERT INTO @Expected (TableName)
    VALUES
        ('Users'),
        ('SwiftletHouses'),
        ('Zones'),
        ('Devices'),
        ('SensorReadings'),
        ('EnvironmentThresholds'),
        ('Alerts'),
        ('AlertActions'),
        ('ControlLogs');

    -- Kiem tra cac bang bi thieu
    SELECT
        e.TableName AS BangBiThieu
    FROM @Expected e
    WHERE OBJECT_ID(
        'dbo.' + e.TableName, 'U'
    ) IS NULL;

    -- Neu thieu bat ky bang nao thi FAIL
    IF EXISTS (
        SELECT 1
        FROM @Expected e
        WHERE OBJECT_ID(
            'dbo.' + e.TableName, 'U'
        ) IS NULL
    )
        THROW 51001,
            'QA01 FAIL: Thieu bang trong database', 1;

    PRINT 'QA01: PASS';

END TRY
BEGIN CATCH
    PRINT 'QA01: FAIL';
    THROW;
END CATCH;
GO

USE SwiftletCare;
GO

-- =========================================
-- QA02: KIEM TRA COT VA RANG BUOC
-- =========================================

BEGIN TRY

    -- 1. Danh sach cot quan trong
    DECLARE @Expected TABLE (
        TableName SYSNAME,
        ColumnName SYSNAME
    );

    INSERT INTO @Expected
        (TableName, ColumnName)
    VALUES
        ('Users', 'UserId'),
        ('Users', 'UserName'),
        ('Users', 'Role'),

        ('SwiftletHouses', 'HouseId'),
        ('SwiftletHouses', 'HouseName'),

        ('Zones', 'ZoneId'),
        ('Zones', 'HouseId'),

        ('Devices', 'DeviceId'),
        ('Devices', 'ZoneId'),
        ('Devices', 'DeviceType'),

        ('SensorReadings', 'ReadingId'),
        ('SensorReadings', 'DeviceId'),
        ('SensorReadings', 'Temperature'),
        ('SensorReadings', 'Humidity'),
        ('SensorReadings', 'RecordeAt'),
        ('SensorReadings', 'SourceEventId'),

        ('EnvironmentThresholds', 'ZoneId'),
        ('EnvironmentThresholds', 'MinTemperature'),
        ('EnvironmentThresholds', 'MaxTemperature'),
        ('EnvironmentThresholds', 'MinHumidity'),
        ('EnvironmentThresholds', 'MaxHumidity'),

        ('Alerts', 'AlertId'),
        ('Alerts', 'ZoneId'),
        ('Alerts', 'Status'),

        ('AlertActions', 'ActionId'),
        ('AlertActions', 'AlertId'),
        ('AlertActions', 'ActionAt');

    -- 2. Tim cot bi thieu
    DECLARE @Missing TABLE (
        TableName SYSNAME,
        ColumnName SYSNAME
    );

    INSERT INTO @Missing
    SELECT e.TableName, e.ColumnName
    FROM @Expected e
    WHERE NOT EXISTS (
        SELECT 1
        FROM sys.tables t
        JOIN sys.schemas s
            ON t.schema_id = s.schema_id
        JOIN sys.columns c
            ON c.object_id = t.object_id
        WHERE s.name = 'dbo'
          AND t.name = e.TableName
          AND c.name = e.ColumnName
    );

    -- 3. Hien thi cot bi thieu neu co
    SELECT TableName, ColumnName
    FROM @Missing;

    IF EXISTS (SELECT 1 FROM @Missing)
        THROW 51002,
            'QA02 FAIL: Thieu cot quan trong',
            1;

    -- 4. Kiem tra CHECK nhiet do
    IF NOT EXISTS (
        SELECT 1
        FROM sys.check_constraints
        WHERE parent_object_id =
            OBJECT_ID('dbo.SensorReadings')
          AND is_disabled = 0
          AND definition LIKE '%Temperature%'
    )
        THROW 51002,
            'QA02 FAIL: Thieu CHECK Temperature',
            1;

    -- 5. Kiem tra CHECK do am
    IF NOT EXISTS (
        SELECT 1
        FROM sys.check_constraints
        WHERE parent_object_id =
            OBJECT_ID('dbo.SensorReadings')
          AND is_disabled = 0
          AND definition LIKE '%Humidity%'
    )
        THROW 51002,
            'QA02 FAIL: Thieu CHECK Humidity',
            1;

    -- 6. Kiem tra khoa ngoai Reading -> Device
    IF NOT EXISTS (
        SELECT 1
        FROM sys.foreign_keys fk
        JOIN sys.foreign_key_columns fkc
            ON fk.object_id = fkc.constraint_object_id
        JOIN sys.columns pc
            ON pc.object_id = fkc.parent_object_id
           AND pc.column_id = fkc.parent_column_id
        JOIN sys.columns rc
            ON rc.object_id = fkc.referenced_object_id
           AND rc.column_id = fkc.referenced_column_id
        WHERE fk.parent_object_id =
            OBJECT_ID('dbo.SensorReadings')
          AND fk.referenced_object_id =
            OBJECT_ID('dbo.Devices')
          AND pc.name = 'DeviceId'
          AND rc.name = 'DeviceId'
          AND fk.is_disabled = 0
    )
        THROW 51002,
            'QA02 FAIL: Thieu FK Reading-Device',
            1;

    PRINT 'QA02: PASS';

END TRY
BEGIN CATCH
    PRINT 'QA02: FAIL';
    THROW;
END CATCH;
GO

USE SwiftletCare;
GO

-- =========================================
-- QA22: THONG KE VA XEP HANG ALERT
-- =========================================

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @UserId INT;
    DECLARE @HouseId INT;
    DECLARE @ZoneA INT;
    DECLARE @ZoneB INT;
    DECLARE @DeviceA INT;
    DECLARE @DeviceB INT;
    DECLARE @ReadingId BIGINT;

    -- Tao User
    INSERT INTO dbo.Users
        (UserName, PasswordHash, FullName, Role)
    VALUES (
        CONCAT('qa22_', REPLACE(
            CONVERT(VARCHAR(36), NEWID()), '-', '')),
        'TEST_ONLY', N'QA22 User', 'STAFF'
    );

    SET @UserId = SCOPE_IDENTITY();

    -- Tao nha yen
    INSERT INTO dbo.SwiftletHouses
        (HouseName, ManagerId)
    VALUES (N'QA22 Test House', @UserId);

    SET @HouseId = SCOPE_IDENTITY();

    -- Tao hai Zone
    INSERT INTO dbo.Zones (HouseId, ZoneName)
    VALUES (@HouseId, N'QA22 Zone A');

    SET @ZoneA = SCOPE_IDENTITY();

    INSERT INTO dbo.Zones (HouseId, ZoneName)
    VALUES (@HouseId, N'QA22 Zone B');

    SET @ZoneB = SCOPE_IDENTITY();

    -- Tao hai cam bien
    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneA, N'QA22 Sensor A', 'SENSOR');

    SET @DeviceA = SCOPE_IDENTITY();

    INSERT INTO dbo.Devices
        (ZoneId, DeviceName, DeviceType)
    VALUES (@ZoneB, N'QA22 Sensor B', 'SENSOR');

    SET @DeviceB = SCOPE_IDENTITY();

    -- Zone A: Alert 1 - PENDING
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity)
    VALUES (@DeviceA, 35, 80);

    SET @ReadingId = SCOPE_IDENTITY();

    INSERT INTO dbo.Alerts
        (ZoneId, ReadingId, AlertType, Message, Status)
    VALUES (
        @ZoneA, @ReadingId,
        'HIGH_TEMP', N'QA22 Alert 1', 'PENDING'
    );

    -- Zone A: Alert 2 - RESOLVED
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity)
    VALUES (@DeviceA, 36, 80);

    SET @ReadingId = SCOPE_IDENTITY();

    INSERT INTO dbo.Alerts
        (ZoneId, ReadingId, AlertType,
         Message, Status, ResolvedAt)
    VALUES (
        @ZoneA, @ReadingId,
        'HIGH_TEMP', N'QA22 Alert 2',
        'RESOLVED', SYSDATETIME()
    );

    -- Zone B: Alert 3 - PENDING
    INSERT INTO dbo.SensorReadings
        (DeviceId, Temperature, Humidity)
    VALUES (@DeviceB, 29, 95);

    SET @ReadingId = SCOPE_IDENTITY();

    INSERT INTO dbo.Alerts
        (ZoneId, ReadingId, AlertType, Message, Status)
    VALUES (
        @ZoneB, @ReadingId,
        'HIGH_HUMIDITY', N'QA22 Alert 3',
        'PENDING'
    );

    -- Luu ket qua thong ke
    DECLARE @Actual TABLE (
        ZoneId INT,
        SoCanhBao INT,
        SoChoXuLy INT,
        HangCanhBao BIGINT
    );

    -- CTE thong ke va xep hang
    ;WITH ThongKe AS (
        SELECT
            z.ZoneId,
            z.HouseId,
            COUNT(a.AlertId) AS SoCanhBao,
            SUM(CASE
                WHEN a.Status = 'PENDING'
                THEN 1 ELSE 0
            END) AS SoChoXuLy
        FROM dbo.Zones z
        LEFT JOIN dbo.Alerts a
            ON z.ZoneId = a.ZoneId
        WHERE z.HouseId = @HouseId
        GROUP BY z.ZoneId, z.HouseId
    ),
    XepHang AS (
        SELECT
            ZoneId,
            SoCanhBao,
            SoChoXuLy,
            DENSE_RANK() OVER (
                PARTITION BY HouseId
                ORDER BY SoCanhBao DESC
            ) AS HangCanhBao
        FROM ThongKe
    )
    INSERT INTO @Actual
    SELECT
        ZoneId,
        SoCanhBao,
        SoChoXuLy,
        HangCanhBao
    FROM XepHang;

    -- Hien thi ket qua
    SELECT
        ZoneId,
        SoCanhBao,
        SoChoXuLy,
        HangCanhBao
    FROM @Actual
    ORDER BY HangCanhBao;

    -- Kiem tra Zone A
    IF NOT EXISTS (
        SELECT 1
        FROM @Actual
        WHERE ZoneId = @ZoneA
          AND SoCanhBao = 2
          AND SoChoXuLy = 1
          AND HangCanhBao = 1
    )
        THROW 51022,
            'QA22 FAIL: Zone A thong ke sai', 1;

    -- Kiem tra Zone B
    IF NOT EXISTS (
        SELECT 1
        FROM @Actual
        WHERE ZoneId = @ZoneB
          AND SoCanhBao = 1
          AND SoChoXuLy = 1
          AND HangCanhBao = 2
    )
        THROW 51022,
            'QA22 FAIL: Zone B thong ke sai', 1;

    -- Dam bao khong co ket qua thua
    IF (SELECT COUNT(*) FROM @Actual) <> 2
        THROW 51022,
            'QA22 FAIL: Sai so Zone', 1;

    -- Khong giu du lieu test
    ROLLBACK TRANSACTION;

    PRINT 'QA22: PASS';

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO
