from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker
from sqlalchemy.ext.declarative import declarative_base
import os
from dotenv import load_dotenv
import logging

# Set up logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

load_dotenv()

# Connect to the Tailor2 database
TAILOR2_DATABASE_URL = os.getenv("TAILOR2_DATABASE_URL")
if not TAILOR2_DATABASE_URL:
    raise ValueError("TAILOR2_DATABASE_URL environment variable is not set")

try:
    engine = create_engine(TAILOR2_DATABASE_URL)
    # Test the connection
    with engine.connect() as conn:
        conn.execute(text("SELECT 1"))
    logger.info("Successfully connected to Tailor2 database")
except Exception as e:
    logger.error(f"Failed to connect to Tailor2 database: {e}")
    raise

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

Base = declarative_base()

def init_db():
    """Initialize the database, creating necessary tables if they don't exist"""
    try:
        with engine.connect() as conn:
            # Create raw_size_guides schema if it doesn't exist
            conn.execute(text("CREATE SCHEMA IF NOT EXISTS raw_size_guides"))
            
            # Create automated_imports table
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS raw_size_guides.automated_imports (
                    id SERIAL PRIMARY KEY,
                    brand_name VARCHAR,
                    product_type VARCHAR,
                    department VARCHAR,
                    category VARCHAR,
                    measurements JSONB,
                    unit_system VARCHAR(8),
                    image_path VARCHAR,
                    ocr_confidence FLOAT,
                    status VARCHAR(20) DEFAULT 'pending_review',
                    review_notes TEXT,
                    reviewed_by INTEGER REFERENCES public.users(id),
                    reviewed_at TIMESTAMP,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    processed_at TIMESTAMP,
                    metadata JSONB,
                    brand_id INTEGER REFERENCES public.brands(id),
                    created_by VARCHAR(255),
                    raw_text TEXT
                )
            """))
            conn.commit()
            logger.info("Successfully initialized database tables")
    except Exception as e:
        logger.error(f"Failed to initialize database: {e}")
        raise

# Dependency
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close() 