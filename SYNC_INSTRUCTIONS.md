# Syncing Between Local and RDS Databases

This guide explains how to work with your local database for testing and then sync changes to the production RDS database.

## Database Configurations

### Local Database
- Host: `localhost`
- Database: `tailor2`
- User: `seandavey`
- Contains development and test data

### RDS Database (Production)
- Host: `tailor2-production.cpgs24uuo973.us-east-2.rds.amazonaws.com`
- Database: `tailor2`
- User: `tailor2_admin`
- Contains production data

## Development Workflow

1. **Work Locally First**
   - Make sure your `.env` file points to local database:
     ```
     DATABASE_URL=postgresql://seandavey@localhost/tailor2
     TAILOR2_DATABASE_URL=postgresql://seandavey@localhost/tailor2
     ```
   - Run the application:
     ```bash
     uvicorn app.main:app --reload
     ```
   - Upload and process size guides at http://127.0.0.1:8000
   - All data will be stored in your local database

2. **Sync to RDS**
   - When ready to push changes to production, run:
     ```bash
     python -m app.sync_to_rds
     ```
   - The script will:
     - Find all new records since last sync
     - Copy them to RDS
     - Update the sync timestamp
     - Handle errors gracefully

3. **Verify Sync**
   - The script will print:
     - Number of new records found
     - Each record as it's synced
     - Any errors that occur
     - Confirmation when sync is complete

## What Gets Synced

The sync process copies the following data:
- New size guide imports (`raw_size_guides.automated_imports`)
- Associated measurements and metadata
- AI analysis results
- Upload timestamps and user information

## Troubleshooting

If you encounter issues:

1. **Connection Problems**
   - Check your VPN/network connection
   - Verify RDS security group allows your IP
   - Test connection:
     ```bash
     psql -h tailor2-production.cpgs24uuo973.us-east-2.rds.amazonaws.com -U tailor2_admin -d tailor2
     ```

2. **Sync Errors**
   - Check `last_sync.json` for the last successful sync
   - Delete `last_sync.json` to force full sync
   - Look for error messages in the script output

3. **Data Mismatches**
   - Use pgAdmin or psql to compare data
   - Check record counts:
     ```sql
     SELECT COUNT(*) FROM raw_size_guides.automated_imports;
     ```

## Safety Notes

1. **Always test locally first**
   - Never develop directly against RDS
   - Use local database for testing new features
   - Only sync when changes are validated

2. **Backup before big syncs**
   - For large changes, backup RDS first:
     ```bash
     pg_dump -h tailor2-production.cpgs24uuo973.us-east-2.rds.amazonaws.com -U tailor2_admin tailor2 > backup.sql
     ```

3. **Monitor space**
   - Keep an eye on RDS storage usage
   - Clean up old/unused data
   - Archive if needed

## Need Help?

If you need assistance:
1. Check the sync script output
2. Look for error messages
3. Contact the database administrator
4. Consider rolling back to last known good state 