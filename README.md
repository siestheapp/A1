# Tailor2 Size Guide Processor

This tool processes screenshots of clothing brand size guides and stores the extracted data in a PostgreSQL database.

## Features

- Accepts image uploads of size guides
- Uses OCR to extract size information
- Stores structured data in PostgreSQL
- RESTful API interface

## Prerequisites

- Python 3.8+
- PostgreSQL
- Tesseract OCR installed on your system
  - For macOS: `brew install tesseract`
  - For Ubuntu: `sudo apt-get install tesseract-ocr`
  - For Windows: Download from https://github.com/UB-Mannheim/tesseract/wiki

## Setup

1. Create a virtual environment:
```bash
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
```

2. Install dependencies:
```bash
pip install -r requirements.txt
```

3. Create a `.env` file with your database configuration:
```
# For local development
DATABASE_URL=postgresql://seandavey@localhost/tailor2

# For production
# DATABASE_URL=postgresql://tailor2_admin:password@tailor2-production.cpgs24uuo973.us-east-2.rds.amazonaws.com/tailor2
```

4. Run the application:
```bash
uvicorn app.main:app --reload
```

## API Endpoints

- POST `/upload`: Upload a size guide image
- GET `/size-guides`: List all processed size guides
- GET `/size-guides/{id}`: Get details of a specific size guide

## Database Setup

### Local Development Database
- Database Name: `tailor2`
- Host: `localhost`
- User: `seandavey`
- Contains development data and test records

### Production RDS Database
- Database Name: `tailor2`
- Host: `tailor2-production.cpgs24uuo973.us-east-2.rds.amazonaws.com`
- User: `tailor2_admin`
- Production environment database

## A1 Automated Import System

### Overview
A1 is an automated system for processing and importing size guides. It uses OCR to extract measurements from size guide images and stores them in a structured format.

### Database Schema
The A1 system uses the `raw_size_guides` schema, which contains:

#### automated_imports Table
Tracks the status and data of automated size guide imports.

**Columns:**
- `brand_name`: Name of the brand
- `product_type`: Type of product (e.g., shirts, pants)
- `department`: Department classification
- `category`: Product category
- `measurements`: Extracted measurement data
- `unit_system`: Measurement system (metric/imperial)
- `image_path`: Path to the uploaded size guide image
- `ocr_confidence`: Confidence score of OCR extraction
- `status`: Current status of the import
- `review_notes`: Notes from manual review
- `reviewed_by`: User who reviewed the import
- `reviewed_at`: Timestamp of review
- `created_at`: Record creation timestamp
- `processed_at`: Processing completion timestamp
- `metadata`: Additional import metadata
- `brand_id`: Foreign key to brands table

### Database Synchronization
- Changes made to the local database do not automatically sync to RDS
- To update RDS with local changes:
  1. Create a backup of local database
  2. Restore backup to RDS
  - OR -
  1. Manually apply schema changes to RDS
  2. Use database migration tools for structured updates

### Important Notes
- Always test new features and changes in the local database first
- Production data in RDS should be treated with care
- Keep track of schema changes and ensure both databases remain in sync 