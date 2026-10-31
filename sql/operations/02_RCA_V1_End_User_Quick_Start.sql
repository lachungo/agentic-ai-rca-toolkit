/*
  RCA V1 PUBLIC QUICK START

  The investigator supplies only a database and local incident window.
  CaptureRunID is retained internally for evidence lineage and repeatability.
*/
USE dbamaint;
GO

EXEC dbo.usp_RCA_WhyIsDatabaseSlowHTMLV1
     @DatabaseName   = N'RCA_Demo',
     @BeginTimeLocal = '2026-08-23T13:56:00',
     @EndTimeLocal   = '2026-08-23T13:59:00';
GO

/*
  Positive-control workloads are under sql/acceptance.
  Run them only in an isolated non-production lab after reviewing their headers.
*/
