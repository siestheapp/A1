from sqlalchemy import Column, Integer, String, JSON, DateTime, Float, ForeignKey, Text
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

class Brand(Base):
    __tablename__ = "brands"
    __table_args__ = {'schema': 'public'}

    id = Column(Integer, primary_key=True)
    name = Column(String, nullable=False)
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
    status = Column(String(20), default='PENDING')
    review_notes = Column(Text)
    reviewed_by = Column(Integer, ForeignKey('public.users.id'))
    reviewed_at = Column(DateTime)
    created_at = Column(DateTime, server_default=func.now())
    processed_at = Column(DateTime)
    extra_data = Column(JSON)
    raw_text = Column(Text)
    created_by = Column(String(255))

    # Relationships
    brand = relationship("Brand", backref="imports")

class SizeGuideUpload(BaseModel):
    brand_name: str
    department: Department
    category: Category
    unit_system: UnitSystem 