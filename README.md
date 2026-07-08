# JARVIS Assistant

Cross-platform Flutter personal assistant for iOS, Android, Web, Windows, macOS, and Linux.

## Features

- Jarvis-inspired dark cyan interface
- OpenAI, Gemini, and Anthropic API key selection
- Provider-specific model selection
- Secure on-device API key storage
- Local-only chat history with no cloud synchronization
- Ollama model discovery, pulling, and offline chat
- TTS enable/disable toggle
- About section for Mohan / mohanybm829@gmail.com

## Run

1. Install Flutter and create platform folders if needed:

   flutter create .

2. Install dependencies:

   flutter pub get

3. Run:

   flutter run

## Ollama

Install and start Ollama separately. The default endpoint is `http://localhost:11434`.

For Android emulators, use `http://10.0.2.2:11434` instead of localhost.

For physical mobile devices, use the desktop machine's LAN IP and ensure the Ollama server is reachable on the local network.

Web builds can encounter browser CORS restrictions when calling cloud APIs or Ollama directly. For production web deployment, use a user-controlled local gateway or provider-supported browser-safe flow. Do not embed API keys in compiled source code.

## Security and privacy

Conversation history is persisted only on the current device. API keys use platform secure storage where supported. The app contains no cloud sync implementation.
