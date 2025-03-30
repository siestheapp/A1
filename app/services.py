import pytesseract
from PIL import Image
import os
import json
from datetime import datetime
from typing import Dict, Any
import re
from sqlalchemy.orm import Session
from . import models
from .models import Department, Category, UnitSystem

class SizeGuideProcessor:
    def __init__(self, upload_dir: str = "uploads"):
        self.upload_dir = upload_dir
        os.makedirs(upload_dir, exist_ok=True)
        
        # Common words to exclude from brand names
        self.exclude_words = {
            'size', 'chart', 'guide', 'measurement', 'men', 'women', 'kids', 'children',
            'tops', 'bottoms', 'dresses', 'shirts', 'pants', 'regular', 'slim', 'tall',
            'petite', 'chest', 'neck', 'waist', 'bust', 'hip', 'arm', 'length', 'inches',
            'centimeters', 'cm', 'in', 'kg', 'lbs', 'pounds', 'kilograms', 'help', 'size',
            'conversion', 'measuring', 'guide', 'how', 'to', 'measure', 'yourself',
            'find', 'your', 'perfect', 'fit', 'international', 'sizing', 'chart'
        }
        
        # Common brand name patterns
        self.brand_patterns = [
            r'^[A-Z][a-zA-Z]+$',  # Single word with capital first letter
            r'^[A-Z][a-zA-Z]+ [A-Z][a-zA-Z]+$',  # Two words with capital first letters
            r'^[A-Z][a-zA-Z]+ & [A-Z][a-zA-Z]+$',  # Two words with & between
            r'^[A-Z][a-zA-Z]+\.$',  # Single word with period
            r'^[A-Z][a-zA-Z]+ [A-Z][a-zA-Z]+\.$',  # Two words with period
        ]

    def process_image(self, image: Image.Image, db: Session, brand_name: str, department: Department, category: Category, unit_system: UnitSystem) -> Dict[str, Any]:
        """
        Process the size guide image using user-provided metadata
        """
        # Convert image to grayscale for better OCR
        gray_image = image.convert('L')
        
        # Perform OCR
        text = pytesseract.image_to_string(gray_image)
        
        # Debug: Print raw OCR text
        print("\nRaw OCR Text:")
        print("=" * 50)
        print(text)
        print("=" * 50)
        
        # Process the extracted text
        measurements = self._parse_measurements(text)
        
        # Try to match brand with existing brands
        brand_id = self._match_brand(brand_name, db)
        
        # Determine product type from department
        product_type = f"{department.value} Clothing"
        
        return {
            "brand_name": brand_name,
            "brand_id": brand_id,
            "product_type": product_type,
            "measurements": measurements,
            "raw_text": text,
            "ocr_confidence": self._calculate_ocr_confidence(text)
        }

    def save_image(self, image: Image.Image, filename: str) -> str:
        """
        Save the uploaded image and return the path
        """
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        safe_filename = f"{timestamp}_{filename}"
        filepath = os.path.join(self.upload_dir, safe_filename)
        image.save(filepath)
        return filepath

    def _parse_measurements(self, text: str) -> Dict[str, Any]:
        """
        Parse the extracted text to identify size measurements
        """
        measurements = {
            "sizes": [],
            "categories": [],
            "measurement_types": []
        }
        
        lines = text.split('\n')
        current_category = None
        
        for line in lines:
            line = line.strip()
            if not line:
                continue
                
            # Detect measurement categories (e.g., REGULAR, SLIM, TALL)
            if any(cat in line.upper() for cat in ['REGULAR', 'SLIM', 'TALL', 'PETITE']):
                current_category = line.strip()
                if current_category not in measurements["categories"]:
                    measurements["categories"].append(current_category)
                continue
            
            # Detect measurement types (e.g., Chest, Neck, Waist)
            if any(measure in line.lower() for measure in ['chest', 'neck', 'waist', 'bust', 'hip', 'arm']):
                measurements["measurement_types"].append(line.strip())
                continue
            
            # Parse size measurements
            # Look for patterns like "xs 32-34 13-13.5 26-28 31-32"
            size_match = re.match(r'^([A-Za-z]+)\s+([\d.-]+)\s+([\d.-]+)\s+([\d.-]+)\s+([\d.-]+)', line)
            if size_match:
                size_data = {
                    "size": size_match.group(1).upper(),
                    "measurements": {
                        "chest": size_match.group(2),
                        "neck": size_match.group(3),
                        "waist": size_match.group(4),
                        "arm_length": size_match.group(5)
                    }
                }
                measurements["sizes"].append(size_data)
        
        return measurements

    def _extract_brand_name(self, text: str) -> str:
        """
        Extract brand name from the text using improved detection logic
        """
        lines = text.split('\n')
        potential_brands = []
        
        # Debug: Print all lines for brand detection
        print("\nBrand Detection Lines:")
        print("=" * 50)
        
        for line in lines:
            line = line.strip()
            if not line:
                continue
                
            print(f"Processing line: '{line}'")
            
            # Skip lines that are too short or contain common size guide words
            if len(line) < 2 or any(word in line.lower() for word in self.exclude_words):
                print(f"Skipping: Contains excluded word or too short")
                continue
                
            # Skip lines that are just numbers or measurements
            if re.match(r'^[\d\s\-\.]+$', line):
                print(f"Skipping: Numbers only")
                continue
                
            # Skip lines that look like size measurements
            if re.match(r'^[A-Za-z]+\s+[\d\s\-\.]+$', line):
                print(f"Skipping: Size measurement")
                continue
                
            # Skip lines that are just categories or measurement types
            if any(cat in line.upper() for cat in ['REGULAR', 'SLIM', 'TALL', 'PETITE']):
                print(f"Skipping: Category")
                continue
                
            # Skip lines that are just measurement units
            if any(unit in line.lower() for unit in ['inches', 'centimeters', 'cm', 'in']):
                print(f"Skipping: Measurement unit")
                continue
                
            # Check if the line matches any brand name patterns
            if any(re.match(pattern, line) for pattern in self.brand_patterns):
                print(f"Found matching brand pattern: {line}")
                potential_brands.insert(0, line)  # Add to front of list
                continue
                
            # Add other potential brand names
            print(f"Adding as potential brand: {line}")
            potential_brands.append(line)
        
        print("\nPotential brands found:", potential_brands)
        print("=" * 50)
        
        # If we found potential brand names, return the first one
        if potential_brands:
            # Clean up the brand name
            brand = potential_brands[0]
            # Remove any trailing/leading special characters
            brand = re.sub(r'^[^a-zA-Z0-9]+|[^a-zA-Z0-9]+$', '', brand)
            # Replace multiple spaces with single space
            brand = re.sub(r'\s+', ' ', brand)
            return brand.strip()
            
        return "Unknown Brand"

    def _match_brand(self, brand_name: str, db: Session) -> int:
        """
        Try to match the extracted brand name with existing brands in the database
        """
        # First try exact match
        brand = db.query(models.Brand).filter(models.Brand.name == brand_name).first()
        if brand:
            return brand.id
            
        # Then try case-insensitive match
        brand = db.query(models.Brand).filter(models.Brand.name.ilike(brand_name)).first()
        if brand:
            return brand.id
            
        # Then try partial match
        brand = db.query(models.Brand).filter(models.Brand.name.ilike(f"%{brand_name}%")).first()
        if brand:
            return brand.id
            
        return None

    def _calculate_ocr_confidence(self, text: str) -> float:
        """
        Calculate a confidence score for the OCR results
        """
        # This is a simple implementation - could be made more sophisticated
        confidence = 0.0
        
        # Check for presence of key elements
        if any(size in text.lower() for size in ['xs', 's', 'm', 'l', 'xl', 'xxl']):
            confidence += 0.3
            
        if any(measure in text.lower() for measure in ['chest', 'waist', 'hip']):
            confidence += 0.3
            
        if any(unit in text.lower() for unit in ['cm', 'in', 'mm']):
            confidence += 0.2
            
        if any(cat in text.lower() for cat in ['regular', 'slim', 'tall']):
            confidence += 0.2
            
        return min(confidence, 1.0) 