# Decode Platform Backend

FastAPI backend for the Decode platform. Handles authentication, AI gateway, and analytics.

## Setup

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Configuration

```bash
cp .env.example .env
# Edit .env with your database credentials
```

Requires a running PostgreSQL instance. Create the database:

```bash
createdb decode
createuser decode
psql -d decode -c "ALTER USER decode WITH PASSWORD 'decode';"
psql -d decode -c "GRANT ALL PRIVILEGES ON DATABASE decode TO decode;"
psql -d decode -c "GRANT ALL ON SCHEMA public TO decode;"
```

## Migrations

```bash
# Apply all migrations
PYTHONPATH=. alembic upgrade head

# Create a new migration after model changes
PYTHONPATH=. alembic revision --autogenerate -m "description"

# Check current migration status
PYTHONPATH=. alembic current
```

## Run

```bash
PYTHONPATH=. python -m uvicorn app.main:app --reload
```

API docs available at http://localhost:8000/docs (development only).

## Verify

```bash
curl http://localhost:8000/health
# {"status":"ok"}
```
