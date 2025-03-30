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
from .database import get_db, SessionLocal
from .models import Department, Category, UnitSystem, ImportStatus
import json

# Set up logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="A1 Size Guide Processor")

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount static files
app.mount("/uploads", StaticFiles(directory="uploads"), name="uploads")
templates = Jinja2Templates(directory="app/templates")

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
    Upload and process a size guide image using AI-enhanced analysis
    """
    if not file.filename.lower().endswith(('.png', '.jpg', '.jpeg')):
        raise HTTPException(status_code=400, detail="File must be an image")
    
    try:
        processor = SizeGuideProcessor()
        
        # Save the uploaded file
        contents = await file.read()
        image = Image.open(io.BytesIO(contents))
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"{timestamp}_{file.filename}"
        image_path = os.path.join("uploads", filename)
        image.save(image_path)
        
        # Process the image with AI enhancement
        result = await processor.process_image(image_path)
        
        # Create automated import record
        db = SessionLocal()
        import_record = models.AutomatedImport(
            brand_name=brand_name,
            department=department,
            category=category,
            unit_system=UnitSystem[unit_system],
            measurements=result["measurements"],
            ocr_text=result["ocr_text"],
            ocr_confidence=result["confidence"],
            image_path=image_path,
            status=ImportStatus.PENDING,
            created_at=datetime.utcnow(),
            created_by=username,
            extra_data={"ai_analysis": result["ai_analysis"]}
        )
        
        # Try to match with existing brand
        brand = db.query(models.Brand).filter(models.Brand.name.ilike(brand_name)).first()
        if brand:
            import_record.brand_id = brand.id
        
        db.add(import_record)
        db.commit()
        db.refresh(import_record)
        
        # If confidence is high enough, automatically approve
        if result["confidence"] > 0.9:
            import_record.status = ImportStatus.APPROVED
            import_record.processed_at = datetime.utcnow()
            db.commit()
        
        db.close()
        
        return {
            "message": "Size guide processed successfully",
            "import_id": import_record.id,
            "status": import_record.status,
            "confidence": result["confidence"]
        }
        
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

@app.post("/train")
async def add_training_example(
    username: str = Depends(get_current_username),
    file: UploadFile = File(...),
    correct_output: str = Form(...),  # JSON string of correct measurements
):
    """
    Add a new training example to improve the AI's accuracy
    """
    if not file.filename.lower().endswith(('.png', '.jpg', '.jpeg')):
        raise HTTPException(status_code=400, detail="File must be an image")
    
    try:
        # Parse the correct output
        correct_measurements = json.loads(correct_output)
        
        # Save the image
        processor = SizeGuideProcessor()
        contents = await file.read()
        image = Image.open(io.BytesIO(contents))
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"training_{timestamp}_{file.filename}"
        image_path = os.path.join("uploads", filename)
        image.save(image_path)
        
        # Add as training example
        processor.add_training_example(image_path, correct_measurements)
        
        return {
            "message": "Training example added successfully",
            "image_path": image_path
        }
        
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="Invalid JSON format for correct_output")
    except Exception as e:
        logger.error(f"Error adding training example: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e)) 