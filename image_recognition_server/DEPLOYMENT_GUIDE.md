# Complete Deployment Guide for Image Recognition Server

## Overview
This guide will walk you through deploying your image recognition server to Render.com and connecting it to your Flutter app.

## What You're Deploying
- **Model**: ResNet50 pre-trained on ImageNet
- **Training Data**: 1.2 million images across 1000 object categories
- **Technology**: Python Flask server with PyTorch
- **Hosting**: Render.com (free tier available)

## Step-by-Step Deployment

### Step 1: Prepare Your Code
All files are already created in the `image_recognition_server` folder:
- `app.py` - Flask server with ResNet50 model
- `requirements.txt` - Python dependencies
- `Procfile` - Render deployment config
- `imagenet_classes.json` - 1000 object class labels
- `.gitignore` - Excludes Python cache files

### Step 2: Push to GitHub
```bash
cd d:/flutter_app
git add .
git commit -m "Add image recognition server"
git push origin main
```

### Step 3: Deploy to Render.com

1. **Create Render Account**
   - Go to https://render.com
   - Sign up with GitHub (recommended for easy deployment)

2. **Create New Web Service**
   - Click "New +" button in top right
   - Select "Web Service"
   - Choose "Build and deploy from a Git repository"
   - Click "Next"

3. **Connect Repository**
   - Select your `flutter_app` repository
   - Click "Connect"

4. **Configure Service**
   Fill in these settings:
   
   - **Name**: `image-recognition-api` (or any name you prefer)
   - **Region**: Choose closest to your users
   - **Branch**: `main`
   - **Root Directory**: `image_recognition_server`
   - **Runtime**: `Python 3`
   - **Build Command**: `pip install -r requirements.txt`
   - **Start Command**: `gunicorn app:app`
   
   - **Instance Type**: 
     - Free tier: Works but has cold starts (30-60s delay on first request after inactivity)
     - Starter ($7/mo): Recommended - always warm, faster responses

5. **Advanced Settings** (Optional)
   - Click "Advanced"
   - Set environment variables if needed (none required for basic setup)
   - Set health check path: `/health`

6. **Create Web Service**
   - Click "Create Web Service"
   - Wait for deployment (5-10 minutes for first deploy)
   - Model weights (~100MB) download automatically

### Step 4: Get Your Server URL
Once deployed, Render will show your service URL:
```
https://your-app-name.onrender.com
```

Copy this URL - you'll need it in the next step!

### Step 5: Update Flutter App

Open `d:\flutter_app\myapp\lib\image_recognition_chatbot_page.dart` and update line 23:

**Before:**
```dart
static const String serverUrl = 'https://your-app-name.onrender.com/predict';
```

**After:**
```dart
static const String serverUrl = 'https://YOUR-ACTUAL-URL.onrender.com/predict';
```

Replace `YOUR-ACTUAL-URL` with your actual Render service name.

### Step 6: Test Your Deployment

1. **Test Server Health**
   - Visit: `https://your-app-name.onrender.com/health`
   - Should see: `{"status": "healthy", "model": "ResNet50-ImageNet"}`

2. **Test in Flutter App**
   - Run your Flutter app
   - Navigate to newsfeed
   - Click the robot icon (top right)
   - Upload an image
   - Wait for results (first request may take 30-60s on free tier)

## Troubleshooting

### Issue: Server shows "Service Unavailable"
**Solution**: Wait 2-3 minutes after deployment. Server is still starting up.

### Issue: First request takes 30-60 seconds
**Solution**: This is normal on free tier (cold start). Upgrade to Starter plan for instant responses.

### Issue: "Failed to analyze image" error in app
**Solutions**:
1. Check server URL in `image_recognition_chatbot_page.dart` is correct
2. Visit `/health` endpoint to verify server is running
3. Check Render logs for errors (Dashboard → Your Service → Logs)

### Issue: Server crashes or runs out of memory
**Solution**: Upgrade to Starter plan. Free tier has limited RAM (~512MB). Model needs ~1GB.

### Issue: Can't connect from Flutter web
**Solution**: CORS is enabled. Check browser console for errors. May need to wait for cold start.

## Model Performance

### Supported Objects (1000 categories including):
- Animals: dogs, cats, birds, insects, marine life
- Vehicles: cars, trucks, bikes, planes, boats
- Food: fruits, vegetables, dishes, beverages
- Objects: furniture, electronics, tools, sports equipment
- Nature: trees, flowers, landscapes

### Accuracy:
- Top-1 Accuracy: ~76% (first prediction is correct)
- Top-5 Accuracy: ~93% (correct answer in top 5 predictions)

### Limitations:
- Works best with single clear objects
- May struggle with multiple objects or abstract scenes
- Trained on ImageNet - best for common objects

## Cost Breakdown

### Free Tier (Render)
- **Cost**: $0/month
- **Pros**: No cost, good for testing
- **Cons**: 
  - Spins down after 15 min inactivity
  - Cold start adds 30-60s delay
  - Limited to 750 hours/month
  - Slower performance

### Starter Tier (Render)
- **Cost**: $7/month
- **Pros**:
  - Always running (no cold starts)
  - Faster response times
  - More RAM for better performance
  - Better for production use
- **Cons**: Monthly cost

## Monitoring

### View Logs
1. Go to Render dashboard
2. Click your service
3. Click "Logs" tab
4. See real-time server activity

### View Metrics
1. Go to Render dashboard
2. Click your service
3. Click "Metrics" tab
4. See CPU, memory, request stats

## Updating the Server

To update server code:
```bash
cd d:/flutter_app
# Make changes to image_recognition_server/app.py
git add .
git commit -m "Update server"
git push origin main
```

Render auto-deploys on git push (if enabled in settings).

## Alternative: Local Development

For testing without deploying:
```bash
cd d:/flutter_app/image_recognition_server
pip install -r requirements.txt
python app.py
```

Server runs at `http://localhost:5000`

Update Flutter app to use: `http://10.0.2.2:5000/predict` (Android emulator) or `http://localhost:5000/predict` (web/iOS simulator)

## Security Notes

- Server accepts any image upload
- No authentication required (add if needed)
- Rate limiting not implemented (consider for production)
- CORS enabled for all origins (restrict if needed)

## Next Steps

1. Deploy server to Render ✓
2. Update Flutter app with server URL ✓
3. Test with various images ✓
4. Monitor performance and costs
5. Upgrade to Starter plan when ready for production
6. Consider adding authentication for production use

## Support

- Render Docs: https://render.com/docs
- PyTorch Docs: https://pytorch.org/docs
- ImageNet Classes: See `imagenet_classes.json` for full list

---

**Congratulations!** You now have a production-ready AI image recognition service! 🎉
