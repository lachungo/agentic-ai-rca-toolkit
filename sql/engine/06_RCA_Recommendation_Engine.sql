USE DBA;
GO

EXEC dbo.usp_RCA_ShowRecommendationReport
     @CaptureRunID = 3,
     @TopExecutions = 20;
GO