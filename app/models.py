from sqlalchemy import Column, Integer, String, JSON, DateTime, Float, ForeignKey, Text, Enum as SQLEnum, Boolean
from sqlalchemy.orm import relationship
from sqlalchemy.ext.declarative import declarative_base
from datetime import datetime
from enum import Enum
from pydantic import BaseModel
from typing import Optional, Dict, Any
from sqlalchemy.sql import func

Base = declarative_base()

class Department(str, Enum):
    MENS = "Men"
    WOMENS = "Women"
    UNISEX = "Unisex"

class Category(str, Enum):
    TOPS = "Tops"
    BOTTOMS = "Bottoms"
    DRESSES = "Dresses"
    OUTERWEAR = "Outerwear"
    SUITS = "Suits"
    ACTIVEWEAR = "Activewear"
    SWIMWEAR = "Swimwear"
    UNDERWEAR = "Underwear"
    ACCESSORIES = "Accessories"

class UnitSystem(str, Enum):
    METRIC = "METRIC"
    IMPERIAL = "IMPERIAL"

class ImportStatus(str, Enum):
    PENDING = "PENDING"
    APPROVED = "APPROVED"
    REJECTED = "REJECTED"

class Gender(str, Enum):
    MENS = "Mens"
    WOMENS = "Womens"

class UploadStatus(str, Enum):
    PENDING = "pending"  # Initial upload, waiting for measurement extraction
    PROCESSING = "processing"  # AI1 is currently processing
    COMPLETED = "completed"  # Successfully extracted measurements
    FAILED = "failed"  # Failed to extract measurements
    MANUAL_REVIEW = "manual_review"  # Needs human review

class User(Base):
    __tablename__ = "users"
    __table_args__ = {'schema': 'public'}

    id = Column(Integer, primary_key=True)
    username = Column(String, unique=True, nullable=False)
    email = Column(String, unique=True, nullable=False)
    created_at = Column(DateTime, server_default=func.now())

class Brand(Base):
    __tablename__ = "brands"
    __table_args__ = {'schema': 'public'}

    id = Column(Integer, primary_key=True)
    name = Column(String, unique=True, nullable=False)
    # Add other brand fields as needed

class AutomatedImport(Base):
    __tablename__ = "automated_imports"
    __table_args__ = {'schema': 'raw_size_guides'}

    id = Column(Integer, primary_key=True)
    brand_name = Column(String)
    brand_id = Column(Integer, ForeignKey('public.brands.id'))
    product_type = Column(String)
    department = Column(String)
    category = Column(String)
    measurements = Column(JSON)
    unit_system = Column(String(8))
    image_path = Column(String)
    ocr_confidence = Column(Float)
    status = Column(String(20), default='pending_review')
    review_notes = Column(Text)
    reviewed_by = Column(Integer, ForeignKey('public.users.id'))
    reviewed_at = Column(DateTime)
    created_at = Column(DateTime, server_default=func.now())
    processed_at = Column(DateTime)
    import_metadata = Column('metadata', JSON)
    created_by = Column(String(255))

    # Relationships
    brand = relationship("Brand", backref="imports")

class SizeGuideUpload(Base):
    __tablename__ = "raw_size_guide_uploads"
    __table_args__ = {'schema': 'raw_size_guides'}

    id = Column(Integer, primary_key=True)
    brand_id = Column(Integer, ForeignKey('public.brands.id'), nullable=False)
    brand_name = Column(String, nullable=False)  # Denormalized for convenience
    gender = Column(String, nullable=False)  # Using String instead of Enum to match database
    category = Column(String, nullable=False)  # Using String instead of Enum to match database
    image_path = Column(String, nullable=False)  # Path to the uploaded screenshot
    status = Column(String, nullable=False, default='pending')  # Using String instead of Enum to match database
    error_message = Column(Text)  # For storing any processing errors
    uploaded_by = Column(Integer, ForeignKey('public.users.id'), nullable=False)
    uploaded_at = Column(DateTime, nullable=False, server_default=func.now())
    processed_at = Column(DateTime)  # When AI1 finished processing
    measurements_imported = Column(Boolean, default=False)  # Whether measurements were successfully imported

    # Relationships
    brand = relationship("Brand", backref="size_guide_uploads")
    uploader = relationship("User", backref="size_guide_uploads")

class SizeGuideUploadSchema(BaseModel):
    brand_name: str
    department: Department
    category: Category
    unit_system: UnitSystem 