USE SwiftletCare;
GO
CREATE OR ALTER PROCEDURE dbo.sp_GetUnresolvedAlerts @ZoneId INT=NULL,@Limit INT=500
AS
BEGIN
    SET NOCOUNT ON;
    IF (@ZoneId IS NOT NULL AND @ZoneId<=0) OR @Limit IS NULL OR @Limit NOT BETWEEN 1 AND 1000
        THROW 52503,N'Tham số danh sách cảnh báo không hợp lệ.',1;
    SELECT TOP(@Limit) a.AlertId,a.ZoneId,a.ReadingId,a.AlertType,a.Message,a.Status,a.CreatedAt
    FROM dbo.Alerts a
    WHERE a.Status IN ('PENDING','ACKNOWLEDGED') AND (@ZoneId IS NULL OR a.ZoneId=@ZoneId)
    ORDER BY a.CreatedAt DESC,a.AlertId DESC;
END;
GO
