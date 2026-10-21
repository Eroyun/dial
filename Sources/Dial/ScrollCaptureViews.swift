import AppKit
import SwiftUI

/// Brief confirmation for the automatic copy action. The owner controls its
/// nonactivating presentation and dismissal lifecycle.
struct ScrollCaptureCopyFeedback: View {
    static let preferredSize = NSSize(width: 320, height: 68)

    let detail: String?
    let onShow: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Screenshot copied")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Show", action: onShow)
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .accessibilityHint("Open the saved screenshot")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss screenshot copied message")
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The capture panel deliberately has no focus-dependent shortcuts: it stays
/// nonactivating so interacting with it cannot steal the browser's scroll target.
struct ScrollCaptureControls: View {
    static let preferredSize = NSSize(width: 440, height: 108)
    let model: ScrollScreenshot

    private var title: String {
        switch model.capturePhase {
        case "finishing": "Preparing your screenshot"
        case "scrolling": "Capturing the page"
        default: "Getting ready"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Capture in progress")
                Text(model.automatic ? title : "Capturing your selection")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                if !model.capturedSize.isEmpty {
                    Text(model.capturedSize).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Text(model.message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).help(model.message).accessibilityLabel(model.message)
                Spacer(minLength: 0)
                Button { model.cancel() } label: {
                    Image(systemName: "xmark").frame(width: 20, height: 20)
                }
                .accessibilityLabel("Cancel capture").help("Cancel and discard this capture")
                Button(model.automatic ? "Stop & keep" : "Done") { model.finish() }
                    .buttonStyle(.borderedProminent).disabled(!model.canFinish)
                    .help("Keep the page captured so far")
            }
            .controlSize(.regular)
        }
        .padding(14)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

}

struct ScrollCapturePermission: View {
    static let preferredSize = NSSize(width: 480, height: 252)
    let model: ScrollScreenshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Allow screen capture", systemImage: "rectangle.dashed.badge.record")
                .font(.system(size: 20, weight: .semibold))
            Text("Give Dial access in Screen Recording settings to capture a page or document automatically.")
                .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            Text("If macOS asks you to reopen Dial, reopen it before trying again.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button("Open Settings") { model.requestPermission() }
                Spacer()
                Button("Try Again") { model.retryAfterPermission() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
    }
}

struct ScrollCapturePreview: View {
    static let preferredSize = NSSize(width: 940, height: 760)
    static let minimumSize = NSSize(width: 560, height: 420)
    let model: ScrollScreenshot
    init(model: ScrollScreenshot) { self.model = model }
    // Explicit DynamicProperty storage avoids the SDK's newer @State macro,
    // whose plugin is absent from the standalone Command Line Tools toolchain.
    private var zoomState = SwiftUI.State<CapturePreviewZoom>(initialValue: .fitWidth)
    private var detailsState = SwiftUI.State<Bool>(initialValue: false)
    private var editingState = SwiftUI.State<Bool>(initialValue: false)
    private var toolState = SwiftUI.State<CaptureImageTool>(initialValue: .crop)
    private var cropState = SwiftUI.State<CGRect?>(initialValue: nil)
    private var annotationsState = SwiftUI.State<[CaptureImageAnnotation]>(initialValue: [])
    private var textState = SwiftUI.State<String>(initialValue: "")
    private var zoom: CapturePreviewZoom { zoomState.wrappedValue }
    private var editing: Bool { editingState.wrappedValue }

    /// Outcome remains visible after Copy or Save changes the model's message.
    private var caution: String? {
        switch model.captureOutcome {
        case "stopped_early": "Stopped early. This image contains the page captured so far."
        case "end_inferred": "The page appeared to stop scrolling. Check the image: the full page could not be confirmed."
        case "end_unverified": "The end of the page could not be confirmed. Check the image before using it."
        case "partial": "Capture is incomplete. This image contains only the content captured successfully."
        default: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if editing {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Page screenshot")
                            .font(.system(size: 20, weight: .semibold))
                        Spacer()
                        if let crop = cropState.wrappedValue {
                            Text("\(Int(crop.width)) × \(Int(crop.height)) px")
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    editorToolbar
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Page screenshot")
                            .font(.system(size: 20, weight: .semibold))
                        if model.result != nil {
                            Text(model.capturedSize).font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.result != nil {
                        Button("Crop") { beginEditing(with: .crop) }
                            .buttonStyle(.bordered)
                        Button("Markup") { beginEditing(with: .arrow) }
                            .buttonStyle(.bordered)
                        Picker("Zoom", selection: zoomState.projectedValue) {
                            ForEach(CapturePreviewZoom.allCases) { level in
                                Text(level.label).tag(level)
                            }
                        }
                        .pickerStyle(.menu).fixedSize().help("Choose how large the screenshot appears")
                        .accessibilityLabel("Screenshot zoom")
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 18)
            }

            if let image = model.result {
                if let caution {
                    HStack(alignment: .top, spacing: 12) {
                        Label(caution, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Details") { detailsState.wrappedValue.toggle() }
                            .buttonStyle(.borderless)
                            .popover(isPresented: detailsState.projectedValue) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Capture details").font(.headline)
                                    Text(model.captureDetails).font(.system(size: 13))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }.padding(18).frame(width: 320, alignment: .leading)
                            }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(Color.orange.opacity(0.10))
                }
                Divider()
                imageCanvas(image)
                Divider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        if model.copied {
                            Label("Copied", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("PNG").foregroundStyle(.secondary)
                        }
                        if model.message.hasPrefix("Saved ") || model.message.hasPrefix("Could not save") {
                            Text(model.message).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.system(size: 12))
                    Spacer(minLength: 8)
                    Button("Copy") { model.copyImage() }.keyboardShortcut("c", modifiers: .command)
                        .disabled(editing || model.isEditingImage)
                    Button("Save…") { model.save() }.buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(editing || model.isEditingImage)
                }
                .controlSize(.large)
                .padding(.horizontal, 24).padding(.vertical, 16)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.imageRevision) { _, _ in resetEditor() }
    }

    private func imageCanvas(_ image: NSImage) -> some View {
        GeometryReader { geometry in
            let pixels = imagePixelSize(image)
            let sourceWidth = max(1, pixels.width)
            let availableWidth = max(1, geometry.size.width - 40)
            let scale = zoom == .fitWidth ? min(1, availableWidth / sourceWidth) : zoom.scale
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if editing {
                        CaptureImageEditor(image: image, pixelSize: pixels,
                                           tool: toolState.wrappedValue, crop: cropState.wrappedValue,
                                           annotations: annotationsState.wrappedValue, text: textState.wrappedValue,
                                           onCrop: { cropState.wrappedValue = $0 },
                                           onAnnotation: { annotationsState.wrappedValue.append($0) })
                            .accessibilityLabel("Screenshot editor")
                    } else {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .background(Color.white)
                            .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
                            .accessibilityLabel("Captured page")
                    }
                }
                .frame(width: sourceWidth * scale, height: max(1, pixels.height) * scale)
                .padding(20)
                .frame(minWidth: geometry.size.width, alignment: .top)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private func imagePixelSize(_ image: NSImage) -> CGSize {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return image.size
    }

    private var editorToolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                toolButton("Crop", tool: .crop)
                toolButton("Arrow", tool: .arrow)
                toolButton("Box", tool: .box)
                toolButton("Text", tool: .text)
                if toolState.wrappedValue == .text {
                    TextField("Text (500 max)", text: Binding(
                        get: { textState.wrappedValue },
                        set: { textState.wrappedValue = String($0.prefix(500)) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Annotation text, up to 500 characters")
                    .help("Annotation text is limited to 500 characters")
                }
                Spacer(minLength: 4)
            }
            HStack(spacing: 8) {
                if model.message.hasPrefix("Could not apply edits") {
                    Text("Could not apply edits")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(model.message)
                        .accessibilityLabel(model.message)
                }
                Spacer(minLength: 4)
                Button("Undo") { undoLastEdit() }
                    .disabled(cropState.wrappedValue == nil && annotationsState.wrappedValue.isEmpty)
                    .help("Undo the last crop or annotation")
                Button("Cancel", action: cancelEditing)
                Button("Apply", action: applyEditing)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isEditingImage || (cropState.wrappedValue == nil && annotationsState.wrappedValue.isEmpty))
            }
        }
        .controlSize(.small)
    }

    private func toolButton(_ title: String, tool: CaptureImageTool) -> some View {
        let selected = toolState.wrappedValue == tool
        return Button { toolState.wrappedValue = tool } label: {
            Text(title).padding(.horizontal, 7).padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel("\(title) tool")
        .accessibilityValue(selected ? "Selected" : "")
    }

    private func beginEditing(with tool: CaptureImageTool) {
        toolState.wrappedValue = tool
        cropState.wrappedValue = nil
        annotationsState.wrappedValue = []
        textState.wrappedValue = ""
        editingState.wrappedValue = true
    }

    private func cancelEditing() {
        model.cancelImageEdit()
        resetEditor()
    }

    private func applyEditing() {
        guard !model.isEditingImage,
              cropState.wrappedValue != nil || !annotationsState.wrappedValue.isEmpty else { return }
        model.applyEdits(crop: cropState.wrappedValue, annotations: annotationsState.wrappedValue)
    }

    private func undoLastEdit() {
        if !annotationsState.wrappedValue.isEmpty {
            annotationsState.wrappedValue.removeLast()
        } else {
            cropState.wrappedValue = nil
        }
    }

    private func resetEditor() {
        editingState.wrappedValue = false
        cropState.wrappedValue = nil
        annotationsState.wrappedValue = []
        textState.wrappedValue = ""
        toolState.wrappedValue = .crop
    }


}

private enum CapturePreviewZoom: String, CaseIterable, Identifiable {
    case fitWidth, actualSize, doubleSize
    var id: Self { self }
    var label: String {
        switch self {
        case .fitWidth: "Fit width"
        case .actualSize: "100%"
        case .doubleSize: "200%"
        }
    }
    var scale: CGFloat { self == .doubleSize ? 2 : 1 }
}
