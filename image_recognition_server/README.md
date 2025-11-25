# Image Recognition Server

This is a Flask-based image recognition server that uses ResNet50 pre-trained on ImageNet (1.2 million images, 1000 classes).

## Features
- Pre-trained ResNet50 model (high accuracy object detection)
- Trained on ImageNet dataset with 1000+ object categories
- REST API for image upload and prediction
- Ready to deploy on Render.com

## Deploy to Render.com

1. Create a new account at https://render.com
2. Click "New +" and select "Web Service"
3. Connect your GitHub repository or upload these files
4. Configure the service:
   - **Name**: image-recognition-api (or your choice)
   - **Environment**: Python
   - **Build Command**: `pip install -r requirements.txt`
   - **Start Command**: `gunicorn app:app`
   - **Instance Type**: Free or Starter (Starter recommended for faster response)

5. Click "Create Web Service"
6. Wait for deployment (first deployment takes 5-10 minutes as it downloads the model)
7. Copy your service URL (e.g., https://your-app-name.onrender.com)
8. Update the `_serverUrl` in `chatbot_page.dart` with your URL

## API Endpoints

### Health Check
```
GET /health
Response: {"status": "healthy", "model": "ResNet50-ImageNet"}
```

### Predict Objects
```
POST /predict
Body: multipart/form-data with 'image' file
Response: {
  "success": true,
  "predictions": [
    {"class": "golden retriever", "confidence": 0.87},
    {"class": "Labrador retriever", "confidence": 0.09}
  ]
}
```

## Model Information
- **Architecture**: ResNet50
- **Training Dataset**: ImageNet (1.2M images)
- **Classes**: 1000 object categories
- **Accuracy**: ~76% top-1, ~93% top-5 on ImageNet validation

## Local Testing
```bash
pip install -r requirements.txt
python app.py
# Server runs on http://localhost:5000
```

## Notes
- Free tier on Render may have cold starts (30s-1min delay on first request)
- Upgrade to Starter plan ($7/mo) for always-on service
- Model weights are downloaded automatically on first run (~100MB)
