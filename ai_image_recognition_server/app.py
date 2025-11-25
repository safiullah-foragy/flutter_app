from flask import Flask, request, jsonify
from flask_cors import CORS
from PIL import Image
import io
import json
import numpy as np

app = Flask(__name__)
CORS(app)

print("Loading MobileNetV2 ONNX model...")
import onnxruntime as ort
import urllib.request
import os

MODEL_PATH = "mobilenetv2.onnx"
LABELS_PATH = "imagenet_classes.json"

# Download pre-trained ONNX model (trained on ImageNet - 1.2M images, 1000 classes)
if not os.path.exists(MODEL_PATH):
    print("Downloading MobileNetV2 ONNX model (~14MB, first time only)...")
    urllib.request.urlretrieve(
        "https://github.com/onnx/models/raw/main/validated/vision/classification/mobilenet/model/mobilenetv2-12.onnx",
        MODEL_PATH
    )
    print("Model downloaded!")

# Load ONNX model with CPU execution (memory efficient)
session = ort.InferenceSession(MODEL_PATH, providers=['CPUExecutionProvider'])
print("Model loaded successfully! Memory usage: ~150MB")

# Load ImageNet class labels (1000 categories)
with open(LABELS_PATH, 'r') as f:
    labels = json.load(f)

def preprocess_image(img):
    """Preprocess image for MobileNetV2 (ImageNet standards)"""
    # Resize to 256x256
    img = img.resize((256, 256), Image.BILINEAR)
    # Center crop to 224x224
    left = (256 - 224) // 2
    top = (256 - 224) // 2
    img = img.crop((left, top, left + 224, top + 224))
    
    # Convert to numpy array and normalize (ImageNet mean/std)
    img_array = np.array(img).astype(np.float32) / 255.0
    mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
    std = np.array([0.229, 0.224, 0.225], dtype=np.float32)
    img_array = (img_array - mean) / std
    
    # Transpose to CHW format (channels, height, width)
    img_array = np.transpose(img_array, (2, 0, 1))
    # Add batch dimension
    img_array = np.expand_dims(img_array, axis=0)
    
    return img_array

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint for Render"""
    return jsonify({
        'status': 'healthy',
        'model': 'MobileNetV2-ONNX',
        'training_data': 'ImageNet (1.2M images)',
        'classes': 1000,
        'memory': '~150MB'
    }), 200

@app.route('/predict', methods=['POST'])
def predict():
    """Predict objects in uploaded image"""
    try:
        if 'image' not in request.files:
            return jsonify({'error': 'No image file provided'}), 400
        
        file = request.files['image']
        img_bytes = file.read()
        img = Image.open(io.BytesIO(img_bytes)).convert('RGB')
        
        # Preprocess image
        input_data = preprocess_image(img)
        
        # Run inference
        input_name = session.get_inputs()[0].name
        output = session.run(None, {input_name: input_data})[0]
        
        # Apply softmax to get probabilities
        exp_output = np.exp(output - np.max(output))
        probabilities = exp_output / exp_output.sum()
        
        # Get top 5 predictions
        top5_idx = np.argsort(probabilities[0])[-5:][::-1]
        
        predictions = []
        for idx in top5_idx:
            confidence = float(probabilities[0][idx])
            if confidence > 0.01:  # Only include predictions with >1% confidence
                predictions.append({
                    'object': labels[idx],
                    'confidence': round(confidence * 100, 2)
                })
        
        return jsonify({
            'success': True,
            'predictions': predictions,
            'message': f'Found {len(predictions)} objects'
        }), 200
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    import os
    port = int(os.environ.get('PORT', 5000))
    app.run(host='0.0.0.0', port=port)
