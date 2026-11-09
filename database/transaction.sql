USE SwiftletCare;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

-- TEST OPTIONS
DECLARE @RunTests BIT = 0;
IF @RunTests = 0
BEGIN
    SELECT N'Đặt @RunTests = 1 để chạy T01–T05 và regression trên dữ liệu riêng.' AS Instructions;
    RETURN;
END;
IF @@TRANCOUNT <> 0
    THROW 53100, N'Chạy test trên kết nối riêng không có transaction đang mở.', 1;

DECLARE @Tag NVARCHAR(45) = CONCAT(N'__SC_TX__', CONVERT(NVARCHAR(36), NEWID()));
DECLARE @AdminId INT, @StaffId INT, @InactiveId INT;
DECLARE @HouseId INT, @ZoneId INT, @EmptyZoneId INT, @DeviceId INT, @FanId INT;
DECLARE @ReadingId BIGINT, @AlertId BIGINT;
DECLARE @Code VARCHAR(32), @Token BINARY(8), @NewToken BINARY(8);
DECLARE @ActionCount INT, @ExpectedError INT, @FailureNumber INT, @Failure NVARCHAR(2048);
DECLARE @Impersonated BIT = 0;

BEGIN TRY
    -- FIXTURE
    BEGIN TRANSACTION;
    INSERT dbo.Users (UserName, PasswordHash, FullName, Role)
    VALUES (@Tag, N'DEMO_HASH_NOT_FOR_LOGIN', @Tag, 'ADMIN');
    SET @AdminId = CONVERT(INT, SCOPE_IDENTITY());
    INSERT dbo.Users (UserName, PasswordHash, FullName, Role)
    VALUES (CONCAT(@Tag, N'_s'), N'DEMO_HASH_NOT_FOR_LOGIN', @Tag, 'STAFF');
    SET @StaffId = CONVERT(INT, SCOPE_IDENTITY());
    INSERT dbo.Users (UserName, PasswordHash, FullName, Role, IsActive)
    VALUES (CONCAT(@Tag, N'_i'), N'DEMO_HASH_NOT_FOR_LOGIN', @Tag, 'STAFF', 0);
    SET @InactiveId = CONVERT(INT, SCOPE_IDENTITY());
    INSERT dbo.SwiftletHouses (HouseName, Address, ManagerId)
    VALUES (@Tag, N'TRANSACTION_REGRESSION_FIXTURE', @AdminId);
    SET @HouseId = CONVERT(INT, SCOPE_IDENTITY());
    INSERT dbo.Zones (HouseId, ZoneName) VALUES (@HouseId, N'Test');
    SET @ZoneId = CONVERT(INT, SCOPE_IDENTITY());
    INSERT dbo.Zones (HouseId, ZoneName) VALUES (@HouseId, N'NoThreshold');
    SET @EmptyZoneId = CONVERT(INT, SCOPE_IDENTITY());
    INSERT dbo.Devices (DeviceName, ZoneId, DeviceType) VALUES (@Tag, @ZoneId, 'SENSOR');
    SET @DeviceId = CONVERT(INT, SCOPE_IDENTITY());
    INSERT dbo.Devices (DeviceName, ZoneId, DeviceType) VALUES (@Tag, @ZoneId, 'FAN');
    SET @FanId = CONVERT(INT, SCOPE_IDENTITY());
    INSERT dbo.SensorReadings (DeviceId, Temperature, Humidity) VALUES (@DeviceId, 35, 80);
    SET @ReadingId = CONVERT(BIGINT, SCOPE_IDENTITY());
    INSERT dbo.Alerts (ZoneId, ReadingId, AlertType, Message) VALUES (@ZoneId, @ReadingId, 'HIGH_TEMP', @Tag);
    SET @AlertId = CONVERT(BIGINT, SCOPE_IDENTITY());
    INSERT dbo.EnvironmentThresholds (ZoneId, MinTemperature, MaxTemperature, MinHumidity, MaxHumidity)
    VALUES (@ZoneId, 26, 32, 70, 90);
    COMMIT TRANSACTION;

    -- T01 ACKNOWLEDGE
    EXEC dbo.sp_AcknowledgeAlert @AlertId, @StaffId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'OK'
       OR NOT EXISTS (SELECT 1 FROM dbo.Alerts WHERE AlertId = @AlertId AND Status = 'ACKNOWLEDGED')
       OR (SELECT COUNT(*) FROM dbo.AlertActions WHERE AlertId = @AlertId AND ActionType = 'ACKNOWLEDGE') <> 1
        THROW 53101, N'T01: ACK hoặc lịch sử không đúng.', 1;
    EXEC dbo.sp_AcknowledgeAlert @AlertId, @StaffId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'INVALID_STATE'
       OR (SELECT COUNT(*) FROM dbo.AlertActions WHERE AlertId = @AlertId) <> 1
        THROW 53102, N'T01: xác nhận trùng không được ngăn chặn.', 1;
    SELECT 'PASS' AS TestResult, 'T01' AS TestName;

    -- T02 RESOLVE
    BEGIN TRANSACTION;
    UPDATE dbo.Alerts SET Status = 'RESOLVED', ResolvedAt = SYSDATETIME()
    WHERE AlertId = @AlertId AND Status = 'ACKNOWLEDGED';
    IF @@ROWCOUNT <> 1 THROW 53103, N'T02: không thể resolve.', 1;
    INSERT dbo.AlertActions (AlertId, UserId, ActionType) VALUES (@AlertId, @StaffId, 'RESOLVE');
    COMMIT TRANSACTION;
    IF NOT EXISTS (SELECT 1 FROM dbo.Alerts WHERE AlertId = @AlertId AND Status = 'RESOLVED' AND ResolvedAt IS NOT NULL)
        THROW 53104, N'T02: trạng thái resolve không đúng.', 1;
    SELECT 'PASS' AS TestResult, 'T02' AS TestName;

    -- T03 REOPEN
    BEGIN TRANSACTION;
    UPDATE dbo.Alerts SET Status = 'PENDING', ResolvedAt = NULL
    WHERE AlertId = @AlertId AND Status = 'RESOLVED';
    IF @@ROWCOUNT <> 1 THROW 53105, N'T03: không thể reopen.', 1;
    INSERT dbo.AlertActions (AlertId, UserId, ActionType) VALUES (@AlertId, @StaffId, 'REOPEN');
    COMMIT TRANSACTION;
    IF NOT EXISTS (SELECT 1 FROM dbo.Alerts WHERE AlertId = @AlertId AND Status = 'PENDING' AND ResolvedAt IS NULL)
        THROW 53106, N'T03: trạng thái reopen không đúng.', 1;
    SELECT 'PASS' AS TestResult, 'T03' AS TestName;

    -- T04 CONTROL
    BEGIN TRANSACTION;
    INSERT dbo.ControlLogs (DeviceId, UserId, Command, Result)
    VALUES (@FanId, @StaffId, 'TURN_ON', 'SUCCESS');
    COMMIT TRANSACTION;
    IF (SELECT COUNT(*) FROM dbo.ControlLogs WHERE DeviceId = @FanId AND UserId = @StaffId) <> 1
        THROW 53107, N'T04: thiếu control log.', 1;
    SELECT 'PASS' AS TestResult, 'T04' AS TestName;

    -- T05 ROLLBACK
    SELECT @ActionCount = COUNT(*) FROM dbo.AlertActions WHERE AlertId = @AlertId;
    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE dbo.Alerts SET Status = 'ACKNOWLEDGED' WHERE AlertId = @AlertId AND Status = 'PENDING';
        IF @@ROWCOUNT <> 1 THROW 53108, N'T05: không thể cập nhật fixture.', 1;
        INSERT dbo.AlertActions (AlertId, UserId, ActionType) VALUES (@AlertId, @StaffId, 'INVALID_ACTION');
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        SET @ExpectedError = ERROR_NUMBER();
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    END CATCH;
    IF ISNULL(@ExpectedError, 0) <> 547
       OR NOT EXISTS (SELECT 1 FROM dbo.Alerts WHERE AlertId = @AlertId AND Status = 'PENDING')
       OR (SELECT COUNT(*) FROM dbo.AlertActions WHERE AlertId = @AlertId) <> @ActionCount
        THROW 53109, N'T05: phải có lỗi CHECK 547, trạng thái và lịch sử phải được rollback.', 1;
    SELECT 'PASS' AS TestResult, 'T05_STATUS_AND_HISTORY_ROLLBACK' AS TestName,
           @ExpectedError AS ExpectedErrorNumber, @@TRANCOUNT AS TranCount, XACT_STATE() AS XactState;

    -- VALIDATION
    EXEC dbo.sp_AcknowledgeAlert @AlertId, @InactiveId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'FORBIDDEN' THROW 53110, N'Tài khoản khóa vẫn xác nhận được.', 1;
    EXEC dbo.sp_AcknowledgeAlert @AlertId, NULL, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'VALIDATION_ERROR' THROW 53111, N'UserId NULL không bị chặn.', 1;
    IF EXISTS (SELECT 1 FROM dbo.Alerts WHERE AlertId = 9223372036854775807)
       OR EXISTS (SELECT 1 FROM dbo.Zones WHERE ZoneId = 2147483647)
        THROW 53112, N'ID kiểm thử không tồn tại đã bị chiếm.', 1;
    EXEC dbo.sp_AcknowledgeAlert 9223372036854775807, @StaffId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'ALERT_NOT_FOUND' THROW 53113, N'Không phân biệt cảnh báo không tồn tại.', 1;
    EXEC dbo.sp_GetEnvironmentThreshold 2147483647, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'ZONE_NOT_FOUND' THROW 53114, N'Không phân biệt Zone không tồn tại.', 1;
    EXEC dbo.sp_GetEnvironmentThreshold @EmptyZoneId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'THRESHOLD_NOT_FOUND' THROW 53115, N'Không phân biệt cấu hình chưa tồn tại.', 1;
    SELECT @Token = RowVer FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId;
    EXEC dbo.sp_GetEnvironmentThreshold @ZoneId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'OK' THROW 53116, N'Không đọc được cấu hình.', 1;
    EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, 27, 33, 72, 92, @Token, @StaffId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'FORBIDDEN' THROW 53117, N'STAFF nghiệp vụ vẫn sửa được ngưỡng.', 1;
    EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, 34, 33, 72, 92, @Token, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'VALIDATION_ERROR' THROW 53118, N'Min > Max không bị chặn.', 1;
    EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, -41, 33, 72, 92, @Token, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'VALIDATION_ERROR' THROW 53119, N'Nhiệt độ ngoài phạm vi không bị chặn.', 1;
    EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, 27, 33, 72, 101, @Token, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'VALIDATION_ERROR' THROW 53120, N'Độ ẩm ngoài phạm vi không bị chặn.', 1;
    EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, 27, 33, 72, 92, 0x010203040506070809, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'VALIDATION_ERROR' THROW 53121, N'Token quá 8 byte không bị chặn.', 1;
    EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, 27, 33, 72, 92, NULL, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'VALIDATION_ERROR' THROW 53138, N'Token NULL không bị chặn.', 1;
    EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, 27, 33, 72, 92, 0x01, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'VALIDATION_ERROR' THROW 53139, N'Token ngắn hơn 8 byte không bị chặn.', 1;
    EXEC dbo.sp_UpdateEnvironmentThreshold 2147483647, 27, 33, 72, 92, @Token, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'ZONE_NOT_FOUND' THROW 53140, N'UPDATE không phân biệt Zone không tồn tại.', 1;
    EXEC dbo.sp_UpdateEnvironmentThreshold @EmptyZoneId, 27, 33, 72, 92, @Token, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'THRESHOLD_NOT_FOUND' THROW 53141, N'UPDATE không phân biệt thiếu cấu hình.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId AND RowVer = @Token)
        THROW 53122, N'Validation đã làm thay đổi cấu hình.', 1;
    SELECT 'PASS' AS TestResult, 'VALIDATION_AND_NOT_FOUND' AS TestName;

    -- OPTIMISTIC CONCURRENCY
    EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, 27, 33, 72, 92, @Token, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'OK' THROW 53123, N'Cập nhật hợp lệ bị lỗi.', 1;
    SELECT @NewToken = RowVer FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId;
    IF @NewToken = @Token THROW 53124, N'RowVer không thay đổi.', 1;
    EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, 25, 31, 65, 85, @Token, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'CONCURRENCY_CONFLICT'
       OR NOT EXISTS (SELECT 1 FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId AND RowVer = @NewToken AND MinTemperature = 27)
        THROW 53125, N'Lost update không bị ngăn chặn.', 1;
    EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, 28, 34, 73, 93, @NewToken, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'OK' THROW 53126, N'Không thể lưu sau khi tải lại phiên bản.', 1;
    SELECT 'PASS' AS TestResult, 'STALE_TOKEN_AND_RELOAD' AS TestName;

    -- AMBIENT TRANSACTION
    BEGIN TRANSACTION;
    SELECT @Token = RowVer FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId;
    EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, 34, 28, 73, 93, @Token, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'VALIDATION_ERROR' OR XACT_STATE() <> 1 OR @@TRANCOUNT <> 1
        THROW 53127, N'Lỗi nghiệp vụ đã phá transaction của caller.', 1;
    EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, 29, 35, 74, 94, @Token, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'OK' OR @@TRANCOUNT <> 1
        THROW 53128, N'Procedure đã commit transaction của caller.', 1;
    ROLLBACK TRANSACTION;
    IF NOT EXISTS (SELECT 1 FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId AND MinTemperature = 28)
        THROW 53129, N'Rollback của caller không hoàn tác được thay đổi.', 1;
    SELECT 'PASS' AS TestResult, 'AMBIENT_TRANSACTION' AS TestName;

    -- STAFF PERMISSIONS
    EXECUTE AS USER = 'swiftlet_staff_demo';
    SET @Impersonated = 1;
    IF ISNULL(HAS_PERMS_BY_NAME('dbo.EnvironmentThresholds', 'OBJECT', 'UPDATE'), 1) <> 0
       OR ISNULL(HAS_PERMS_BY_NAME('dbo.Alerts', 'OBJECT', 'UPDATE'), 1) <> 0
       OR ISNULL(HAS_PERMS_BY_NAME('dbo.AlertActions', 'OBJECT', 'INSERT'), 1) <> 0
        THROW 53130, N'STAFF vẫn có quyền ghi trực tiếp.', 1;
    EXEC dbo.sp_AcknowledgeAlert @AlertId, @StaffId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'OK' THROW 53131, N'STAFF không gọi được ACK qua ownership chain.', 1;
    EXEC dbo.sp_GetEnvironmentThreshold @ZoneId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'OK' THROW 53132, N'STAFF không đọc được cấu hình qua procedure.', 1;
    SET @ExpectedError = NULL;
    BEGIN TRY
        EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, 27, 33, 72, 92, @Token, @AdminId;
    END TRY
    BEGIN CATCH
        SET @ExpectedError = ERROR_NUMBER();
    END CATCH;
    REVERT;
    SET @Impersonated = 0;
    IF ISNULL(@ExpectedError, 0) <> 229 THROW 53133, N'STAFF phải bị từ chối EXECUTE kể cả gửi UserId ADMIN.', 1;
    SELECT 'PASS' AS TestResult, 'STAFF_PERMISSIONS' AS TestName;

    -- ADMIN PERMISSIONS
    EXECUTE AS USER = 'swiftlet_admin_demo';
    SET @Impersonated = 1;
    IF ISNULL(HAS_PERMS_BY_NAME('dbo.EnvironmentThresholds', 'OBJECT', 'UPDATE'), 1) <> 0
       OR ISNULL(HAS_PERMS_BY_NAME('dbo.Alerts', 'OBJECT', 'UPDATE'), 1) <> 0
       OR ISNULL(HAS_PERMS_BY_NAME('dbo.AlertActions', 'OBJECT', 'INSERT'), 1) <> 0
        THROW 53134, N'ADMIN ứng dụng vẫn có quyền ghi trực tiếp.', 1;
    EXEC dbo.sp_GetEnvironmentThreshold @ZoneId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'OK' THROW 53135, N'ADMIN không gọi được getter.', 1;
    SELECT @Token = RowVer FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId;
    EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, 29, 35, 74, 94, @Token, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'OK' THROW 53137, N'ADMIN không cập nhật được qua procedure.', 1;
    EXEC dbo.sp_UpdateEnvironmentThreshold @ZoneId, 29, 35, 74, 94, @NewToken, @AdminId, @ResultCode = @Code OUTPUT;
    IF ISNULL(@Code, '') <> 'CONCURRENCY_CONFLICT' THROW 53136, N'ADMIN procedure phải phát hiện token cũ.', 1;
    REVERT;
    SET @Impersonated = 0;
    SELECT 'PASS' AS TestResult, 'ADMIN_PERMISSIONS' AS TestName;
END TRY
BEGIN CATCH
    SET @FailureNumber = ERROR_NUMBER();
    SET @Failure = ERROR_MESSAGE();
    IF @Impersonated = 1 REVERT;
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH;

-- CLEANUP
BEGIN TRY
    BEGIN TRANSACTION;
    DELETE FROM dbo.AlertActions WHERE AlertId = @AlertId;
    DELETE FROM dbo.Alerts WHERE AlertId = @AlertId;
    DELETE FROM dbo.ControlLogs WHERE DeviceId = @FanId;
    DELETE FROM dbo.SensorReadings WHERE ReadingId = @ReadingId;
    DELETE FROM dbo.EnvironmentThresholds WHERE ZoneId = @ZoneId;
    DELETE FROM dbo.Devices WHERE DeviceId IN (@DeviceId, @FanId);
    DELETE FROM dbo.Zones WHERE ZoneId IN (@ZoneId, @EmptyZoneId);
    DELETE FROM dbo.SwiftletHouses WHERE HouseId = @HouseId;
    DELETE FROM dbo.Users WHERE UserID IN (@AdminId, @StaffId, @InactiveId) AND FullName = @Tag;
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    SELECT @Tag AS FixtureTag, @FailureNumber AS OriginalErrorNumber, @Failure AS OriginalError;
    THROW;
END CATCH;

IF @FailureNumber IS NOT NULL
BEGIN
    SELECT 'FAIL' AS TestResult, @FailureNumber AS ErrorNumber, @Failure AS ErrorMessage;
    THROW 53199, @Failure, 1;
END;
SELECT 'PASS' AS TestResult, 'ALL_REGRESSION_TESTS_AND_CLEANUP' AS TestName;
GO
