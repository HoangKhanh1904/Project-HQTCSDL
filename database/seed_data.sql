USE SwiftletCare;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @SeedReadings TABLE (ReadingId BIGINT PRIMARY KEY);
DECLARE @SeedLockResult INT;

BEGIN TRY
    BEGIN TRANSACTION;
    EXEC @SeedLockResult = sys.sp_getapplock
        @Resource = N'SwiftletCare.SeedData', @LockMode = 'Exclusive',
        @LockOwner = 'Transaction', @LockTimeout = 10000;
    IF @SeedLockResult < 0
        THROW 52301, N'Không thể khóa quá trình seed dữ liệu.', 1;

-- USERS

IF NOT EXISTS (
    SELECT 1 FROM dbo.Users WHERE UserName = 'admin'
)
BEGIN
    INSERT INTO dbo.Users (UserName, PasswordHash, FullName, Role)
    VALUES ('admin', 'DEMO_HASH_NOT_FOR_LOGIN', N'Quản trị viên', 'ADMIN');
END;

IF NOT EXISTS (
    SELECT 1 FROM dbo.Users WHERE UserName = 'staff01'
)
BEGIN
    INSERT INTO dbo.Users (UserName, PasswordHash, FullName, Role)
    VALUES ('staff01', 'DEMO_HASH_NOT_FOR_LOGIN', N'Nguyễn Văn An', 'STAFF');
END;

IF NOT EXISTS (
    SELECT 1 FROM dbo.Users WHERE UserName = 'staff02'
)
BEGIN
    INSERT INTO dbo.Users (UserName, PasswordHash, FullName, Role)
    VALUES ('staff02', 'DEMO_HASH_NOT_FOR_LOGIN', N'Trần Thị Bình', 'STAFF');
END;

-- SWIFTLET HOUSES
INSERT INTO dbo.SwiftletHouses
    (HouseName, Address, ManagerId, Status)
SELECT
    N'Nhà yến Bình Dương',
    N'Thủ Dầu Một, Bình Dương',
    UserID,
    'ACTIVE'
FROM dbo.Users
WHERE UserName = 'admin'
  AND NOT EXISTS (
      SELECT 1
      FROM dbo.SwiftletHouses
      WHERE HouseName = N'Nhà yến Bình Dương'
  );

INSERT INTO dbo.SwiftletHouses
    (HouseName, Address, ManagerId, Status)
SELECT
    N'Nhà yến Đồng Nai',
    N'Biên Hòa, Đồng Nai',
    UserID,
    'ACTIVE'
FROM dbo.Users
WHERE UserName = 'staff01'
  AND NOT EXISTS (
      SELECT 1
      FROM dbo.SwiftletHouses
      WHERE HouseName = N'Nhà yến Đồng Nai'
  );

-- ZONES

INSERT INTO dbo.Zones
    (HouseId, ZoneName, Description, Status)
SELECT
    h.HouseId,
    z.ZoneName,
    z.Description,
    'ACTIVE'
FROM dbo.SwiftletHouses AS h
CROSS APPLY (
    VALUES
        (N'Tầng 1', N'Khu vực tầng một'),
        (N'Tầng 2', N'Khu vực tầng hai')
) AS z(ZoneName, Description)
WHERE h.HouseName IN (
    N'Nhà yến Bình Dương',
    N'Nhà yến Đồng Nai'
)
AND NOT EXISTS (
    SELECT 1
    FROM dbo.Zones AS existing
    WHERE existing.HouseId = h.HouseId
      AND existing.ZoneName = z.ZoneName
);

-- DEVICES

INSERT INTO dbo.Devices
    (ZoneId, DeviceName, DeviceType, Status, InstalledAt)
SELECT
    z.ZoneId,
    d.DeviceName,
    d.DeviceType,
    'ACTIVE',
    SYSDATETIME()
FROM dbo.Zones AS z
JOIN dbo.SwiftletHouses AS h
    ON z.HouseId = h.HouseId
CROSS APPLY (
    VALUES
        (N'Cảm biến môi trường', 'SENSOR'),
        (N'Quạt thông gió', 'FAN')
) AS d(DeviceName, DeviceType)
WHERE h.HouseName IN (
    N'Nhà yến Bình Dương',
    N'Nhà yến Đồng Nai'
)
AND z.ZoneName IN (N'Tầng 1', N'Tầng 2')
AND NOT EXISTS (
    SELECT 1
    FROM dbo.Devices AS existing
    WHERE existing.ZoneId = z.ZoneId
      AND existing.DeviceName = d.DeviceName
);

-- ENVIRONMENT THRESHOLDS

INSERT INTO dbo.EnvironmentThresholds
    (
        ZoneId,
        MinTemperature,
        MaxTemperature,
        MinHumidity,
        MaxHumidity
    )
SELECT
    z.ZoneId,
    26.00,
    32.00,
    70.00,
    90.00
FROM dbo.Zones AS z
JOIN dbo.SwiftletHouses AS h
    ON z.HouseId = h.HouseId
WHERE h.HouseName IN (
    N'Nhà yến Bình Dương',
    N'Nhà yến Đồng Nai'
)
AND z.ZoneName IN (N'Tầng 1', N'Tầng 2')
AND NOT EXISTS (
    SELECT 1
    FROM dbo.EnvironmentThresholds AS t
    WHERE t.ZoneId = z.ZoneId
);

-- SENSOR READINGS

INSERT INTO dbo.SensorReadings
    (DeviceId, Temperature, Humidity, RecordeAt)
OUTPUT inserted.ReadingId INTO @SeedReadings
SELECT
    d.DeviceId,
    r.Temperature,
    r.Humidity,
    DATEADD(MINUTE, r.MinutesAgo, SYSDATETIME())
FROM dbo.Devices AS d
JOIN dbo.Zones AS z
    ON d.ZoneId = z.ZoneId
JOIN dbo.SwiftletHouses AS h
    ON z.HouseId = h.HouseId
CROSS APPLY (
    VALUES
        (28.50, 80.00, -20),
        (29.20, 82.00, -15),
        (34.50, 85.00, -10),
        (30.00, 95.00, -5),
        (27.50, 78.00,  0)
) AS r(Temperature, Humidity, MinutesAgo)
WHERE d.DeviceType = 'SENSOR'
  AND h.HouseName IN (
      N'Nhà yến Bình Dương',
      N'Nhà yến Đồng Nai'
  )
  AND z.ZoneName IN (N'Tầng 1', N'Tầng 2')
  AND NOT EXISTS (
      SELECT 1
      FROM dbo.SensorReadings AS existing
      WHERE existing.DeviceId = d.DeviceId
  );

-- 7. ALERTS

INSERT INTO dbo.Alerts
    (ZoneId, ReadingId, AlertType, Message, Status)
SELECT
    z.ZoneId,
    r.ReadingId,
    a.AlertType,
    a.Message,
    'PENDING'
FROM dbo.SensorReadings AS r
JOIN @SeedReadings AS seeded ON seeded.ReadingId = r.ReadingId
JOIN dbo.Devices AS d
    ON r.DeviceId = d.DeviceId
JOIN dbo.Zones AS z
    ON d.ZoneId = z.ZoneId
JOIN dbo.EnvironmentThresholds AS t
    ON z.ZoneId = t.ZoneId
CROSS APPLY (
    VALUES
        (
            'HIGH_TEMP',
            CASE WHEN r.Temperature > t.MaxTemperature
                 THEN N'Nhiệt độ vượt ngưỡng tối đa'
            END
        ),
        (
            'LOW_TEMP',
            CASE WHEN r.Temperature < t.MinTemperature
                 THEN N'Nhiệt độ dưới ngưỡng tối thiểu'
            END
        ),
        (
            'HIGH_HUMIDITY',
            CASE WHEN r.Humidity > t.MaxHumidity
                 THEN N'Độ ẩm vượt ngưỡng tối đa'
            END
        ),
        (
            'LOW_HUMIDITY',
            CASE WHEN r.Humidity < t.MinHumidity
                 THEN N'Độ ẩm dưới ngưỡng tối thiểu'
            END
        )
) AS a(AlertType, Message)
WHERE d.DeviceType = 'SENSOR'
  AND a.Message IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM dbo.Alerts AS existing
      WHERE existing.ReadingId = r.ReadingId
        AND existing.AlertType = a.AlertType
  );

-- 9. CONTROL LOGS

INSERT INTO dbo.ControlLogs
    (DeviceId, UserId, Command, Result)
SELECT
    d.DeviceId,
    u.UserID,
    c.Command,
    'SUCCESS'
FROM dbo.Devices AS d
JOIN dbo.Zones AS z
    ON d.ZoneId = z.ZoneId
JOIN dbo.SwiftletHouses AS h
    ON z.HouseId = h.HouseId
CROSS JOIN dbo.Users AS u
CROSS APPLY (
    VALUES
        ('TURN_ON'),
        ('TURN_OFF')
) AS c(Command)
WHERE d.DeviceType = 'FAN'
  AND u.UserName = 'staff01'
  AND h.HouseName IN (
      N'Nhà yến Bình Dương',
      N'Nhà yến Đồng Nai'
  )
  AND NOT EXISTS (
      SELECT 1
      FROM dbo.ControlLogs AS existing
      WHERE existing.DeviceId = d.DeviceId
        AND existing.UserId = u.UserID
        AND existing.Command = c.Command
  );

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
