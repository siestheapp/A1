import os
import json
from datetime import datetime
from typing import Dict, Any, List
import base64
import requests
from io import BytesIO
from PIL import Image
from dotenv import load_dotenv

load_dotenv()

class SizeGuideProcessor:
    def __init__(self, upload_dir: str = "uploads"):
        self.upload_dir = upload_dir
        os.makedirs(upload_dir, exist_ok=True)
        self.openai_api_key = os.getenv("OPENAI_API_KEY")
        
        # Load training examples if they exist
        self.training_examples = self._load_training_examples()

    async def process_image(self, image_path: str) -> Dict[str, Any]:
        """
        Process the size guide image using GPT-4 Vision
        """
        # Use GPT-4 Vision for analysis
        result = await self._analyze_with_gpt4_vision(image_path)
        
        return {
            "measurements": result.get("measurements", {}),
            "confidence": result.get("confidence", 0.0),
            "ai_analysis": result
        }

    async def _analyze_with_gpt4_vision(self, image_path: str) -> Dict[str, Any]:
        """
        Analyze the size guide image using GPT-4 Vision with training examples
        """
        # Convert image to base64
        with open(image_path, "rb") as image_file:
            image_data = base64.b64encode(image_file.read()).decode('utf-8')
        
        # Prepare system message with enhanced instructions
        system_message = """You are an expert at analyzing clothing size guides for the Tailor app, which helps users find clothes that fit them perfectly. Your task is to extract and standardize measurements with perfect accuracy for comparison across different brands.

Key Instructions:
1. Size Labels and Correlations:
   - Extract ALL size variations (XS/S/M/L/XL, numeric sizes, etc.)
   - Document size correlations (e.g., "US 4 = UK 8 = EU 36")
   - Note fit variations (Regular/Slim/Relaxed)
   - Maintain brand-specific size formatting

2. Critical Measurements:
   - Primary measurements (MUST HAVE):
     * Chest/Bust: Always in range format (e.g., "38-40")
     * Shoulders: Measure point to point
     * Length: Total garment length
   - Secondary measurements (if available):
     * Neck: Circumference
     * Sleeve: From shoulder seam
     * Waist: Natural waistline
     * Hip: Fullest part
   - Ensure all measurements are in the original unit system

3. Measurement Validation:
   - Verify size progression logic (each size should increase consistently)
   - Check measurement relationships (chest > waist for most garments)
   - Validate measurement ranges (e.g., typical chest range is 2-4 units)
   - Flag any measurements outside normal ranges

4. Fit Information:
   - Note garment type and intended fit
   - Capture measurement points ("chest measured flat", "waist at natural line")
   - Record any stretch/fabric allowances
   - Document any brand-specific fit notes

5. Quality Control:
   - Assign confidence scores to each measurement (0.0-1.0)
   - Higher confidence for clearly stated measurements
   - Lower confidence for implied or calculated measurements
   - Flag potential OCR errors or unclear values

Output Format:
{
  "measurements": {
    "sizes": [
      {
        "label": string,  // Original size label
        "type": string,  // Regular/Slim/Relaxed
        "correlations": {  // Size correlations
          "US": string,
          "UK": string,
          "EU": string
        },
        "measurements": {
          "chest": {
            "range": string,  // "min-max" format
            "point": string,  // How to measure
            "confidence": float  // 0.0-1.0
          },
          // ... other measurements
        }
      }
    ],
    "fit_notes": {
      "garment_type": string,
      "intended_fit": string,
      "fabric_properties": string
    },
    "measurement_points": {},  // How/where to measure
    "quality_flags": []  // Warnings about unusual values
  },
  "metadata": {
    "brand_name": string,
    "unit_system": string,  // "cm" or "inches"
    "confidence": float,  // Overall confidence
    "size_type": string  // Letter/Number/Mixed
  }
}"""

        # Add training examples if available
        if self.training_examples:
            system_message += "\n\nReference Examples:\n"
            for example in self.training_examples:
                system_message += f"\nExample {example['id']}:\n{json.dumps(example['output'], indent=2)}"

        # Prepare the API request
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.openai_api_key}"
        }
        
        payload = {
            "model": "gpt-4-vision-preview",
            "messages": [
                {
                    "role": "system",
                    "content": system_message
                },
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": "Analyze this size guide with perfect accuracy. Extract all measurements and format them according to the specified structure. Pay special attention to measurement ranges, size variants, and any special instructions."
                        },
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": f"data:image/jpeg;base64,{image_data}"
                            }
                        }
                    ]
                }
            ],
            "max_tokens": 1500
        }
        
        try:
            response = requests.post(
                "https://api.openai.com/v1/chat/completions",
                headers=headers,
                json=payload
            )
            response.raise_for_status()
            
            # Parse the response
            result = response.json()
            content = result['choices'][0]['message']['content']
            
            # Extract the JSON from the content
            try:
                return json.loads(content)
            except json.JSONDecodeError:
                # If GPT-4 didn't return valid JSON, extract it from the text
                import re
                json_str = re.search(r'{.*}', content, re.DOTALL)
                if json_str:
                    return json.loads(json_str.group())
                return {"measurements": {}, "confidence": 0.0}
                
        except Exception as e:
            print(f"Error in GPT-4 Vision analysis: {str(e)}")
            return {"measurements": {}, "confidence": 0.0}

    def add_training_example(self, image_path: str, correct_output: Dict[str, Any]) -> None:
        """
        Add a new training example to improve future analyses
        """
        example = {
            "id": len(self.training_examples) + 1,
            "image_path": image_path,
            "output": correct_output,
            "added_at": datetime.utcnow().isoformat()
        }
        
        self.training_examples.append(example)
        self._save_training_examples()

    def _load_training_examples(self) -> List[Dict[str, Any]]:
        """
        Load training examples from disk
        """
        try:
            with open('training_examples.json', 'r') as f:
                return json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return []

    def _save_training_examples(self) -> None:
        """
        Save training examples to disk
        """
        with open('training_examples.json', 'w') as f:
            json.dump(self.training_examples, f, indent=2)

    def save_image(self, image: Image.Image, filename: str) -> str:
        """
        Save the uploaded image and return the path
        """
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        safe_filename = f"{timestamp}_{filename}"
        filepath = os.path.join(self.upload_dir, safe_filename)
        image.save(filepath)
        return filepath 