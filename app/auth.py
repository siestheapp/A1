from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBasic, HTTPBasicCredentials
import secrets
import os
from dotenv import load_dotenv

load_dotenv()

security = HTTPBasic()

def get_current_username(credentials: HTTPBasicCredentials = Depends(security)):
    """Validate username and password"""
    correct_username = os.getenv("API_USERNAME", "admin")
    correct_password = os.getenv("API_PASSWORD", "changeme")
    
    is_correct_username = secrets.compare_digest(credentials.username.encode("utf8"), correct_username.encode("utf8"))
    is_correct_password = secrets.compare_digest(credentials.password.encode("utf8"), correct_password.encode("utf8"))
    
    if not (is_correct_username and is_correct_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect username or password",
            headers={"WWW-Authenticate": "Basic"},
        )
    
    return credentials.username 