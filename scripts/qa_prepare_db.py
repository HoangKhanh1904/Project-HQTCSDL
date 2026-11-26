"""Install baseline dependencies + TV4 analytics ONLY in an isolated QA DB.

Requires: an existing, empty SQL Server database named *_QA or *_Test and
QA_CONN_STR pointing at it. Does not create/drop databases, modify application
procedures, or touch SwiftletCare production. This deploys the team's
published SQL scripts in dependency order, without running seed/demo scripts.
"""
import os
from pathlib import Path
import re
import sys

try:
    import pyodbc
except ImportError:
    raise SystemExit('Install requirements: python -m pip install -r requirements.txt')

ROOT=Path(__file__).resolve().parents[1]
# When installed into a cloned repo, ROOT is the repo root. When run inside
# the downloadable package, copy scripts to the actual project first.
SOURCE_FILES=[
    'database/create_tables.sql',
    'database/alter_table.sql',
    'database/runtime_migration.sql',
    'database/application_extension.sql',
    'database/concurrency/sp_acknowledge_alert.sql',
    'database/concurrency/sp_update_environment_threshold.sql',
    'database/procedures/sp_insert_sensor_reading.sql',
    'database/procedures/sp_bird_movements.sql',
    'database/procedures/sp_simulated_system_events.sql',
    'database/procedures/sp_simulate_device_control.sql',
    'scripts/analytics_qa.sql',
    'database/concurrency/sp_get_environment_threshold.sql',
    'database/procedures/sp_create_environment_threshold.sql',
    'database/procedures/sp_get_environment_yield_correlation.sql',
    'database/procedures/sp_get_zone_dashboard.sql',
    'database/procedures/sp_get_environment_metrics.sql',
    'database/procedures/sp_get_house_overview.sql',
]


def batches(path):
    text=path.read_text(encoding='utf-8-sig')
    # Original team scripts explicitly target production with USE SwiftletCare.
    # Remove ONLY exact stand-alone switches; never override the selected DB.
    text=re.sub(r'(?im)^\s*USE\s+(?:\[SwiftletCare\]|SwiftletCare)\s*;\s*$',
                '',text)
    for chunk in re.split(r'(?im)^\s*GO\s*(?:--[^\n]*)?$',text):
        if chunk.strip():
            yield chunk


def main():
    cs=os.getenv('QA_CONN_STR')
    if not cs:
        raise SystemExit('Missing QA_CONN_STR')
    missing=[p for p in SOURCE_FILES if not (ROOT/p).is_file()]
    if missing:
        raise SystemExit('Run after copying scripts into cloned repo; missing: '+', '.join(missing))
    cn=pyodbc.connect(cs,autocommit=True,timeout=10)
    try:
        cur=cn.cursor()
        db=cur.execute('SELECT DB_NAME()').fetchval()
        if not db.lower().endswith(('_qa','_test')):
            raise RuntimeError('Refusing to deploy in '+db+': use *_QA or *_Test')
        tables=cur.execute("SELECT COUNT(*) FROM sys.tables WHERE schema_id=SCHEMA_ID('dbo')").fetchval()
        if tables:
            raise RuntimeError('QA DB is not empty; preparation does not overwrite an existing DB')
        print('Preparing isolated database',db)
        for p in SOURCE_FILES:
            path=ROOT/p
            print('DEPLOY',p,flush=True)
            for batch in batches(path):
                cur.execute(batch)
                while True:
                    if cur.description:
                        cur.fetchall()
                    if not cur.nextset():
                        break
        print('PREPARED: schema + TV4 analytics installed; now run qa_runner.py')
        return 0
    except Exception as error:
        print('PREPARE FAIL:',error,file=sys.stderr)
        print('The QA DB may be partially deployed. Inspect it; recreate only this isolated QA DB if necessary.',file=sys.stderr)
        return 1
    finally:
        cn.close()


if __name__=='__main__':
    sys.exit(main())
