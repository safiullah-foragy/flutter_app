# Group Chat Profile Photos Feature

## Overview
Enhanced the group chat feature with Messenger-style profile photos beside each message and the ability to set custom group photos.

## Features Implemented

### 1. Sender Profile Photos in Group Chats
Each message in a group chat now displays:
- **Small profile photo** (20px radius) beside the sender's name
- **Sender name** in gray text below the photo
- Only shown for **other users' messages** (not your own messages)
- **Fallback avatar** with colored circle and initial letter if no profile photo is set

### 2. Group Photo Display
Group photos are now displayed in multiple locations:
- **Messages list**: Group conversations show custom photo or default group icon
- **Chat header**: Group photo shown with group name and member count
- **Group info sheet**: Large group photo at the top of the sheet

### 3. Group Photo Upload
Admins can set/change group photos:
- **During group creation**: Tap the camera icon to select a photo before creating
- **After creation**: Admin can tap the group photo in group info to change it
- Photos are uploaded to Supabase storage
- System message sent when photo is updated
- Loading indicator shown during upload

## Technical Implementation

### Files Modified

#### 1. `lib/messages.dart`
**Changes:**
- Updated message display to show sender profile photo with name in group chats
- Added `_buildGroupAvatar()` helper method for group photo display
- Updated `_buildGroupTitle()` to show group photo in chat header
- Modified `_buildGroupConversationItem()` to use custom group photos

**Key Code:**
```dart
// Sender info with profile photo
Widget? senderInfoWidget;
if (widget.isGroup && !isMe && senderId.isNotEmpty) {
  senderInfoWidget = StreamBuilder<DocumentSnapshot>(
    stream: _firestore.collection('users').doc(senderId).snapshots(),
    builder: (context, userSnap) {
      String senderName = senderId;
      String? senderPhotoUrl;
      if (userSnap.hasData && userSnap.data!.exists) {
        final userData = userSnap.data!.data() as Map<String, dynamic>?;
        senderName = userData?['name'] ?? senderId;
        senderPhotoUrl = userData?['profile_image'];
      }
      return Padding(
        padding: const EdgeInsets.only(left: 12, bottom: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 10,
              backgroundImage: senderPhotoUrl != null && senderPhotoUrl.isNotEmpty
                  ? CachedNetworkImageProvider(senderPhotoUrl)
                  : null,
              child: senderPhotoUrl == null || senderPhotoUrl.isEmpty
                  ? Text(
                      senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
                      style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold),
                    )
                  : null,
            ),
            const SizedBox(width: 6),
            Text(
              senderName,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      );
    },
  );
}
```

#### 2. `lib/group_info_page.dart`
**Changes:**
- Added imports for `image_picker` and `supabase`
- Added `_imagePicker` and `_isUploadingPhoto` state variables
- Created `_updateGroupPhoto()` method for admin photo upload
- Updated header to display group photo with camera icon overlay
- Added loading indicator during photo upload

**Key Features:**
- Admin-only photo upload with permission check
- Image resizing to 800x800 for optimization
- Upload to Supabase 'message-images' bucket
- System message sent on photo update
- Error handling with user feedback

#### 3. `lib/create_group_page.dart`
**Changes:**
- Added imports for `image_picker` and `supabase`
- Added `_groupPhotoUrl` state variable
- Created `_pickGroupPhoto()` method
- Added group photo selection UI at top of create page
- Updated `_createGroup()` to include photo in group data

**Key Features:**
- Photo selection before group creation
- Visual feedback with camera icon overlay
- Tappable circular avatar (100px diameter)
- Helper text "Tap to set group photo"
- Photo stored in Firestore `group_photo` field

## Database Schema

### Firestore `conversations` Collection
```javascript
{
  is_group: true,
  group_name: "My Group",
  group_description: "Group description",
  group_photo: "https://supabase-url/message-images/group_photos/...",  // NEW FIELD
  group_admin: "admin_user_id",
  participants: ["user1", "user2", "user3"],
  // ... other fields
}
```

### Firestore `messages` Subcollection
System messages for photo updates:
```javascript
{
  sender_id: "admin_user_id",
  text: "updated the group photo",
  timestamp: 1733097600000,
  file_url: "",
  file_type: "system",
  reactions: {},
  edited: false
}
```

## User Workflows

### Setting Group Photo During Creation
1. User taps **"Create group"** button in Messages
2. Taps on the circular avatar at the top
3. Selects image from gallery
4. Image is uploaded (loading indicator shown)
5. Photo preview updates with selected image
6. User enters group name, description, and members
7. Taps **"CREATE"**
8. Group created with custom photo

### Changing Group Photo After Creation
1. Admin opens group chat
2. Taps group header or "Group Info" icon
3. In group info sheet, taps the group photo
4. Selects new image from gallery
5. Image is uploaded (loading indicator shown)
6. Photo updates across all views
7. System message sent: "Admin updated the group photo"
8. All members see updated photo

### Viewing Sender Photos in Group Chat
1. User opens group conversation
2. Messages from other users display:
   - Small circular profile photo (20px)
   - Sender name beside the photo
   - Message bubble below
3. User's own messages don't show photo/name
4. Photos update in real-time if users change profile pictures

## Storage Details

### Supabase Storage
- **Bucket**: `message-images`
- **Path format**: `group_photos/{conversationId}_{timestamp}.jpg`
- **Image specs**:
  - Max dimensions: 800x800px
  - Quality: 85%
  - Format: JPEG
- **Permissions**: Public read access required

## UI/UX Highlights

### Message Display
- Profile photos only shown for **other users** in group
- Photos are **small (20px radius)** to save space
- Name shown in **gray** (#808080) for subtle appearance
- **6px spacing** between photo and name
- **12px left padding** for alignment

### Group Avatar Display
- **Messages list**: 24px radius circular avatar
- **Chat header**: 16px radius with name and member count
- **Group info**: 40px radius with white background
- **Create page**: 50px radius with camera icon overlay

### Photo Upload Feedback
- **Loading state**: CircularProgressIndicator during upload
- **Success**: SnackBar "Group photo updated"
- **Error**: SnackBar with error message
- **Camera icon**: White icon on teal circular button

## Testing Checklist

### Profile Photos in Messages
- [ ] Send message in group as User A
- [ ] Check message shows profile photo and name from User B's view
- [ ] Verify User A doesn't see photo on their own message
- [ ] Update User A's profile photo
- [ ] Confirm photo updates in group chat for User B
- [ ] Test with user who has no profile photo (shows initial)

### Group Photo Upload - Creation
- [ ] Create new group
- [ ] Tap avatar to select photo
- [ ] Verify photo uploads and displays
- [ ] Create group and check photo appears in messages list
- [ ] Open group chat and verify photo in header
- [ ] Check group info sheet shows photo

### Group Photo Upload - Admin
- [ ] Open existing group as admin
- [ ] Open group info sheet
- [ ] Tap group photo
- [ ] Select new image
- [ ] Verify upload progress indicator
- [ ] Confirm photo updates everywhere
- [ ] Check system message sent
- [ ] Verify all members see new photo

### Group Photo Upload - Non-Admin
- [ ] Open group as non-admin member
- [ ] Open group info sheet
- [ ] Try to tap group photo
- [ ] Verify no camera icon shown
- [ ] Confirm tapping does nothing
- [ ] Check permission message if forced

### Edge Cases
- [ ] Create group without photo (shows default icon)
- [ ] Upload very large image (resized to 800x800)
- [ ] Cancel photo selection (no error)
- [ ] Network error during upload (error message shown)
- [ ] Delete group with custom photo
- [ ] User leaves group with custom photo

## Known Limitations

1. **No photo deletion**: Once set, group photo can only be replaced, not removed
2. **Admin only**: Only group admin can change photo (by design)
3. **No image preview**: No way to view full-size group photo
4. **Storage**: Old photos not automatically deleted when replaced

## Future Enhancements

### Photo Management
- Add option to remove group photo (reset to default)
- Implement photo deletion when replaced
- Add image cropping before upload
- Support photo selection from camera (not just gallery)

### UI Improvements
- Full-screen group photo viewer (tap to view)
- Photo change history in system messages
- Animated transitions when photo updates
- Progress percentage during upload

### Permissions
- Allow admins to restrict who can change photo
- Member voting system for photo changes
- Photo approval workflow

### Additional Features
- Multiple group photos (slideshow/carousel)
- Video thumbnails as group photos
- GIF support for group photos
- Profile photo borders/frames in group chats

## Deployment

### Prerequisites
- Supabase `message-images` bucket exists
- Bucket has public read permissions
- `image_picker` package added to `pubspec.yaml`

### Steps
1. No migration needed (new fields are optional)
2. Deploy app with updated code
3. Test photo upload functionality
4. Monitor Supabase storage usage
5. Set up storage lifecycle policies if needed

### Rollback Plan
If issues occur:
1. Field `group_photo` is optional (no breaking changes)
2. Old groups without photos will show default icon
3. Profile photos in messages gracefully fall back to initials
4. Remove photo upload UI but keep display logic

## Support

### Common Issues

**Issue**: Photo not uploading
- Check Supabase connection
- Verify bucket permissions
- Check file size limits
- Ensure internet connectivity

**Issue**: Profile photos not showing
- Confirm users have `profile_image` field set
- Check image URLs are accessible
- Verify cached_network_image working

**Issue**: Camera icon not visible
- Confirm user is the group admin
- Check `group_admin` field matches user ID
- Verify admin privileges not revoked

## Conclusion

The group chat profile photos feature brings a more familiar, Messenger-style experience to group conversations. Users can easily identify who sent each message, and admins can personalize their groups with custom photos. All features include proper error handling, loading states, and permission checks for a smooth user experience.
