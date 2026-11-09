
import os
import pyodbc
from dotenv import load_dotenv

load_dotenv()

password = os.getenv("MSSQL_SA_PASSWORD")

if not password:
    raise RuntimeError("Chưa có MSSQL_SA_PASSWORD trong file .env")

connection_string = (
    "DRIVER={ODBC Driver 18 for SQL Server};"
    "SERVER=127.0.0.1,14330;"
    "DATABASE=SwiftletCare;"
    "UID=sa;"
    f"PWD={password};"
    "Encrypt=yes;"
    "TrustServerCertificate=yes;"
)

try:
    with pyodbc.connect(connection_string, timeout=5) as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT DB_NAME(), @@VERSION")
        result = cursor.fetchone()

        print("KET NOI THANH CONG!")
        print("Database:", result[0])
        print("SQL Server:", result[1].splitlines()[0])

except pyodbc.Error as error:
    print("KET NOI THAT BAI!")
    print(error)
