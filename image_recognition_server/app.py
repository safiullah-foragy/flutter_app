from flask import Flask, request, jsonify
from flask_cors import CORS
from PIL import Image
import io
import json

app = Flask(__name__)
CORS(app)  # Enable CORS for Flutter web

# Use a lightweight pre-trained model from torchvision (mobilenet)
# Much smaller memory footprint than transformers
print("Loading MobileNetV2 model...")
import torch
import torchvision.models as models
from torchvision import transforms

# Use MobileNetV2 - lightweight and efficient
model = models.mobilenet_v2(pretrained=True)
model.eval()

# Load ImageNet class labels
with open('imagenet_classes.json', 'r') as f:
    class_labels = json.load(f)

# Image preprocessing
preprocess = transforms.Compose([
    transforms.Resize(256),
    transforms.CenterCrop(224),
    transforms.ToTensor(),
    transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
])

print("Model loaded successfully!")

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint for Render"""
    return jsonify({'status': 'healthy', 'model': 'MobileNetV2-ImageNet'}), 200

@app.route('/predict', methods=['POST'])
def predict():
    """Predict objects in uploaded image"""
    try:
        # Check if image file is present
        if 'image' not in request.files:
            return jsonify({'error': 'No image file provided'}), 400
        
        file = request.files['image']
        
        # Read and process image
        img_bytes = file.read()
        img = Image.open(io.BytesIO(img_bytes)).convert('RGB')
        
        # Preprocess and predict
        img_tensor = preprocess(img).unsqueeze(0)
        
        with torch.no_grad():
            outputs = model(img_tensor)
            probabilities = torch.nn.functional.softmax(outputs[0], dim=0)
        
        # Get top 5 predictions
        top5_prob, top5_idx = torch.topk(probabilities, 5)
        
        predictions = []
        for i in range(5):
            class_idx = top5_idx[i].item()
            confidence = top5_prob[i].item()
            
            # Only include predictions with >5% confidence
            if confidence > 0.05:
                predictions.append({
                    'class': class_labels[class_idx],
                    'confidence': float(confidence)
                })
        
        return jsonify({
            'success': True,
            'predictions': predictions
        }), 200
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    # Render will set PORT environment variable
    import os
    port = int(os.environ.get('PORT', 5000))
    app.run(host='0.0.0.0', port=port)
