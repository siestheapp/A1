import os
import logging

logger = logging.getLogger(__name__)

def get_database_url():
    """Get database URL from environment variable or AWS Secrets Manager"""
    # First try environment variable
    if os.getenv("TAILOR2_DATABASE_URL"):
        return os.getenv("TAILOR2_DATABASE_URL")
        
    # Only try AWS if explicitly configured
    if os.getenv("USE_AWS_SECRETS") == "true":
        try:
            import boto3
            import json
            
            secret_name = "tailor2/production/database"
            region_name = "us-east-2"
            
            client = boto3.client('secretsmanager', region_name=region_name)
            secret = client.get_secret_value(SecretId=secret_name)
            secret_dict = json.loads(secret['SecretString'])
            
            return f"postgresql://{secret_dict['username']}:{secret_dict['password']}@{secret_dict['host']}/{secret_dict['dbname']}"
        except Exception as e:
            logger.error(f"Failed to get AWS secret: {e}")
            return None
            
    return None 