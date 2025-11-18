# Supabase Document Storage Setup

This guide explains how to set up the document sharing buckets in Supabase for the messaging feature.

## Required Buckets

You need to create the following buckets in your Supabase project:

1. **message-docs** - For general documents (Word, etc.)
2. **message-pdf** - For PDF files
3. **message-txt** - For text files

## Setup Instructions

### 1. Access Supabase Dashboard

1. Go to [Supabase Dashboard](https://app.supabase.com)
2. Select your project: `nqydqpllowakssgfpevt`
3. Navigate to **Storage** in the left sidebar

### 2. Create Buckets

For each bucket (message-docs, message-pdf, message-txt):

1. Click **New bucket**
2. Enter the bucket name (e.g., `message-docs`)
3. Set **Public bucket** to **ON** (to allow file sharing between users)
4. Click **Create bucket**

Repeat for all three buckets.

### 3. Set Bucket Permissions (RLS Policies)

After creating each bucket, you need to set up Row Level Security (RLS) policies to control access.

#### For All Buckets (message-docs, message-pdf, message-txt):

1. Click on the bucket name
2. Go to the **Policies** tab
3. Click **New Policy**

Create the following policies for each bucket:

##### Policy 1: Allow Authenticated Users to Upload
```sql
-- Policy Name: Allow authenticated uploads
-- Allowed operation: INSERT

CREATE POLICY "Allow authenticated uploads"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'message-docs');  -- Change bucket name for each
```

##### Policy 2: Allow Authenticated Users to Read
```sql
-- Policy Name: Allow authenticated reads
-- Allowed operation: SELECT

CREATE POLICY "Allow authenticated reads"
ON storage.objects FOR SELECT
TO authenticated
USING (bucket_id = 'message-docs');  -- Change bucket name for each
```

##### Policy 3: Allow Users to Delete Their Own Files
```sql
-- Policy Name: Allow users to delete own files
-- Allowed operation: DELETE

CREATE POLICY "Allow users to delete own files"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'message-docs' AND auth.uid()::text = owner);  -- Change bucket name for each
```

### 4. Alternative: Simple Public Access (Less Secure)

If you want simpler setup (but less secure), you can make the buckets fully public:

1. Click on the bucket name
2. Go to **Configuration**
3. Enable **Public** toggle
4. This allows anyone with the URL to access the files

**Note:** This is NOT recommended for production as it exposes all files publicly.

### 5. File Size Limits

By default, Supabase allows uploads up to 50MB. To change this:

1. Go to bucket **Configuration**
2. Set **File size limit** to your desired value (e.g., 10MB, 50MB, 100MB)
3. Click **Save**

Recommended limits:
- **message-pdf**: 50MB
- **message-docs**: 25MB
- **message-txt**: 5MB

### 6. Allowed MIME Types (Optional)

You can restrict which file types can be uploaded:

1. Go to bucket **Configuration**
2. Set **Allowed MIME types**:
   - **message-pdf**: `application/pdf`
   - **message-docs**: `application/msword,application/vnd.openxmlformats-officedocument.wordprocessingml.document`
   - **message-txt**: `text/plain`
3. Click **Save**

## Testing

After setup, test the document sharing:

1. Run the app
2. Open a conversation
3. Tap the **+** icon (leftmost in input row)
4. Select **Document**, **PDF**, or **Text File**
5. Pick a file and send it
6. Verify the recipient can open/download the file

## Troubleshooting

### Error: "Bucket not found"
- Verify bucket name spelling matches exactly: `message-docs`, `message-pdf`, `message-txt`
- Check that buckets are created in the correct Supabase project

### Error: "New row violates row-level security policy"
- Check that RLS policies are created for INSERT, SELECT, DELETE
- Ensure `authenticated` role is specified in policies
- Verify user is logged in (has valid JWT token)

### Files not accessible
- Check bucket is set to **Public** OR has proper SELECT policy
- Verify CORS settings in Supabase if accessing from web
- Check browser console for specific error messages

### Upload fails
- Verify file size is within bucket limits
- Check MIME type restrictions if configured
- Ensure user is authenticated
- Check INSERT policy allows the upload

## Security Best Practices

1. **Use RLS policies** instead of public buckets
2. **Set file size limits** to prevent abuse
3. **Restrict MIME types** to only what's needed
4. **Enable virus scanning** if available in your Supabase plan
5. **Monitor storage usage** in Supabase dashboard
6. **Implement user quotas** in your app logic to prevent spam
7. **Clean up old files** periodically (implement deletion logic)

## Storage Quotas

Free tier includes:
- 1GB storage
- 2GB bandwidth per month

Monitor usage in: **Project Settings → Billing → Usage**

## Additional Features to Implement

Consider adding these features in the future:

1. File preview before sending
2. File download progress indicator
3. Automatic file cleanup after X days
4. User storage quota tracking
5. File compression before upload
6. Thumbnail generation for documents
7. Virus scanning integration
8. Encrypted file storage

## SQL Queries for Manual Policy Creation

If you prefer to create policies via SQL editor:

```sql
-- For message-docs bucket
CREATE POLICY "Allow authenticated uploads" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'message-docs');

CREATE POLICY "Allow authenticated reads" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'message-docs');

CREATE POLICY "Allow users to delete own files" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'message-docs' AND auth.uid()::text = owner);

-- Repeat for message-pdf and message-txt, changing bucket_id accordingly
```

## Complete Setup Checklist

- [ ] Created `message-docs` bucket (public: ON)
- [ ] Created `message-pdf` bucket (public: ON)
- [ ] Created `message-txt` bucket (public: ON)
- [ ] Set up INSERT policy for each bucket
- [ ] Set up SELECT policy for each bucket
- [ ] Set up DELETE policy for each bucket
- [ ] Configured file size limits
- [ ] (Optional) Configured MIME type restrictions
- [ ] Tested document upload in app
- [ ] Tested document download/open in app
- [ ] Verified files accessible to other users

## Support

For issues with Supabase setup:
- [Supabase Documentation](https://supabase.com/docs/guides/storage)
- [Supabase Discord](https://discord.supabase.com)
- [Supabase Storage RLS Guide](https://supabase.com/docs/guides/storage/security/access-control)
