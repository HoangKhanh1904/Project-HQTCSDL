-- P5 (nhanh update_application): SP tong quan tung nha yen.
-- Goc: ke hoach Giai doan 1, goi P5 "Quan ly nhieu nha yen": trang
-- farms (danh sach nha) can mot lan goi lay tong quan moi nha, thay
-- vi goi dashboard tung khu roi cong don o frontend.
--
-- File dich trong repo: database/procedures/sp_get_house_overview.sql
-- Yeu cau da deploy: create_tables.sql (cac bang SwiftletHouses,
-- Users, Zones, Devices, SensorReadings, EnvironmentThresholds,
-- Alerts).
--
-- QUY UOC DOC KET QUA:
-- 1. Mot dong = mot nha yen. Nha chua co khu vuc nao van co dong,
--    cac so dem bang 0 va OverallStatus = 'NO_DATA'.
-- 2. Loc @ManagerId: NULL = tat ca nha; co gia tri = chi cac nha
--    do nguoi quan ly do phu trach. ManagerName la FullName cua
--    Users ung voi ManagerId cua nha.
-- 3. WarningZoneCount dem so khu co EnvironmentStatus = 'WARNING'
--    theo dung logic sp_GetZoneDashboard: chi xet so do MOI NHAT
--    cua tung cam bien SENSOR (OUTER APPLY TOP 1 theo RecordeAt
--    DESC, ReadingId DESC); khu bi WARNING khi co it nhat mot cam
--    bien co so do va so do nam ngoai [Min, Max] nhiet do hoac
--    do am cua nguong khu do. Khu chua cau hinh nguong hoac chua
--    co so do thi khong tinh la WARNING.
-- 4. OpenAlertCount dem canh bao chua dong (Status PENDING hoac
--    ACKNOWLEDGED) tren tat ca khu cua nha.
-- 5. OverallStatus theo thu tu uu tien:
--    'WARNING' khi WarningZoneCount > 0 hoac OpenAlertCount > 0;
--    'NO_DATA' khi nha khong co bat ky so do cam bien nao
--    (khong cam bien nao co so do moi nhat);
--    con lai 'NORMAL'.
USE SwiftletCare;
GO
CREATE OR ALTER PROCEDURE dbo.sp_GetHouseOverview
    @ManagerId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @ManagerId IS NOT NULL AND @ManagerId <= 0
        THROW 52730, 'Invalid ManagerId', 1;

    -- So do moi nhat cua tung cam bien, giong sp_GetZoneDashboard:
    -- cam bien chua co so do van co dong voi ReadingId, Temperature
    -- va Humidity = NULL nho OUTER APPLY.
    WITH LatestReadings AS (
        SELECT d.ZoneId, d.DeviceId, r.ReadingId,
               r.Temperature, r.Humidity, r.RecordeAt
        FROM dbo.Devices AS d
        OUTER APPLY (
            SELECT TOP (1) sr.ReadingId, sr.Temperature,
                   sr.Humidity, sr.RecordeAt
            FROM dbo.SensorReadings AS sr
            WHERE sr.DeviceId = d.DeviceId
            ORDER BY sr.RecordeAt DESC, sr.ReadingId DESC
        ) AS r
        WHERE d.DeviceType = 'SENSOR'
    ),
    -- Trang thai canh bao theo tung khu: IsWarning = 1 khi khu co
    -- EnvironmentStatus = 'WARNING' theo logic dashboard o tren.
    ZoneStatus AS (
        SELECT z.ZoneId, z.HouseId,
               COUNT(r.ReadingId) AS ReadingSensorCount,
               CASE
                   WHEN t.ThresholdsId IS NULL THEN 0
                   WHEN COUNT(r.ReadingId) = 0 THEN 0
                   WHEN MAX(CASE WHEN r.Temperature < t.MinTemperature
                                   OR r.Temperature > t.MaxTemperature
                                   OR r.Humidity < t.MinHumidity
                                   OR r.Humidity > t.MaxHumidity
                                 THEN 1 ELSE 0 END) = 1 THEN 1
                   ELSE 0
               END AS IsWarning
        FROM dbo.Zones AS z
        LEFT JOIN LatestReadings AS r ON r.ZoneId = z.ZoneId
        LEFT JOIN dbo.EnvironmentThresholds AS t ON t.ZoneId = z.ZoneId
        GROUP BY z.ZoneId, z.HouseId, t.ThresholdsId
    ),
    -- Cong don theo nha, tach rieng tung nguon dem (khu, thiet bi,
    -- canh bao) de cac so dem khong nhan cheo nhau khi JOIN.
    HouseZoneStats AS (
        SELECT HouseId,
               COUNT(*) AS ZoneCount,
               SUM(IsWarning) AS WarningZoneCount,
               SUM(ReadingSensorCount) AS ReadingSensorCount
        FROM ZoneStatus
        GROUP BY HouseId
    ),
    HouseDeviceStats AS (
        SELECT z.HouseId,
               COUNT(d.DeviceId) AS DeviceCount
        FROM dbo.Zones AS z
        JOIN dbo.Devices AS d ON d.ZoneId = z.ZoneId
        GROUP BY z.HouseId
    ),
    HouseAlertStats AS (
        SELECT z.HouseId,
               COUNT(a.AlertId) AS OpenAlertCount
        FROM dbo.Zones AS z
        JOIN dbo.Alerts AS a ON a.ZoneId = z.ZoneId
        WHERE a.Status IN ('PENDING', 'ACKNOWLEDGED')
        GROUP BY z.HouseId
    )
    SELECT h.HouseId, h.HouseName, h.Address,
           h.ManagerId, u.FullName AS ManagerName, h.Status,
           COALESCE(zs.ZoneCount, 0) AS ZoneCount,
           COALESCE(ds.DeviceCount, 0) AS DeviceCount,
           COALESCE(als.OpenAlertCount, 0) AS OpenAlertCount,
           COALESCE(zs.WarningZoneCount, 0) AS WarningZoneCount,
           CASE
               WHEN COALESCE(zs.WarningZoneCount, 0) > 0
                 OR COALESCE(als.OpenAlertCount, 0) > 0 THEN 'WARNING'
               WHEN COALESCE(zs.ReadingSensorCount, 0) = 0 THEN 'NO_DATA'
               ELSE 'NORMAL'
           END AS OverallStatus
    FROM dbo.SwiftletHouses AS h
    LEFT JOIN dbo.Users AS u ON u.UserID = h.ManagerId
    LEFT JOIN HouseZoneStats AS zs ON zs.HouseId = h.HouseId
    LEFT JOIN HouseDeviceStats AS ds ON ds.HouseId = h.HouseId
    LEFT JOIN HouseAlertStats AS als ON als.HouseId = h.HouseId
    WHERE (@ManagerId IS NULL OR h.ManagerId = @ManagerId)
    ORDER BY h.HouseName;
END;
GO

-- Vi du chay thu (bo comment de chay tay trong SSMS):
-- 1) Tat ca nha:
-- EXEC dbo.sp_GetHouseOverview;
-- 2) Chi nha cua mot nguoi quan ly:
-- EXEC dbo.sp_GetHouseOverview @ManagerId = 1;
