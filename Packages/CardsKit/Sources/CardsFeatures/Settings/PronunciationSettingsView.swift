import CardsCore
import CardsDesignSystem
import SwiftUI

struct PronunciationSettingsView: View {
    @Bindable var audio: AudioPreviewModel
    @Bindable var preferences: AudioPreferences
    @State private var voices: [SpeechVoice] = []

    var body: some View {
        Form {
            Picker("Вариант произношения", selection: $preferences.locale) {
                Text("UK · en-GB").tag("en-GB")
                Text("US · en-US").tag("en-US")
            }.pickerStyle(.segmented).accessibilityIdentifier("settings.audio.locale")
            Toggle("Автоматически воспроизводить при показе карточки", isOn: $preferences.autoplay)
                .accessibilityIdentifier("settings.audio.autoplay")
            Picker("Установленный голос", selection: $preferences.voiceID) {
                Text("Первый доступный").tag(nil as String?)
                ForEach(voices.filter { $0.locale == preferences.locale }) { voice in
                    Text(voice.name).tag(Optional(voice.id))
                }
                if let selected = preferences.voiceID, !voices.contains(where: { $0.id == selected && $0.locale == preferences.locale }) {
                    Text("Выбранный голос недоступен").tag(Optional(selected))
                }
            }.accessibilityIdentifier("settings.audio.voice")
            if !voices.contains(where: { $0.locale == preferences.locale }) {
                Text("Для этого варианта нет доступного голоса. Выберите другой вариант или установите системный голос в настройках macOS.")
                    .foregroundStyle(.secondary).accessibilityIdentifier("settings.audio.missingVoice")
            }
            HStack {
                Button("Проверить произношение · serendipity", systemImage: "speaker.wave.2.fill") {
                    Task { await audio.preview(text: "serendipity") }
                }.accessibilityIdentifier("settings.audio.preview")
                if audio.isPlaying { Button("Стоп") { audio.stop() }.accessibilityIdentifier("settings.audio.stop") }
                Button("Обновить голоса") { voices = audio.voices }
            }
            if let message = audio.message {
                Text(message).foregroundStyle(audio.hasError ? Color.red : Color.secondary)
                    .accessibilityIdentifier("settings.audio.message")
            }
        }
        .formStyle(.grouped)
        .onAppear { voices = audio.voices }
        .onDisappear { audio.stop() }
        .onChange(of: preferences.locale) { _, _ in audio.stop() }
        .onChange(of: preferences.voiceID) { _, _ in audio.stop() }
    }
}
