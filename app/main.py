from fastapi import FastAPI, UploadFile, File, HTTPException, Depends, Form, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session
from PIL import Image
import io
import os
from typing import List
from datetime import datetime
import logging
from .auth import get_current_username
from . import models, database
from .services import SizeGuideProcessor
from .database import get_db
from .models import Department, Category, UnitSystem, ImportStatus

# Set up logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="A1 Size Guide Processor")

# Add CORS middleware with specific origins
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:3000",
        "http://127.0.0.1:3000",
        # Add your colleague's domain/IP here
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount the uploads directory
app.mount("/uploads", StaticFiles(directory="uploads"), name="uploads")

# Set up templates
templates = Jinja2Templates(directory="app/templates")

# Initialize the processor
processor = SizeGuideProcessor()

@app.get("/", response_class=HTMLResponse)
async def upload_form(request: Request):
    """
    Serve the upload form
    """
    return templates.TemplateResponse("upload.html", {"request": request})

@app.get("/view/{import_id}")
async def view_image(
    import_id: int,
    username: str = Depends(get_current_username),
    db: Session = Depends(get_db)
):
    """
    View an uploaded image
    """
    # Get the import record
    import_record = db.query(models.AutomatedImport).filter(models.AutomatedImport.id == import_id).first()
    if not import_record:
        raise HTTPException(status_code=404, detail="Import not found")
    
    # Check if the image exists
    if not os.path.exists(import_record.image_path):
        raise HTTPException(status_code=404, detail="Image file not found")
    
    return templates.TemplateResponse(
        "view.html",
        {
            "request": {"type_hints": {}},  # Minimal request object
            "import_record": import_record,
            "image_url": f"/uploads/{os.path.basename(import_record.image_path)}"
        }
    )

@app.post("/upload")
async def upload_size_guide(
    username: str = Depends(get_current_username),
    file: UploadFile = File(...),
    brand_name: str = Form(...),
    department: str = Form(...),
    category: str = Form(...),
    unit_system: str = Form(...)
):
    """
    Upload a size guide image with metadata
    """
    if not file.filename.lower().endswith(('.png', '.jpg', '.jpeg')):
        raise HTTPException(status_code=400, detail="File must be an image")
    
    try:
        processor = SizeGuideProcessor()
        
        # Process the image and extract data
        image_path = await processor.save_image(file)
        measurements, ocr_text, confidence = await processor.process_image(image_path)
        
        # Create new automated import record
        import_record = models.AutomatedImport(
            brand_name=brand_name,
            department=department,
            category=category,
            unit_system=UnitSystem[unit_system],
            measurements=measurements,
            ocr_text=ocr_text,
            ocr_confidence=confidence,
            image_path=image_path,
            status=ImportStatus.PENDING,
            created_at=datetime.utcnow(),
            created_by=username
        )
        
        db = SessionLocal()
        db.add(import_record)
        db.commit()
        db.refresh(import_record)
        db.close()
        
        return {"message": "Size guide uploaded successfully", "import_id": import_record.id}
        
    except Exception as e:
        logger.error(f"Error processing upload: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/pending-imports")
def list_pending_imports(
    username: str = Depends(get_current_username),
    db: Session = Depends(get_db),
    skip: int = 0,
    limit: int = 100
):
    """
    List all pending imports awaiting review
    """
    imports = db.query(models.AutomatedImport)\
        .filter(models.AutomatedImport.status == models.ImportStatus.PENDING)\
        .offset(skip)\
        .limit(limit)\
        .all()
    
    return [
        {
            "id": imp.id,
            "brand_name": imp.brand_name,
            "department": imp.department,
            "category": imp.category,
            "ocr_confidence": imp.ocr_confidence,
            "created_at": imp.created_at,
            "created_by": imp.created_by
        }
        for imp in imports
    ]

@app.get("/imports/{import_id}")
def get_import_details(
    import_id: int,
    db: Session = Depends(get_db)
):
    """
    Get detailed information about a specific import
    """
    import_record = db.query(models.AutomatedImport)\
        .filter(models.AutomatedImport.id == import_id)\
        .first()
    
    if not import_record:
        raise HTTPException(status_code=404, detail="Import not found")
    
    return {
        "id": import_record.id,
        "brand_name": import_record.brand_name,
        "brand_id": import_record.brand_id,
        "product_type": import_record.product_type,
        "department": import_record.department,
        "category": import_record.category,
        "measurements": import_record.measurements,
        "unit_system": import_record.unit_system,
        "ocr_confidence": import_record.ocr_confidence,
        "status": import_record.status,
        "raw_text": import_record.raw_text,
        "created_at": import_record.created_at,
        "reviewed_at": import_record.reviewed_at,
        "review_notes": import_record.review_notes
    }

@app.post("/imports/{import_id}/review")
def review_import(
    import_id: int,
    status: models.ImportStatus,
    review_notes: str = None,
    db: Session = Depends(get_db)
):
    """
    Review an import and approve or reject it
    """
    import_record = db.query(models.AutomatedImport)\
        .filter(models.AutomatedImport.id == import_id)\
        .first()
    
    if not import_record:
        raise HTTPException(status_code=404, detail="Import not found")
    
    if import_record.status != models.ImportStatus.PENDING:
        raise HTTPException(status_code=400, detail="Import has already been reviewed")
    
    import_record.status = status
    import_record.review_notes = review_notes
    import_record.reviewed_at = datetime.utcnow()
    
    db.commit()
    
    return {
        "message": "Import reviewed successfully",
        "import_id": import_record.id,
        "status": import_record.status,
        "review_notes": import_record.review_notes
    }

@app.get("/brands")
def list_brands(
    db: Session = Depends(get_db),
    skip: int = 0,
    limit: int = 100
):
    """
    List all brands in the database
    """
    brands = db.query(models.Brand)\
        .offset(skip)\
        .limit(limit)\
        .all()
    
    return [
        {
            "id": brand.id,
            "name": brand.name
        }
        for brand in brands
    ] 