# Supabase Storage: RLS examples for message-images / message-videos

This file contains example SQL policies you can apply in your Supabase project's SQL editor to allow authenticated client uploads to specific buckets used by the app (`message-images`, `message-videos`).

WARNING: Adjust these policies to match your security needs before using in production. For rapid development you can make the buckets public from the Supabase Storage UI.

---

## Quick dev option: make bucket public

1. In Supabase dashboard → Storage → Buckets → select `message-images` → toggle `Public`.
2. Repeat for `message-videos`.

This is the fastest way to get client uploads working, but exposes files to anyone with the object URL.

---

## RLS policies (recommended for authenticated uploads)

Open Supabase SQL editor and run the following (adjust `bucket_id` names as needed):

-- Allow authenticated inserts into all buckets (broad)
CREATE POLICY "Allow authenticated inserts into storage.objects" ON storage.objects
FOR INSERT
USING (auth.role() = 'authenticated')
WITH CHECK (auth.role() = 'authenticated');

-- Allow authenticated inserts only into message-images bucket
CREATE POLICY "Allow authenticated inserts into message-images" ON storage.objects
FOR INSERT
USING (auth.role() = 'authenticated' AND bucket_id = 'message-images')
WITH CHECK (auth.role() = 'authenticated' AND bucket_id = 'message-images');

-- Allow authenticated inserts only into message-videos bucket
CREATE POLICY "Allow authenticated inserts into message-videos" ON storage.objects
FOR INSERT
USING (auth.role() = 'authenticated' AND bucket_id = 'message-videos')
WITH CHECK (auth.role() = 'authenticated' AND bucket_id = 'message-videos');

-- Allow select (download) of public objects if you made the bucket public. If you keep RLS, you may also allow selects for authenticated users:
CREATE POLICY "Allow authenticated selects" ON storage.objects
FOR SELECT
USING (auth.role() = 'authenticated');

-- If you want to allow deletes/updates by the uploader only, you can add a policy like:
CREATE POLICY "Allow owner delete/update" ON storage.objects
FOR UPDATE, DELETE
USING (auth.role() = 'authenticated' AND metadata->>'uploader' = auth.uid);

---

Notes:
- Supabase `storage.objects` table stores metadata; actual object access still depends on bucket privacy.
- When you upload from the client, you may want to add metadata (e.g., `uploader: auth.user().id`) to be able to restrict deletes.
- If you use the Dart Supabase client, ensure the client uses an authenticated session (anon key + user sign-in) when uploading.

If you want, I can add a small helper in `lib/supabase.dart` to include `metadata: {'uploader': userId}` when uploading so the `owner delete/update` policy can be used.