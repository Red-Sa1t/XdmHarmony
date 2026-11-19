"""Line protocol for host-only tests against real SQLite transactions (not Harmony SDK)."""
import json
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1], isolation_level=None)
for line in sys.stdin:
    message = json.loads(line)
    try:
        cursor = connection.execute(message['sql'], message.get('args', []))
        columns = [entry[0] for entry in cursor.description] if cursor.description else []
        rows = [dict(zip(columns, row)) for row in cursor.fetchall()] if columns else []
        print(json.dumps({'id': message['id'], 'rows': rows}), flush=True)
    except Exception as error:
        print(json.dumps({'id': message['id'], 'error': type(error).__name__}), flush=True)
connection.close()
