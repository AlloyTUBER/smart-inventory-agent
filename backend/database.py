import os
from pathlib import Path
from dotenv import load_dotenv
from sqlalchemy import create_engine

env_path = Path(__file__).resolve().parent / ".env"
if env_path.exists():
    load_dotenv(dotenv_path=env_path)
else:
    load_dotenv()

DATABASE_URL = os.getenv(
    "DATABASE_URL", "postgresql://inv_admin:1234@localhost:3010/inventory_db"
)
engine = create_engine(DATABASE_URL)
