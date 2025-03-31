# Tailor Size Guide Processing System - Troubleshooting Guide

## Project Overview
This is a system designed to automatically process clothing size guides using GPT-4 Vision. The system:
1. Takes uploaded size guide images
2. Uses GPT-4 Vision to extract measurements and size information
3. Stores the processed data in a PostgreSQL database
4. Manages the processing workflow through status tracking

## Database Structure
- Schema: `raw_size_guides`
- Main Tables:
  - `raw_size_guide_uploads`: Stores uploaded size guides and their processing status
  - `automated_imports`: Tracks the automated processing results

### Key Enums
We've set up several ENUM types for data consistency:
- `gender`: `['Mens', 'Womens']`
- `category`: `['Tops', 'Bottoms', 'Dresses', 'Outerwear', 'Suits', 'Activewear', 'Swimwear', 'Underwear', 'Accessories']`
- `upload_status`: `['pending', 'processing', 'completed', 'failed', 'manual_review']`

## Current Issue
We're trying to integrate GPT-4 Vision for size guide processing but encountering model access issues:

### The Problem
1. The script (`app/process_size_guide.py`) attempts to use GPT-4 Vision to analyze size guide images
2. We're getting errors related to model access and image processing capabilities
3. We've tried several model names:
   - `gpt-4-vision-preview` (deprecated)
   - `gpt-4-turbo-preview` (doesn't support images)
   - `gpt-4-1106-vision-preview` (deprecated)
   - `gpt-4-0125-preview` (doesn't support images)

### What We've Done
1. Set up OpenAI API access with proper permissions
2. Updated the model names multiple times
3. Configured the image data to be sent as base64-encoded data URLs
4. Set up proper database schema and ENUM types

### Next Steps Needed
1. Confirm the correct model name for GPT-4 Vision capabilities
2. Verify the correct format for sending images to the API
3. Ensure all necessary API permissions are properly set
4. Test the image processing pipeline

## Environment Details
- Python dependencies in `requirements.txt`
- Using OpenAI Python client version 1.12.0
- PostgreSQL database
- Key environment variables needed:
  - `OPENAI_API_KEY`
  - Database connection details

## Files to Focus On
1. `app/process_size_guide.py` - Main processing script
2. `.env` - API key configuration
3. Database schema in `raw_size_guides`

## Questions for ChatGPT
1. What is the current correct model name for GPT-4 Vision capabilities?
2. Is our image data format correct for the API?
3. Are we missing any required parameters in the API call?
4. What's the best way to handle the image processing pipeline? 