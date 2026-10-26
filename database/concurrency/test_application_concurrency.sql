USE SwiftletCare;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET LOCK_TIMEOUT 20000;

-- TEST OPTIONS
DECLARE @Mode VARCHAR(32) = 'HELP';
DECLARE @RunTag NVARCHAR(24) = N'demo01';
DECLARE @Prefix NVARCHAR(40) = CONCAT(N'__SC_CC__', @RunTag);
DECLARE @AdminA INT, @AdminB INT, @StaffA INT, @StaffB INT;
DECLARE @HouseId INT, @ZoneId INT, @DeviceId INT, @ReadingId BIGINT, @AlertId BIGINT;
DECLARE @Token BINARY(8), @Code VARCHAR(32);

IF @Mode = 'HELP'
BEGIN
    SELECT 'SETUP, ACK_A, ACK_B, VERIFY_ACK, THRESHOLD_A, THRESHOLD_B, VERIFY_THRESHOLD, CLEANUP' AS Modes;
    RETURN;
END;

IF @Mode NOT IN ('SETUP', 'ACK_A', 'ACK_B', 'VERIFY_ACK', 'THRESHOLD_A', 'THRESHOLD_B', 'VERIFY_THRESHOLD', 'CLEANUP')
   OR NULLIF(@RunTag, N'') IS NULL OR @RunTag LIKE N'%[^a-zA-Z0-9_-]%'
    THROW 53001, N'Mode hoặc RunTag không hợp lệ.', 1;
IF @@TRANCOUNT <> 0
    THROW 53002, N'Chạy test trên kết nối riêng, không có transaction đang mở.', 1;

-- SETUP
IF @Mode = 'SETUP'
BEGIN
    BEGIN TRY
        BEGIN TRANSACTION;
        IF EXISTS (
            SELECT 1 FROM dbo.Users WITH (UPDLOCK, HOLDLOCK)
            WHERE UserName IN (CONCAT(@Prefix, N'_admin_a'), CONCAT(@Prefix, N'_admin_b'),
                               CONCAT(@Prefix, N'_staff_a'), CONCAT(@Prefix, N'_staff_b'))
        )
           OR EXISTS (SELECT 1 FROM dbo.SwiftletHouses WHERE HouseName = @Prefix)
            THROW 53003, N'RunTag đã tồn tại. Chọn tag mới hoặc cleanup đúng fixture cũ.', 1;

        INSERT dbo.Users (UserName, PasswordHash, FullName, Role)
        VALUES (CONCAT(@Prefix, N'_admin_a'), N'DEMO_HASH_NOT_FOR_LOGIN', @Prefix, 'ADMIN');
        SET @AdminA = CONVERT(INT, SCOPE_IDENTITY());
        INSERT dbo.Users (UserName, PasswordHash, FullName, Role)
        VALUES (CONCAT(@Prefix, N'_admin_b'), N'DEMO_HASH_NOT_FOR_LOGIN', @Prefix, 'ADMIN');
        INSERT dbo.Users (UserName, PasswordHash, FullName, Role)
        VALUES (CONCAT(@Prefix, N'_staff_a'), N'DEMO_HASH_NOT_FOR_LOGIN', @Prefix, 'STAFF');
        INSERT dbo.Users (UserName, PasswordHash, FullName, Role)
        VALUES (CONCAT(@Prefix, N'_staff_b'), N'DEMO_HASH_NOT_FOR_LOGIN', @Prefix, 'STAFF');
        INSERT dbo.SwiftletHouses (HouseName, Address, ManagerId)
        VALUES (@Prefix, N'APPLICATION_CONCURRENCY_FIXTURE', @AdminA);
        SET @HouseId = CONVERT(INT, SCOPE_IDENTITY());
        INSERT dbo.Zones (HouseId, ZoneName, Description)
        VALUES (@HouseId, N'Concurrency', N'APPLICATION_CONCURRENCY_FIXTURE');
        SET @ZoneId = CONVERT(INT, SCOPE_IDENTITY());
        INSERT dbo.Devices (DeviceName, ZoneId, DeviceType)
        VALUES (N'Concurrency sensor', @ZoneId, 'SENSOR');
        SET @DeviceId = CONVERT(INT, SCOPE_IDENTITY());
        INSERT dbo.SensorReadings (DeviceId, Temperature, Humidity)
        VALUES (@DeviceId, 35, 80);
        SET @ReadingId = CONVERT(BIGINT, SCOPE_IDENTITY());
        INSERT dbo.EnvironmentThresholds (ZoneId, MinTemperature, MaxTemperature, MinHumidity, MaxHumidity)
        VALUES (@ZoneId, 26, 32, 70, 90);
        INSERT dbo.Alerts (ZoneId, ReadingId, AlertType, Message)
        VALUES (@ZoneId, @ReadingId, 'HIGH_TEMP', @Prefix);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;

-- FIXTURE
SELECT @AdminA = UserID FROM dbo.Users WHERE UserName = CONCAT(@Prefix, N'_admin_a');
SELECT @AdminB = UserID FROM dbo.Users WHERE UserName = CONCAT(@Prefix, N'_admin_b');
SELECT @StaffA = UserID FROM dbo.Users WHERE UserName = CONCAT(@Prefix, N'_staff_a');
SELECT @StaffB = UserID FROM dbo.Users WHERE UserName = CONCAT(@Prefix, N'_staff_b');
SELECT @HouseId = HouseId FROM dbo.SwiftletHouses
WHERE HouseName = @Prefix AND Address = N'APPLICATION_CONCURRENCY_FIXTURE' AND ManagerId = @AdminA;
SELECT @ZoneId = ZoneId FROM dbo.Zones
WHERE HouseId = @HouseId AND ZoneName = N'Concurrency' AND Description = N'APPLICATION_CONCURRENCY_FIXTURE';
SELECT @AlertId = AlertId FROM dbo.Alerts WHERE ZoneId = @ZoneId AND Message = @Prefix;

IF @ZoneId IS NULL OR @AlertId IS NULL OR @AdminA IS NULL OR @AdminB IS NULL OR @StaffA IS NULL OR @StaffB IS NULL
    THROW 53004, N'Không tìm thấy fixture đầy đủ. Chạy SETUP với RunTag mới.', 1;

IF @Mode = 'SETUP'
    SELECT @RunTag AS RunTag, @ZoneId AS ZoneId, @AlertId AS AlertId,
           @StaffA AS StaffA, @StaffB AS StaffB, @AdminA AS AdminA, @AdminB AS AdminB;

-- ACK SESSION A
IF @Mode = 'ACK_A'
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.Alerts WHERE AlertId = @AlertId AND Status = 'PENDING')
        THROW 53013, N'ACK_A cần cảnh báo PENDING của fixture mới.', 1;
    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC dbo.sp_AcknowledgeAlert @AlertId, @StaffA, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'OK' THROW 53005, N'ACK_A phải thành công trên fixture mới.', 1;
        WAITFOR DELAY '00:00:08';
        COMMIT TRANSACTION;
        SELECT 'PASS' AS TestResult, 'ACK_A' AS TestName;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;

-- ACK SESSION B
IF @Mode = 'ACK_B'
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.Alerts WHERE AlertId = @AlertId AND Status = 'PENDING')
        THROW 53014, N'Chạy ACK_B trước ACK_A trên fixture mới.', 1;
    WAITFOR DELAY '00:00:06';
    EXEC dbo.sp_AcknowledgeAlert @AlertId, @StaffB, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'INVALID_STATE' THROW 53006, N'ACK_B phải bị từ chối do INVALID_STATE.', 1;
    SELECT 'PASS' AS TestResult, 'ACK_B' AS TestName;
END;

-- ACK VERIFICATION
IF @Mode = 'VERIFY_ACK'
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.Alerts WHERE AlertId = @AlertId AND Status = 'ACKNOWLEDGED')
       OR (SELECT COUNT(*) FROM dbo.AlertActions WHERE AlertId = @AlertId AND ActionType = 'ACKNOWLEDGE') <> 1
       OR NOT EXISTS (SELECT 1 FROM dbo.AlertActions WHERE AlertId = @AlertId AND UserId = @StaffA AND ActionType = 'ACKNOWLEDGE')
        THROW 53007, N'Trạng thái hoặc lịch sử ACK không đúng.', 1;
    SELECT 'PASS' AS TestResult, 'VERIFY_ACK' AS TestName;
END;

-- THRESHOLD SESSION B
IF @Mode = 'THRESHOLD_B'
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId AND MinTemperature = 26 AND MaxTemperature = 32)
        THROW 53015, N'THRESHOLD_B cần ngưỡng ban đầu của fixture mới.', 1;
    SELECT @Token = RowVer FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId;
    SELECT @Token AS OriginalRowVerB;
    EXEC dbo.sp_GetEnvironmentThreshold @ZoneId;
    WAITFOR DELAY '00:00:12';
    EXEC dbo.sp_UpdateEnvironmentThreshold
        @ZoneId, 25, 31, 65, 85, @Token, @AdminB, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'CONCURRENCY_CONFLICT'
        THROW 53008, N'THRESHOLD_B phải bị từ chối do phiên bản cũ.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId AND MinTemperature = 27 AND MaxTemperature = 33 AND MinHumidity = 72 AND MaxHumidity = 92)
        THROW 53009, N'Thay đổi của session A đã bị ghi đè.', 1;
    EXEC dbo.sp_GetEnvironmentThreshold @ZoneId;
    SELECT @Token = RowVer FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId;
    EXEC dbo.sp_UpdateEnvironmentThreshold
        @ZoneId, 27, 33, 72, 92, @Token, @AdminB, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'OK' THROW 53010, N'Session B phải lưu được sau khi tải lại RowVer.', 1;
    SELECT 'PASS' AS TestResult, 'THRESHOLD_B_CONFLICT_AND_RELOAD' AS TestName;
END;

-- THRESHOLD SESSION A
IF @Mode = 'THRESHOLD_A'
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId AND MinTemperature = 26 AND MaxTemperature = 32)
        THROW 53016, N'THRESHOLD_A cần ngưỡng ban đầu của fixture mới.', 1;
    SELECT @Token = RowVer FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId;
    SELECT @Token AS OriginalRowVerA;
    EXEC dbo.sp_UpdateEnvironmentThreshold
        @ZoneId, 27, 33, 72, 92, @Token, @AdminA, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'OK' THROW 53011, N'THRESHOLD_A phải thành công.', 1;
    SELECT 'PASS' AS TestResult, 'THRESHOLD_A' AS TestName;
END;

-- THRESHOLD VERIFICATION
IF @Mode = 'VERIFY_THRESHOLD'
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId AND MinTemperature = 27 AND MaxTemperature = 33 AND MinHumidity = 72 AND MaxHumidity = 92)
        THROW 53012, N'Ngưỡng cuối cùng không giữ các giá trị của A.', 1;
    SELECT 'PASS' AS TestResult, 'VERIFY_THRESHOLD' AS TestName;
END;

-- CLEANUP
IF @Mode = 'CLEANUP'
BEGIN
    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE aa FROM dbo.AlertActions AS aa JOIN dbo.Alerts AS a ON a.AlertId = aa.AlertId WHERE a.ZoneId = @ZoneId;
        DELETE FROM dbo.Alerts WHERE ZoneId = @ZoneId;
        DELETE r FROM dbo.SensorReadings AS r JOIN dbo.Devices AS d ON d.DeviceId = r.DeviceId WHERE d.ZoneId = @ZoneId;
        DELETE cl FROM dbo.ControlLogs AS cl JOIN dbo.Devices AS d ON d.DeviceId = cl.DeviceId WHERE d.ZoneId = @ZoneId;
        DELETE FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId;
        DELETE FROM dbo.Devices WHERE ZoneId = @ZoneId;
        DELETE FROM dbo.Zones WHERE ZoneId = @ZoneId;
        DELETE FROM dbo.SwiftletHouses WHERE HouseId = @HouseId;
        DELETE FROM dbo.Users WHERE UserID IN (@AdminA, @AdminB, @StaffA, @StaffB) AND FullName = @Prefix;
        COMMIT TRANSACTION;
        SELECT 'PASS' AS TestResult, 'CLEANUP' AS TestName;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
