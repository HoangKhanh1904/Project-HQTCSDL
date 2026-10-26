param(
    [string]$ScriptDomPath = 'C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\Extensions\Application\Microsoft.SqlServer.TransactSql.ScriptDom.dll'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ScriptDomPath)) {
    throw 'Pass -ScriptDomPath pointing to Microsoft.SqlServer.TransactSql.ScriptDom.dll (SQL Server 2022 parser).'
}
Add-Type -Path $ScriptDomPath
$parser = New-Object Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser($true)
$trees = @()
$syntaxErrors = @()

foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.sql' -Recurse -File) {
    $reader = [System.IO.StringReader]::new([System.IO.File]::ReadAllText($file.FullName))
    try {
        $parseErrors = $null
        $tree = $parser.Parse($reader, [ref]$parseErrors)
        foreach ($parseError in $parseErrors) {
            $syntaxErrors += '{0}:{1}:{2}: {3}' -f $file.Name, $parseError.Line, $parseError.Column, $parseError.Message
        }
        $trees += [PSCustomObject]@{ Path = $file.FullName; Tree = $tree }
        Write-Output ('SYNTAX {0}: {1} error(s)' -f $file.Name, $parseErrors.Count)
    }
    finally {
        $reader.Dispose()
    }
}
if ($syntaxErrors.Count -gt 0) {
    throw ($syntaxErrors -join [Environment]::NewLine)
}

function Get-SqlNodes {
    param($Node, [string]$TypeName)
    if ($null -eq $Node) { return }
    if ($Node.GetType().Name -eq $TypeName) { Write-Output $Node }
    foreach ($property in $Node.PSObject.Properties) {
        if ($property.Name -eq 'ScriptTokenStream') { continue }
        $value = $property.Value
        if ($value -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]) {
            Get-SqlNodes -Node $value -TypeName $TypeName
        }
        elseif ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
            foreach ($item in $value) {
                if ($item -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]) {
                    Get-SqlNodes -Node $item -TypeName $TypeName
                }
            }
        }
    }
}

$tables = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
$procedures = @()
$primaryKeyCount = 0
$uniqueCount = 0
$foreignKeyCount = 0
$checkCount = 0
$businessTrees = @($trees | Where-Object { $_.Path -notmatch '[\\/]isolation_demos[\\/]' })
foreach ($entry in $businessTrees) {
    foreach ($node in Get-SqlNodes -Node $entry.Tree -TypeName 'CreateTableStatement') {
        $name = $node.SchemaObjectName.BaseIdentifier.Value
        if ($tables.ContainsKey($name)) { throw "Duplicate table definition: $name" }
        $columns = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($column in $node.Definition.ColumnDefinitions) {
            if (-not $columns.Add($column.ColumnIdentifier.Value)) { throw "Duplicate column in $name" }
        }
        $tables.Add($name, $columns)
        foreach ($constraint in Get-SqlNodes -Node $node -TypeName 'UniqueConstraintDefinition') {
            if ($constraint.IsPrimaryKey) { $primaryKeyCount++ } else { $uniqueCount++ }
        }
        $foreignKeyCount += @(Get-SqlNodes -Node $node -TypeName 'ForeignKeyConstraintDefinition').Count
        $checkCount += @(Get-SqlNodes -Node $node -TypeName 'CheckConstraintDefinition').Count
    }
    foreach ($node in Get-SqlNodes -Node $entry.Tree -TypeName 'CreateOrAlterProcedureStatement') {
        $procedures += $node.ProcedureReference.Name.BaseIdentifier.Value
    }
}

$expectedTables = @('Users', 'SwiftletHouses', 'Zones', 'Devices', 'SensorReadings', 'EnvironmentThresholds', 'Alerts', 'AlertActions', 'ControlLogs')
if ($tables.Count -ne 9) { throw "Expected nine business tables; got $($tables.Count)." }
foreach ($name in $expectedTables) {
    if (-not $tables.ContainsKey($name)) { throw "Missing table: $name" }
}
if ($primaryKeyCount -ne 9 -or $uniqueCount -ne 3 -or $foreignKeyCount -ne 11 -or $checkCount -ne 15) {
    throw "Unexpected constraint counts: PK=$primaryKeyCount UNIQUE=$uniqueCount FK=$foreignKeyCount CHECK=$checkCount"
}
$expectedProcedures = @('sp_AcknowledgeAlert', 'sp_GetEnvironmentThreshold', 'sp_UpdateEnvironmentThreshold',
    'sp_InsertSensorReading', 'sp_TransitionAlert', 'sp_ResolveAlert', 'sp_ReopenAlert', 'sp_CreateEnvironmentThreshold',
    'sp_GetLatestSensorReadings', 'sp_GetSensorHistory', 'sp_GetUnresolvedAlerts', 'sp_GetZoneDashboard')
if ($procedures.Count -ne $expectedProcedures.Count -or @($procedures | Select-Object -Unique).Count -ne $expectedProcedures.Count) {
    throw 'Expected exactly twelve distinct application procedure definitions.'
}
foreach ($name in $expectedProcedures) {
    if ($procedures -cnotcontains $name) { throw "Missing procedure: $name" }
}

foreach ($entry in $businessTrees) {
    foreach ($node in Get-SqlNodes -Node $entry.Tree -TypeName 'NamedTableReference') {
        if ($null -ne $node.SchemaObject.SchemaIdentifier -and $node.SchemaObject.SchemaIdentifier.Value -ceq 'dbo') {
            $name = $node.SchemaObject.BaseIdentifier.Value
            if (-not $tables.ContainsKey($name)) { throw "Unknown dbo table $name in $($entry.Path)" }
        }
    }
    foreach ($node in Get-SqlNodes -Node $entry.Tree -TypeName 'InsertSpecification') {
        if ($node.Target -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.NamedTableReference]) { continue }
        if ($null -eq $node.Target.SchemaObject.SchemaIdentifier -or $node.Target.SchemaObject.SchemaIdentifier.Value -cne 'dbo') { continue }
        $name = $node.Target.SchemaObject.BaseIdentifier.Value
        foreach ($column in $node.Columns) {
            $columnName = $column.MultiPartIdentifier.Identifiers[-1].Value
            if (-not $tables[$name].Contains($columnName)) { throw "Unknown INSERT column $name.$columnName in $($entry.Path)" }
        }
    }
    foreach ($node in Get-SqlNodes -Node $entry.Tree -TypeName 'ForeignKeyConstraintDefinition') {
        $name = $node.ReferenceTableName.BaseIdentifier.Value
        if (-not $tables.ContainsKey($name)) { throw "Unknown foreign key target $name" }
        foreach ($column in $node.ReferencedTableColumns) {
            if (-not $tables[$name].Contains($column.Value)) { throw "Unknown foreign key column $name.$($column.Value)" }
        }
    }
}

foreach ($pair in @(@('SensorReadings', 'RecordeAt'), @('ControlLogs', 'ExecuteAt'), @('EnvironmentThresholds', 'ThresholdsId'), @('EnvironmentThresholds', 'UpdateAt'), @('EnvironmentThresholds', 'RowVer'))) {
    if (-not $tables[$pair[0]].Contains($pair[1])) { throw "Missing protected column $($pair -join '.')" }
}
Write-Output ('STATIC PASS: {0} SQL files; nine business tables; twelve application procedures; dbo table, INSERT column and FK target references checked.' -f $trees.Count)
Write-Output 'STATIC PASS: nine PK, three UNIQUE, eleven FK and fifteen CHECK definitions.'
Write-Output 'NOT TESTED: SQL Server binding, permissions, transaction execution and two-session concurrency.'
