# Flutter Social Media App

A comprehensive social media application built with Flutter, Firebase, and Supabase.

## 🌐 Live Demo

**Primary (Firebase Hosting):** [https://myapp-6cbbf.web.app](https://myapp-6cbbf.web.app)

**Alternative (GitHub Pages):** [https://safiullah-foragy.github.io/flutter_app/](https://safiullah-foragy.github.io/flutter_app/)

## ✨ Features

- **User Authentication** - Secure signup/login with Firebase Auth
- **Profile Management** - Comprehensive profiles with education, work experience, and personal information
- **Social Newsfeed** - Post text, images, and videos with reactions (like, love, sad, angry)
- **Real-time Messaging** - Chat with other users with Firebase Cloud Messaging
- **Video/Audio Calls** - Integrated Agora for voice and video calling
- **Job Search** - Browse and search for job opportunities
- **AI Chatbot** - Intelligent chatbot integration
- **Notifications** - Push notifications for messages, posts, and interactions
- **Offline Support** - Works offline with local data caching
- **Responsive Design** - Phone-sized UI on web/desktop for optimal mobile experience

## 🛠️ Tech Stack

- **Frontend:** Flutter (Web, Android, iOS, Windows)
- **Backend:** Firebase (Auth, Firestore, Cloud Messaging, Storage)
- **Media Storage:** Supabase
- **Video/Audio Calls:** Agora RTC
- **State Management:** Provider pattern
- **Notifications:** Firebase Cloud Messaging + Flutter Local Notifications

## 📱 Platform Support

- ✅ Android
- ✅ iOS
- ✅ Web
- ✅ Windows
- ✅ macOS
- ✅ Linux

## 🚀 Getting Started

### Prerequisites

- Flutter SDK (latest stable version)
- Firebase account and project setup
- Supabase account
- Agora account (for video/audio calls)

### Installation

1. Clone the repository:
```bash
git clone https://github.com/safiullah-foragy/flutter_app.git
cd flutter_app/myapp
```

2. Install dependencies:
```bash
flutter pub get
```

3. Configure Firebase:
   - Add your `google-services.json` (Android)
   - Add your `GoogleService-Info.plist` (iOS)
   - Update `firebase_options.dart`

4. Configure Supabase:
   - Update Supabase credentials in `lib/supabase.dart`

5. Run the app:
```bash
flutter run
```

## 📂 Project Structure

```
flutter_app/
├── myapp/          # Main Flutter application
├── job_api/        # Job search API service
└── Chat_Bot/       # AI chatbot service
```

## 🔧 Configuration

Key configuration files:
- `lib/firebase_options.dart` - Firebase configuration
- `lib/supabase.dart` - Supabase configuration
- `lib/agora_config.dart` - Agora credentials

## 📄 License

This project is licensed under the MIT License.

## 👨‍💻 Author

**Safiullah Foragy**
- GitHub: [@safiullah-foragy](https://github.com/safiullah-foragy)

## 🤝 Contributing

Contributions, issues, and feature requests are welcome!

---

**🚀 Try it now:**
- **Firebase Hosting:** [https://myapp-6cbbf.web.app](https://myapp-6cbbf.web.app) ⭐ **Recommended**
- **GitHub Pages:** [https://safiullah-foragy.github.io/flutter_app/](https://safiullah-foragy.github.io/flutter_app/)
