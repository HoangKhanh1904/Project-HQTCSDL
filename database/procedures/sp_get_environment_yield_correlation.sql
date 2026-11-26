-- P4 (nhanh update_application): SP bao cao tuong quan moi truong - nang suat.
-- Goc: ke hoach Giai doan 1, goi P4 "Analytics va bao cao tuong quan
-- moi truong - nang suat": them SP sp_GetEnvironmentYieldCorrelation gom
-- so gio trong nguong theo nha/khu + luong chim IN/OUT theo ngay.
-- Hien chua co bang ghi so to thu hoach, nen "nang suat" tam do bang
-- luong chim ra/vao (BirdMovementEvents); neu sau nay co bang so to thi
-- thay cot chim bang cot to, khong doi tham so SP.
--
-- File dich trong repo: database/procedures/sp_get_environment_yield_correlation.sql
-- Yeu cau da deploy: create_tables.sql + application_extension.sql
-- (can bang BirdMovementEvents va cot CO2Ppm/LightLux cua SensorReadings).
--
-- QUY UOC DOC KET QUA (quan trong khi demo va khi viet API/frontend):
-- 1. Mot dong = mot nha x mot ngay (ReportDate). Loc @ZoneId chi thu hep
--    phan moi truong/canh bao ve khu do; phan chim van la cap nha vi
--    BirdMovementEvents khong co ZoneId - khong nhan doi chim theo khu.
--    Khi khong loc khu: ZoneId/ZoneName = NULL, nghia la "toan nha".
-- 2. Khoang ngay la nua mo [From, To) nhu sp_GetBirdMovementDaily va
--    sp_GetEnvironmentMetrics. Ngay khong co du lieu van co dong (so 0)
--    de bieu do khong dut quang.
-- 3. Mot so do duoc tinh "trong nguong" khi Temperature va Humidity deu
--    nam trong [Min, Max] cua nguong zone chua cam bien do (khop logic
--    WARNING cua sp_GetZoneDashboard va fn_QAClassifyReading).
--    So do o zone chua cau hinh nguong van dem vao ReadingCount nhung
--    khong vao mau so cua InRangePct (ConfiguredReadingCount).
-- 4. EstimatedHoursInRange la UOC TINH: InRangePct * 24 / 100, gia dinh
--    so do phan bo deu trong ngay; khong phai so gio do truc tiep.
-- 5. Ngay cua so do dung CONVERT(DATE, RecordeAt) (gio may chu legacy),
--    ngay cua chim dung CONVERT(DATE, ObservedAt) (gio tuong Asia/Saigon);
--    hai ben ghep theo ngay lich nhu da luu, khong doi mui gio.
-- 6. He so Pearson tinh tren cac ngay co InRangePct (co so do da cau
--    hinh nguong) cua tung nha trong khoang loc; can toi thieu 3 ngay
--    va ca hai day co phuong sai > 0, neu khong thi tra NULL kem
--    CorrelationStrength = 'INSUFFICIENT_DATA'. He so chi la tuong quan
--    thong ke tren du lieu mo phong, khong khang dinh nhan - qua.
USE SwiftletCare;
GO
CREATE OR ALTER PROCEDURE dbo.sp_GetEnvironmentYieldCorrelation
    @HouseId INT = NULL,
    @ZoneId  INT = NULL,
    @From    DATETIME2 = NULL,
    @To      DATETIME2 = NULL,
    @ManagerId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- VALIDATION + MAC DINH: ca hai dau moc cung co hoac cung trong;
    -- mac dinh 30 ngay lich gan nhat tinh ca hom nay.
    IF (@HouseId IS NOT NULL AND @HouseId <= 0)
       OR (@ZoneId IS NOT NULL AND @ZoneId <= 0)
       OR (@ManagerId IS NOT NULL AND @ManagerId <= 0)
       OR (@From IS NULL AND @To IS NOT NULL)
       OR (@From IS NOT NULL AND @To IS NULL)
        THROW 52720, N'Bo loc nha/khu hoac khoang ngay khong hop le: can ca From va To, hoac de trong ca hai.', 1;
    IF @From IS NULL
    BEGIN
        SET @To = DATEADD(DAY, 1, CONVERT(DATE, SYSDATETIME()));
        SET @From = DATEADD(DAY, -29, CONVERT(DATE, SYSDATETIME()));
    END;
    IF @From >= @To OR DATEDIFF(DAY, @From, @To) > 366
        THROW 52720, N'Khoang ngay phai la [From, To) hop le va khong dai hon 366 ngay.', 1;
    IF OBJECT_ID('dbo.BirdMovementEvents', 'U') IS NULL
        THROW 52723, N'Chua deploy application_extension.sql: thieu bang BirdMovementEvents.', 1;
    IF @HouseId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.SwiftletHouses WHERE HouseId = @HouseId)
        THROW 52721, N'Nha yen khong ton tai.', 1;
    IF @ZoneId IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM dbo.Zones
            WHERE ZoneId = @ZoneId
              AND (@HouseId IS NULL OR HouseId = @HouseId))
        THROW 52722, N'Khu khong ton tai hoac khong thuoc nha da loc.', 1;

    -- Cot song theo ngay: moi ngay trong [From, To) deu xuat hien.
    WITH Calendar AS (
        SELECT CONVERT(DATE, @From) AS ReportDate
        UNION ALL
        SELECT DATEADD(DAY, 1, ReportDate) FROM Calendar
        WHERE DATEADD(DAY, 1, ReportDate) < CONVERT(DATE, @To)
    ),
    Houses AS (
        SELECT HouseId, HouseName FROM dbo.SwiftletHouses
        WHERE (@HouseId IS NULL OR HouseId = @HouseId) AND (@ManagerId IS NULL OR ManagerId = @ManagerId)
    ),
    -- Moi truong theo nha x ngay; nguong lay cua chinh zone chua cam bien.
    EnvDaily AS (
        SELECT z.HouseId,
               CONVERT(DATE, r.RecordeAt) AS ReportDate,
               COUNT_BIG(*) AS ReadingCount,
               COUNT_BIG(t.ThresholdsId) AS ConfiguredReadingCount,
               SUM(CASE WHEN t.ThresholdsId IS NOT NULL
                         AND r.Temperature BETWEEN t.MinTemperature AND t.MaxTemperature
                         AND r.Humidity BETWEEN t.MinHumidity AND t.MaxHumidity
                        THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END) AS InRangeCount,
               CAST(AVG(CONVERT(DECIMAL(18, 4), r.Temperature)) AS DECIMAL(9, 2)) AS AvgTemperature,
               MIN(r.Temperature) AS MinTemperature,
               MAX(r.Temperature) AS MaxTemperature,
               CAST(AVG(CONVERT(DECIMAL(18, 4), r.Humidity)) AS DECIMAL(9, 2)) AS AvgHumidity,
               MIN(r.Humidity) AS MinHumidity,
               MAX(r.Humidity) AS MaxHumidity,
               CAST(AVG(CONVERT(DECIMAL(18, 4), r.CO2Ppm)) AS DECIMAL(10, 2)) AS AvgCO2Ppm,
               CAST(AVG(CONVERT(DECIMAL(18, 4), r.LightLux)) AS DECIMAL(10, 2)) AS AvgLightLux
        FROM dbo.SensorReadings r
        JOIN dbo.Devices d ON d.DeviceId = r.DeviceId AND d.DeviceType = 'SENSOR'
        JOIN dbo.Zones z ON z.ZoneId = d.ZoneId
        JOIN dbo.SwiftletHouses sh ON sh.HouseId = z.HouseId AND (@ManagerId IS NULL OR sh.ManagerId = @ManagerId)
        LEFT JOIN dbo.EnvironmentThresholds t ON t.ZoneId = z.ZoneId
        WHERE r.RecordeAt >= @From AND r.RecordeAt < @To
          AND (@HouseId IS NULL OR z.HouseId = @HouseId)
          AND (@ZoneId IS NULL OR z.ZoneId = @ZoneId)
        GROUP BY z.HouseId, CONVERT(DATE, r.RecordeAt)
    ),
    -- Canh bao theo nha x ngay (Alerts la cap zone, cong don len nha).
    AlertDaily AS (
        SELECT z.HouseId,
               CONVERT(DATE, a.CreatedAt) AS ReportDate,
               COUNT_BIG(*) AS AlertCount
        FROM dbo.Alerts a
        JOIN dbo.Zones z ON z.ZoneId = a.ZoneId
        JOIN dbo.SwiftletHouses sh ON sh.HouseId = z.HouseId AND (@ManagerId IS NULL OR sh.ManagerId = @ManagerId)
        WHERE a.CreatedAt >= @From AND a.CreatedAt < @To
          AND (@HouseId IS NULL OR z.HouseId = @HouseId)
          AND (@ZoneId IS NULL OR z.ZoneId = @ZoneId)
        GROUP BY z.HouseId, CONVERT(DATE, a.CreatedAt)
    ),
    -- Chim ra/vao theo nha x ngay: day la chi so "nang suat" tam thoi.
    -- Tong luu luong mo ta chuyen dong, khong phai so chim dang o trong nha.
    BirdDaily AS (
        SELECT HouseId,
               CONVERT(DATE, ObservedAt) AS ReportDate,
               SUM(CASE WHEN Direction = 'IN' THEN CONVERT(BIGINT, BirdCount)
                        ELSE CONVERT(BIGINT, 0) END) AS BirdInCount,
               SUM(CASE WHEN Direction = 'OUT' THEN CONVERT(BIGINT, BirdCount)
                        ELSE CONVERT(BIGINT, 0) END) AS BirdOutCount,
               COUNT_BIG(*) AS BirdEventCount
        FROM dbo.BirdMovementEvents
        WHERE ObservedAt >= @From AND ObservedAt < @To
          AND (@HouseId IS NULL OR HouseId = @HouseId)
          AND (@ManagerId IS NULL OR EXISTS (SELECT 1 FROM dbo.SwiftletHouses h WHERE h.HouseId = BirdMovementEvents.HouseId AND h.ManagerId = @ManagerId))
        GROUP BY HouseId, CONVERT(DATE, ObservedAt)
    ),
    Daily AS (
        SELECT h.HouseId, h.HouseName, c.ReportDate,
               COALESCE(e.ReadingCount, CONVERT(BIGINT, 0)) AS ReadingCount,
               COALESCE(e.ConfiguredReadingCount, CONVERT(BIGINT, 0)) AS ConfiguredReadingCount,
               COALESCE(e.InRangeCount, CONVERT(BIGINT, 0)) AS InRangeCount,
               e.AvgTemperature, e.MinTemperature, e.MaxTemperature,
               e.AvgHumidity, e.MinHumidity, e.MaxHumidity,
               e.AvgCO2Ppm, e.AvgLightLux,
               COALESCE(a.AlertCount, CONVERT(BIGINT, 0)) AS AlertCount,
               COALESCE(b.BirdInCount, CONVERT(BIGINT, 0)) AS BirdInCount,
               COALESCE(b.BirdOutCount, CONVERT(BIGINT, 0)) AS BirdOutCount,
               COALESCE(b.BirdEventCount, CONVERT(BIGINT, 0)) AS BirdEventCount,
               CAST(CASE WHEN COALESCE(e.ConfiguredReadingCount, 0) = 0 THEN NULL
                         ELSE 100.0 * e.InRangeCount / e.ConfiguredReadingCount
                    END AS DECIMAL(5, 2)) AS InRangePct
        FROM Houses h
        CROSS JOIN Calendar c
        LEFT JOIN EnvDaily e ON e.HouseId = h.HouseId AND e.ReportDate = c.ReportDate
        LEFT JOIN AlertDaily a ON a.HouseId = h.HouseId AND a.ReportDate = c.ReportDate
        LEFT JOIN BirdDaily b ON b.HouseId = h.HouseId AND b.ReportDate = c.ReportDate
    ),
    -- Pearson giua InRangePct (x) va NetMovement = In - Out (y),
    -- tinh bang so hoc FLOAT tren cac ngay co InRangePct cua tung nha.
    Correlation AS (
        SELECT HouseId,
               COUNT_BIG(*) AS CorrelationDays,
               CASE WHEN COUNT_BIG(*) < 3
                          OR (COUNT_BIG(*) * SUM(x * x) - SUM(x) * SUM(x)) <= 0
                          OR (COUNT_BIG(*) * SUM(y * y) - SUM(y) * SUM(y)) <= 0
                    THEN NULL
                    ELSE CAST(
                        (COUNT_BIG(*) * SUM(x * y) - SUM(x) * SUM(y))
                        / SQRT((COUNT_BIG(*) * SUM(x * x) - SUM(x) * SUM(x))
                             * (COUNT_BIG(*) * SUM(y * y) - SUM(y) * SUM(y)))
                        AS DECIMAL(6, 4))
               END AS PearsonInRangeVsNet
        FROM (
            SELECT HouseId,
                   CONVERT(FLOAT, InRangePct) AS x,
                   CONVERT(FLOAT, BirdInCount - BirdOutCount) AS y
            FROM Daily WHERE InRangePct IS NOT NULL
        ) s
        GROUP BY HouseId
    )
    SELECT d.HouseId, d.HouseName,
           @ZoneId AS ZoneId,
           (SELECT ZoneName FROM dbo.Zones WHERE ZoneId = @ZoneId) AS ZoneName,
           d.ReportDate,
           d.ReadingCount, d.ConfiguredReadingCount, d.InRangeCount,
           d.ConfiguredReadingCount - d.InRangeCount AS OutOfRangeCount,
           d.InRangePct,
           CAST(CASE WHEN d.InRangePct IS NULL THEN NULL
                     ELSE d.InRangePct * 24.0 / 100.0
                END AS DECIMAL(5, 2)) AS EstimatedHoursInRange,
           d.AvgTemperature, d.MinTemperature, d.MaxTemperature,
           d.AvgHumidity, d.MinHumidity, d.MaxHumidity,
           d.AvgCO2Ppm, d.AvgLightLux,
           d.AlertCount,
           d.BirdEventCount, d.BirdInCount, d.BirdOutCount,
           d.BirdInCount - d.BirdOutCount AS NetMovement,
           COALESCE(corr.CorrelationDays, CONVERT(BIGINT, 0)) AS CorrelationDays,
           corr.PearsonInRangeVsNet,
           CASE WHEN corr.PearsonInRangeVsNet IS NULL THEN 'INSUFFICIENT_DATA'
                WHEN corr.PearsonInRangeVsNet >= 0.7 THEN 'STRONG_POSITIVE'
                WHEN corr.PearsonInRangeVsNet >= 0.4 THEN 'MODERATE_POSITIVE'
                WHEN corr.PearsonInRangeVsNet >= 0.2 THEN 'WEAK_POSITIVE'
                WHEN corr.PearsonInRangeVsNet > -0.2 THEN 'NEGLIGIBLE'
                WHEN corr.PearsonInRangeVsNet > -0.4 THEN 'WEAK_NEGATIVE'
                WHEN corr.PearsonInRangeVsNet > -0.7 THEN 'MODERATE_NEGATIVE'
                ELSE 'STRONG_NEGATIVE'
           END AS CorrelationStrength,
           CAST('Asia/Saigon' AS VARCHAR(32)) AS BirdTimeZone
    FROM Daily d
    LEFT JOIN Correlation corr ON corr.HouseId = d.HouseId
    ORDER BY d.HouseName, d.ReportDate
    OPTION (MAXRECURSION 366);
END;
GO

-- Vi du chay thu (bo comment de chay tay trong SSMS):
-- 1) Mac dinh: 30 ngay gan nhat, tat ca nha:
-- EXEC dbo.sp_GetEnvironmentYieldCorrelation;
-- 2) Mot nha trong khoang ngay cu the (nua mo [From, To)):
-- EXEC dbo.sp_GetEnvironmentYieldCorrelation
--     @HouseId = 1, @From = '2026-01-01', @To = '2026-02-01';
-- 3) Thu hep phan moi truong ve mot khu (phan chim van la cap nha):
-- EXEC dbo.sp_GetEnvironmentYieldCorrelation
--     @HouseId = 1, @ZoneId = 1, @From = '2026-01-01', @To = '2026-02-01';
