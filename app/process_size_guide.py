import os
from datetime import datetime
import base64
import json
from openai import OpenAI
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from models import SizeGuideUpload, Brand, User
from dotenv import load_dotenv

load_dotenv()

def get_db_session():
    """Create a database session"""
    engine = create_engine('postgresql://seandavey@localhost:5432/tailor2')
    Session = sessionmaker(bind=engine)
    return Session()

def validate_measurements(data):
    """Validate the measurements data structure"""
    if not isinstance(data, dict):
        data = json.loads(data)
    
    required_keys = ["sizes", "measurements", "unit"]
    for key in required_keys:
        if key not in data:
            raise ValueError(f"Missing required key: {key}")
    
    if not isinstance(data["sizes"], list):
        raise ValueError("Sizes must be a list")
    
    if not isinstance(data["measurements"], dict):
        raise ValueError("Measurements must be a dictionary")
    
    size_count = len(data["sizes"])
    for measurement_type, values in data["measurements"].items():
        if not isinstance(values, list):
            raise ValueError(f"Measurement {measurement_type} must be a list")
        if len(values) != size_count:
            raise ValueError(f"Measurement {measurement_type} count doesn't match size count")
    
    return data

def process_size_guide(upload_id: int):
    """Process a single size guide using GPT-4 Vision"""
    client = OpenAI()
    db = get_db_session()
    
    # Get the upload record
    upload = db.query(SizeGuideUpload).filter_by(id=upload_id).first()
    if not upload:
        raise ValueError(f"Upload {upload_id} not found")
    
    # Update status to processing
    upload.status = 'processing'
    upload.processed_at = datetime.utcnow()
    db.commit()
    
    try:
        # Read the image
        with open(upload.image_path, "rb") as image_file:
            image_data = image_file.read()
            
        # Create our system prompt
        system_prompt = f"""You are analyzing a clothing size guide image.
        Brand: {upload.brand_name}
        Gender: {upload.gender}
        Category: {upload.category}
        
        Extract all measurements in the following format:
        {{
          "sizes": ["XS", "S", "M", "L", "XL", "XXL"],
          "measurements": {{
            "chest": {{
              "min": [31, 35, 38, 42, 46, 49],
              "max": [34, 37, 40, 45, 48, 52]
            }},
            "neck": {{
              "min": [14, 14, 15, 16, 17, 18],
              "max": [14, 14.5, 15.5, 16.5, 17.5, 18.5]
            }},
            "sleeve": {{
              "min": [32, 32, 34, 35, 36, 37],
              "max": [32.5, 33, 35, 36, 37, 38]
            }},
            "waist": {{
              "min": [26, 28, 31, 35, 40, 43],
              "max": [28, 30, 34, 38, 42, 45]
            }}
          }},
          "unit": "inches"
        }}
        
        Important rules:
        1. Convert all measurements to inches if they're in cm
        2. Keep measurements to 1 decimal place if needed
        3. Ensure arrays of measurements align with sizes array
        4. Include ALL measurements shown in the size guide
        5. For range measurements (e.g., "31"-34""), split into min and max values
        6. If you're unsure about any measurement, mark it with "?" suffix
        7. Maintain the exact order of sizes as shown in the guide
        """
        
        response = client.chat.completions.create(
            model="gpt-4-0125-preview",
            messages=[
                {
                    "role": "system",
                    "content": system_prompt
                },
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": f"Please analyze this size guide for {upload.brand_name} {upload.gender} {upload.category} and extract the measurements in JSON format."
                        },
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": f"data:image/jpeg;base64,{base64.b64encode(image_data).decode()}"
                            }
                        }
                    ]
                }
            ],
            max_tokens=1000
        )
        
        # Parse and validate the response
        measurements = validate_measurements(response.choices[0].message.content)
        
        # TODO: Store measurements in automated_imports table
        
        # Update status to completed
        upload.status = 'completed'
        upload.measurements_imported = True
        db.commit()
        
    except Exception as e:
        upload.status = 'failed'
        upload.error_message = str(e)
        db.commit()
        raise

if __name__ == "__main__":
    import sys
    if len(sys.argv) != 2:
        print("Usage: python process_size_guide.py <upload_id>")
        sys.exit(1)
    
    upload_id = int(sys.argv[1])
    process_size_guide(upload_id) 