USE SwiftletCare;
GO

-- =========================================================================
-- Procedure: dbo.sp_AuditZoneSensorsWithCursor
-- Mục đích: Minh họa kỹ thuật CURSOR trong T-SQL (Chương 1 giáo trình HQTCSDL)
-- Nghiệp vụ: Duyệt qua từng khu vực (Zone) đang hoạt động, đọc số đo cảm biến mới
--            nhất và đối chiếu với ngưỡng môi trường (EnvironmentThresholds).
--            Nếu vượt ngưỡng mà chưa có cảnh báo PENDING thì tự động kích hoạt Alert.
-- Các lệnh Cursor: DECLARE, OPEN, FETCH NEXT, @@FETCH_STATUS, CLOSE, DEALLOCATE
-- =========================================================================

CREATE OR ALTER PROCEDURE dbo.sp_AuditZoneSensorsWithCursor
    @HouseId INT = NULL,                  -- NULL: kiểm tra toàn bộ các nhà yến
    @AutoGenerateAlert BIT = 1,           -- 1: Tự động ghi nhận Alert nếu vượt ngưỡng
    @TotalZonesChecked INT = NULL OUTPUT, -- Số khu vực đã kiểm tra qua Cursor
    @AbnormalZonesCount INT = NULL OUTPUT -- Số khu vực phát hiện bất thường môi trường
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Khởi tạo biến đầu ra
    SET @TotalZonesChecked = 0;
    SET @AbnormalZonesCount = 0;

    -- Khai báo các biến lưu trữ dữ liệu từ Cursor
    DECLARE @CurZoneId INT;
    DECLARE @CurZoneName NVARCHAR(100);
    DECLARE @CurHouseName NVARCHAR(100);
    DECLARE @MinTemp DECIMAL(5,2), @MaxTemp DECIMAL(5,2);
    DECLARE @MinHum DECIMAL(5,2), @MaxHum DECIMAL(5,2);
    DECLARE @LatestReadingId BIGINT;
    DECLARE @LatestTemp DECIMAL(5,2);
    DECLARE @LatestHum DECIMAL(5,2);
    DECLARE @AlertMessage NVARCHAR(500);

    -- Bảng tạm lưu kết quả audit để trả về cho người dùng/ứng dụng
    DECLARE @AuditResults TABLE (
        ZoneId INT,
        ZoneName NVARCHAR(100),
        HouseName NVARCHAR(100),
        CurrentTemperature DECIMAL(5,2),
        CurrentHumidity DECIMAL(5,2),
        TemperatureRange NVARCHAR(50),
        HumidityRange NVARCHAR(50),
        AuditStatus NVARCHAR(50),
        ActionTaken NVARCHAR(200)
    );

    -- 1. KHAI BÁO CURSOR (DECLARE CURSOR)
    -- Lấy danh sách các Zone đang ACTIVE và có cấu hình ngưỡng môi trường
    DECLARE zone_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT 
            z.ZoneId, 
            z.ZoneName, 
            h.HouseName,
            t.MinTemperature, 
            t.MaxTemperature,
            t.MinHumidity, 
            t.MaxHumidity
        FROM dbo.Zones z
        INNER JOIN dbo.SwiftletHouses h ON z.HouseId = h.HouseId
        INNER JOIN dbo.EnvironmentThresholds t ON z.ZoneId = t.ZoneId
        WHERE z.Status = 'ACTIVE'
          AND (@HouseId IS NULL OR z.HouseId = @HouseId);

    -- 2. MỞ CURSOR (OPEN)
    OPEN zone_cursor;

    -- 3. ĐỌC DÒNG ĐẦU TIÊN (FETCH NEXT INTO)
    FETCH NEXT FROM zone_cursor INTO 
        @CurZoneId, @CurZoneName, @CurHouseName,
        @MinTemp, @MaxTemp, @MinHum, @MaxHum;

    -- 4. VÒNG LẶP DUYỆT TỪNG DÒNG (WHILE @@FETCH_STATUS = 0)
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @TotalZonesChecked = @TotalZonesChecked + 1;

        -- Tìm số đo cảm biến SENSOR mới nhất trong khu vực hiện tại
        SELECT TOP (1)
            @LatestReadingId = sr.ReadingId,
            @LatestTemp = sr.Temperature,
            @LatestHum = sr.Humidity
        FROM dbo.SensorReadings sr
        INNER JOIN dbo.Devices d ON sr.DeviceId = d.DeviceId
        WHERE d.ZoneId = @CurZoneId
          AND d.DeviceType = 'SENSOR'
          AND d.Status = 'ACTIVE'
        ORDER BY sr.RecordeAt DESC, sr.ReadingId DESC;

        -- Kiểm tra tình trạng bất thường
        IF @LatestReadingId IS NULL
        BEGIN
            INSERT INTO @AuditResults
            VALUES (@CurZoneId, @CurZoneName, @CurHouseName, NULL, NULL,
                    CONCAT(@MinTemp, N' - ', @MaxTemp), CONCAT(@MinHum, N' - ', @MaxHum),
                    N'NO_DATA', N'Không tìm thấy số đo từ cảm biến');
        END
        ELSE
        BEGIN
            DECLARE @IsOutOfRange BIT = 0;
            DECLARE @AlertType VARCHAR(30) = NULL;

            IF @LatestTemp > @MaxTemp
            BEGIN
                SET @IsOutOfRange = 1;
                SET @AlertType = 'HIGH_TEMP';
                SET @AlertMessage = CONCAT(N'Nhiệt độ hiện tại (', @LatestTemp, N'°C) vượt ngưỡng tối đa (', @MaxTemp, N'°C)');
            END
            ELSE IF @LatestTemp < @MinTemp
            BEGIN
                SET @IsOutOfRange = 1;
                SET @AlertType = 'LOW_TEMP';
                SET @AlertMessage = CONCAT(N'Nhiệt độ hiện tại (', @LatestTemp, N'°C) thấp hơn ngưỡng tối thiểu (', @MinTemp, N'°C)');
            END
            ELSE IF @LatestHum > @MaxHum
            BEGIN
                SET @IsOutOfRange = 1;
                SET @AlertType = 'HIGH_HUMIDITY';
                SET @AlertMessage = CONCAT(N'Độ ẩm hiện tại (', @LatestHum, N'%) vượt ngưỡng tối đa (', @MaxHum, N'%)');
            END
            ELSE IF @LatestHum < @MinHum
            BEGIN
                SET @IsOutOfRange = 1;
                SET @AlertType = 'LOW_HUMIDITY';
                SET @AlertMessage = CONCAT(N'Độ ẩm hiện tại (', @LatestHum, N'%) thấp hơn ngưỡng tối thiểu (', @MinHum, N'%)');
            END

            IF @IsOutOfRange = 1
            BEGIN
                SET @AbnormalZonesCount = @AbnormalZonesCount + 1;
                DECLARE @ActionTaken NVARCHAR(200) = N'Phát hiện vượt ngưỡng';

                -- Nếu bật tùy chọn tạo cảnh báo và chưa có cảnh báo PENDING trùng loại
                IF @AutoGenerateAlert = 1 AND @AlertType IS NOT NULL
                BEGIN
                    IF NOT EXISTS (
                        SELECT 1 FROM dbo.Alerts
                        WHERE ZoneId = @CurZoneId 
                          AND AlertType = @AlertType 
                          AND Status = 'PENDING'
                    )
                    BEGIN
                        INSERT INTO dbo.Alerts (ZoneId, ReadingId, AlertType, Message, Status, CreatedAt)
                        VALUES (@CurZoneId, @LatestReadingId, @AlertType, @AlertMessage, 'PENDING', SYSDATETIME());

                        SET @ActionTaken = CONCAT(N'Đã tự động tạo cảnh báo: ', @AlertType);
                    END
                    ELSE
                    BEGIN
                        SET @ActionTaken = N'Cảnh báo PENDING đã tồn tại, bỏ qua tạo mới';
                    END
                END

                INSERT INTO @AuditResults
                VALUES (@CurZoneId, @CurZoneName, @CurHouseName, @LatestTemp, @LatestHum,
                        CONCAT(@MinTemp, N' - ', @MaxTemp), CONCAT(@MinHum, N' - ', @MaxHum),
                        N'WARNING', @ActionTaken);
            END
            ELSE
            BEGIN
                INSERT INTO @AuditResults
                VALUES (@CurZoneId, @CurZoneName, @CurHouseName, @LatestTemp, @LatestHum,
                        CONCAT(@MinTemp, N' - ', @MaxTemp), CONCAT(@MinHum, N' - ', @MaxHum),
                        N'NORMAL', N'Chỉ số ổn định trong ngưỡng an toàn');
            END
        END

        -- Reset biến cho vòng lặp tiếp theo
        SET @LatestReadingId = NULL;
        SET @LatestTemp = NULL;
        SET @LatestHum = NULL;

        -- Đọc dòng tiếp theo của Cursor
        FETCH NEXT FROM zone_cursor INTO 
            @CurZoneId, @CurZoneName, @CurHouseName,
            @MinTemp, @MaxTemp, @MinHum, @MaxHum;
    END;

    -- 5. ĐÓNG CURSOR (CLOSE)
    CLOSE zone_cursor;

    -- 6. GIẢI PHÓNG VÙNG NHỚ CURSOR (DEALLOCATE)
    DEALLOCATE zone_cursor;

    -- Trả kết quả bảng chi tiết
    SELECT * FROM @AuditResults ORDER BY ZoneId;
END;
GO
