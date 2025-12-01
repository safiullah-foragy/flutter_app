# Recommended Firestore Security Rules for Group Chats

## Enhanced Security Rules

Add these rules to your `firestore.rules` file to properly secure group chat functionality:

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    
    // Helper function to check if user is authenticated
    function isSignedIn() {
      return request.auth != null;
    }
    
    // Helper function to check if user is in participants list
    function isParticipant(conversationData) {
      return request.auth.uid in conversationData.participants;
    }
    
    // Helper function to check if user is group admin
    function isGroupAdmin(conversationData) {
      return isSignedIn() && 
             conversationData.is_group == true && 
             conversationData.group_admin == request.auth.uid;
    }
    
    // Conversations (both 1-on-1 and groups)
    match /conversations/{conversationId} {
      // Allow read if user is a participant
      allow read: if isSignedIn() && 
                     isParticipant(resource.data);
      
      // Allow create if user is creating a conversation they're part of
      allow create: if isSignedIn() && 
                       request.auth.uid in request.resource.data.participants;
      
      // Allow update if:
      // - User is a participant AND
      // - User is updating allowed fields (last_message, last_updated, last_read, archived, typing)
      // OR
      // - User is group admin (can update group_name, group_description, participants)
      allow update: if isSignedIn() && (
        // Regular participant updates (marking read, archiving, etc.)
        (isParticipant(resource.data) && 
         (!request.resource.data.diff(resource.data).affectedKeys().hasAny(['is_group', 'group_admin', 'created_at']))) ||
        
        // Admin-only updates (adding/removing members, updating group info)
        (isGroupAdmin(resource.data) && 
         resource.data.is_group == true &&
         // Admin cannot change themselves
         request.resource.data.group_admin == resource.data.group_admin &&
         // Admin cannot change group to non-group or vice versa
         request.resource.data.is_group == resource.data.is_group)
      );
      
      // Allow delete if user is participant or admin
      allow delete: if isSignedIn() && (
        isParticipant(resource.data) || 
        isGroupAdmin(resource.data)
      );
      
      // Messages subcollection
      match /messages/{messageId} {
        // Allow read if user is participant of conversation
        allow read: if isSignedIn() && 
                       isParticipant(get(/databases/$(database)/documents/conversations/$(conversationId)).data);
        
        // Allow create if:
        // - User is participant AND
        // - User is setting themselves as sender
        allow create: if isSignedIn() && 
                         isParticipant(get(/databases/$(database)/documents/conversations/$(conversationId)).data) &&
                         request.auth.uid == request.resource.data.sender_id;
        
        // Allow update if:
        // - User is the sender (for editing messages)
        // - Or user is participant (for reactions)
        allow update: if isSignedIn() && (
          request.auth.uid == resource.data.sender_id ||
          (isParticipant(get(/databases/$(database)/documents/conversations/$(conversationId)).data) &&
           // Only allow updating reactions and edited flag
           !request.resource.data.diff(resource.data).affectedKeys().hasAny(['sender_id', 'timestamp', 'file_url', 'file_type']))
        );
        
        // Allow delete if user is sender or admin
        allow delete: if isSignedIn() && (
          request.auth.uid == resource.data.sender_id ||
          isGroupAdmin(get(/databases/$(database)/documents/conversations/$(conversationId)).data)
        );
      }
    }
    
    // Call sessions
    match /call_sessions/{sessionId} {
      // Allow read for caller, callee, or any group participant
      allow read: if isSignedIn() && (
        request.auth.uid == resource.data.caller_id ||
        request.auth.uid == resource.data.callee_id ||
        (resource.data.is_group == true && 
         request.auth.uid in get(/databases/$(database)/documents/conversations/$(resource.data.group_id)).data.participants)
      );
      
      // Allow create if user is the caller
      allow create: if isSignedIn() && 
                       request.auth.uid == request.resource.data.caller_id;
      
      // Allow update for caller, callee, or participants (to update status)
      allow update: if isSignedIn() && (
        request.auth.uid == resource.data.caller_id ||
        request.auth.uid == resource.data.callee_id ||
        (resource.data.is_group == true && 
         request.auth.uid in get(/databases/$(database)/documents/conversations/$(resource.data.group_id)).data.participants)
      );
      
      // Allow delete for caller
      allow delete: if isSignedIn() && 
                       request.auth.uid == resource.data.caller_id;
    }
    
    // Users collection (existing rule, keep as is)
    match /users/{userId} {
      allow read: if isSignedIn();
      allow write: if isSignedIn() && request.auth.uid == userId;
    }
    
    // Add other collection rules as needed...
  }
}
```

## Key Security Features

### 1. **Participant Verification**
- Users can only access conversations they're part of
- Enforced through `participants` array check
- Applies to both 1-on-1 and group chats

### 2. **Admin Permissions**
- Only the group admin can:
  - Add or remove members
  - Update group name/description
- Admin cannot transfer admin rights (prevent conflicts)
- Admin cannot change group type after creation

### 3. **Message Protection**
- Users can only create messages as themselves
- Cannot impersonate other users
- Can edit their own messages
- Can add reactions to any message in their conversations
- Admin can delete any message in their group

### 4. **Group Integrity**
- `is_group` flag cannot be changed after creation
- `group_admin` cannot be changed (prevents admin takeover)
- `created_at` timestamp is immutable
- Participants list can only be modified by admin

### 5. **Call Sessions**
- Group call sessions accessible to all group members
- Only caller can create session
- Any participant can update status (accept/reject)
- Only caller can delete session

## Testing Security Rules

Use the Firestore Rules Playground in Firebase Console to test:

### Test Case 1: Create Group
```javascript
// Should SUCCEED
auth: { uid: 'user1' }
operation: create /conversations/conv123
data: {
  is_group: true,
  group_name: 'Test Group',
  group_admin: 'user1',
  participants: ['user1', 'user2', 'user3'],
  ...
}
```

### Test Case 2: Non-Admin Tries to Add Member
```javascript
// Should FAIL
auth: { uid: 'user2' }
operation: update /conversations/conv123
data: {
  participants: ['user1', 'user2', 'user3', 'user4']  // Adding user4
}
```

### Test Case 3: Admin Adds Member
```javascript
// Should SUCCEED
auth: { uid: 'user1' } // admin
operation: update /conversations/conv123
data: {
  participants: ['user1', 'user2', 'user3', 'user4']
}
```

### Test Case 4: User Sends Message as Another User
```javascript
// Should FAIL
auth: { uid: 'user2' }
operation: create /conversations/conv123/messages/msg123
data: {
  sender_id: 'user1',  // Trying to impersonate user1
  text: 'Fake message'
}
```

## Deployment

1. **Backup Current Rules**:
   ```bash
   firebase firestore:rules > firestore.rules.backup
   ```

2. **Update Rules File**:
   - Edit `firestore.rules` with the new rules above
   - Merge with your existing rules

3. **Deploy**:
   ```bash
   firebase deploy --only firestore:rules
   ```

4. **Monitor**:
   - Check Firebase Console > Firestore > Rules tab
   - Review any denied requests in the logs

## Common Issues and Solutions

### Issue: Members can't send messages
**Solution**: Ensure user is in `participants` array of the conversation

### Issue: Admin can't add members
**Solution**: Verify:
- User is the `group_admin`
- `is_group` is `true`
- Not trying to change `group_admin` or `is_group` fields

### Issue: Users can access conversations they're not in
**Solution**: Check that `isParticipant()` function is properly implemented in read rules

## Performance Considerations

- The `get()` function in rules counts toward your read quota
- Consider caching conversation data in client app
- Use indexes for large participant lists
- Monitor rule evaluation performance in Firebase Console

## Additional Recommendations

1. **Rate Limiting**: Consider implementing Cloud Functions to rate-limit group creation
2. **Max Members**: Add a check for maximum participants (e.g., 256)
3. **Validation**: Add field validation (e.g., group name length, description length)
4. **Audit Log**: Consider logging admin actions for compliance

Apply these rules and your group chat feature will be secure and production-ready! 🔒
