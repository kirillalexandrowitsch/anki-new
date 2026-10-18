import AppKit
import SwiftUI
import Testing
@testable import CardsDesignSystem

struct DesignSystemTests {
    /// Resolve actual semantic colors, not a separate table of expected hex values.
    @MainActor @Test func textAndActionContrastInBothAppearances() {
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let backgrounds: [CardsColor] = [.window, .surface, .secondarySurface]
            for background in backgrounds {
                for foreground in [CardsColor.text, .secondaryText] {
                    let ratio = contrast(foreground.color, background.color, environment)
                    #expect(ratio >= 4.5, "\(scheme) \(foreground)/\(background): \(ratio)")
                }
            }
            #expect(contrast(.white, CardsColor.accentFill.color, environment) >= 4.5)
            for foreground in [CardsColor.danger, .success, .warning, .accent] {
                #expect(contrast(foreground.color, CardsColor.surface.color, environment) >= 4.5)
            }
            #expect(contrast(CardsColor.text.color, CardsColor.window.color, environment) > 10)
        }
    }

    /// Stable primitives only: no native text fields, spinners, or full-window pixel
    /// baselines. Theme/OS font rendering can change; states must still differ.
    @MainActor @Test func buttonStatesRenderDistinctShapes() throws {
        for scheme in [ColorScheme.light, .dark] {
            for kind in CardsButtonKind.allCases {
                var renders: [Data] = []
                for state in ButtonPreviewState.allCases {
                    let sample = Button("Action") {}
                        .buttonStyle(CardsButtonStyle(kind, preview: state))
                        .disabled(state == .disabled)
                        .padding(16).frame(width: 220, height: 90)
                        .background(CardsColor.window.color)
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: sample)
                    renderer.scale = 1
                    let cgImage = try #require(renderer.cgImage)
                    #expect(cgImage.width == 220 && cgImage.height == 90)
                    let image = NSBitmapImageRep(cgImage: cgImage)
                    let data = try #require(image.representation(using: .png, properties: [:]))
                    #expect(!renders.contains(data), "Duplicate state \(kind)/\(state)/\(scheme)")
                    renders.append(data)
                    try save(data, name: "\(scheme)-\(kind.rawValue)-\(state.rawValue).png")
                }
            }
        }
    }

    /// Optional local review images use the same views as Xcode previews.
    /// Native controls use AppKit hosting and are never claimed as ImageRenderer output.
    @MainActor @Test func renderStaticGalleryForLocalReview() throws {
        guard ProcessInfo.processInfo.environment["CARDS_DESIGN_SNAPSHOTS"] != nil else { return }
        for scheme in [ColorScheme.light, .dark] {
            for scale in CardsTextScale.allCases {
                for page in CardsGalleryPage.allCases {
                    let content = CardsGalleryContent(page: page)
                        .padding(32).frame(width: scale == .standard ? 1120 : 800)
                        .background(CardsColor.window.color)
                        .environment(\.colorScheme, scheme)
                        .environment(\.cardsTextScale, scale)
                    let data: Data
                    if page == .fields || page == .messages {
                        // Cache an AppKit-backed hosting view for native controls;
                        // ImageRenderer intentionally omits TextField/Toggle/spinner.
                        _ = NSApplication.shared
                        let hosting = NSHostingView(rootView: content)
                        let size = hosting.fittingSize
                        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                              styleMask: .borderless, backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        window.contentView = hosting
                        hosting.frame = NSRect(origin: .zero, size: size)
                        hosting.layoutSubtreeIfNeeded()
                        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                        data = try #require(bitmap.representation(using: .png, properties: [:]))
                        window.close()
                    } else {
                        let renderer = ImageRenderer(content: content)
                        renderer.scale = 1
                        let image = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                        data = try #require(image.representation(using: .png, properties: [:]))
                    }
                    try save(data, name: "gallery-\(page.rawValue)-\(scheme)-\(scale).png")
                }
            }
        }
    }

    @MainActor private func save(_ data: Data, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["CARDS_DESIGN_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name))
    }

    @MainActor private func contrast(_ first: Color, _ second: Color, _ environment: EnvironmentValues) -> Double {
        func luminance(_ color: Color) -> Double {
            let value = color.resolve(in: environment)
            func linear(_ component: Float) -> Double {
                let c = Double(component)
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(value.red) + 0.7152 * linear(value.green) + 0.0722 * linear(value.blue)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
