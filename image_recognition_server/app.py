from flask import Flask, request, jsonify
from flask_cors import CORS
from PIL import Image
import io
import json
from transformers import pipeline
import warnings
warnings.filterwarnings('ignore')

app = Flask(__name__)
CORS(app)  # Enable CORS for Flutter web

# Use Hugging Face transformers with a lightweight model
# This works with any Python version and downloads automatically
print("Loading image classification model...")
classifier = pipeline("image-classification", model="google/vit-base-patch16-224")
print("Model loaded successfully!")

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint for Render"""
    return jsonify({'status': 'healthy', 'model': 'ViT-Base-224'}), 200

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
        
        # Get predictions
        results = classifier(img, top_k=5)
        
        predictions = []
        for result in results:
            # Only include predictions with >5% confidence
            if result['score'] > 0.05:
                predictions.append({
                    'class': result['label'],
                    'confidence': float(result['score'])
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
