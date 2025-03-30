"""
Script to sync local size guide data to RDS database
"""
import os
from datetime import datetime
from sqlalchemy import create_engine
from dotenv import load_dotenv
import json

load_dotenv()

def create_db_engine(is_rds=False):
    """Create database engine for either local or RDS database"""
    if is_rds:
        db_url = "postgresql://tailor2_admin:efVtower12@tailor2-production.cpgs24uuo973.us-east-2.rds.amazonaws.com/tailor2"
    else:
        db_url = "postgresql://seandavey@localhost/tailor2"
    return create_engine(db_url)

def sync_to_rds():
    """Sync new size guide data from local to RDS"""
    local_engine = create_db_engine(is_rds=False)
    rds_engine = create_db_engine(is_rds=True)
    
    # Get latest sync timestamp from metadata
    try:
        with open('last_sync.json', 'r') as f:
            last_sync = datetime.fromisoformat(json.load(f)['last_sync'])
    except (FileNotFoundError, json.JSONDecodeError):
        last_sync = datetime.min
    
    print(f"Syncing data since {last_sync}")
    
    # Sync automated imports
    with local_engine.connect() as local_conn, rds_engine.connect() as rds_conn:
        # Get new records from local database
        new_imports = local_conn.execute(f"""
            SELECT * FROM raw_size_guides.automated_imports 
            WHERE created_at > '{last_sync}'
        """).fetchall()
        
        print(f"Found {len(new_imports)} new size guide imports")
        
        # Insert into RDS
        for record in new_imports:
            # Check if record already exists in RDS
            exists = rds_conn.execute(f"""
                SELECT id FROM raw_size_guides.automated_imports 
                WHERE id = {record.id}
            """).fetchone()
            
            if not exists:
                # Convert record to dictionary
                record_dict = dict(record)
                
                # Generate INSERT statement
                columns = ', '.join(record_dict.keys())
                values = ', '.join([
                    f"'{str(v)}'" if isinstance(v, (str, datetime)) 
                    else 'null' if v is None 
                    else str(v) 
                    for v in record_dict.values()
                ])
                
                insert_sql = f"""
                    INSERT INTO raw_size_guides.automated_imports ({columns})
                    VALUES ({values})
                """
                
                try:
                    rds_conn.execute(insert_sql)
                    print(f"Synced record {record.id}")
                except Exception as e:
                    print(f"Error syncing record {record.id}: {str(e)}")
        
        # Commit RDS transaction
        rds_conn.execute("COMMIT")
    
    # Update sync timestamp
    with open('last_sync.json', 'w') as f:
        json.dump({'last_sync': datetime.utcnow().isoformat()}, f)
    
    print("Sync completed!")

if __name__ == "__main__":
    sync_to_rds() 