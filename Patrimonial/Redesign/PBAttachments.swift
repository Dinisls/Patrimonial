// ───────────────────────────────────────────────────────────
// PBAttachments.swift — Image attachments for transactions
// ───────────────────────────────────────────────────────────
import SwiftUI
import PhotosUI

// MARK: - File I/O

enum AttachmentStore {
    private static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        let name = UUID().uuidString + ".jpg"
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func load(_ fileName: String) -> UIImage? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func delete(_ fileName: String) {
        let url = directory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    static func encode(_ fileNames: [String]) -> String? {
        fileNames.isEmpty ? nil : (try? JSONEncoder().encode(fileNames)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return names
    }
}

// MARK: - Picker view

struct AttachmentsSectionView: View {
    @Binding var fileNames: [String]
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var fullScreenImage: String? = nil

    var body: some View {
        Section("Anexos") {
            if !fileNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(fileNames, id: \.self) { name in
                            attachmentThumb(name)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }

            HStack(spacing: 16) {
                PhotosPicker(selection: $photoSelection, maxSelectionCount: 5, matching: .images) {
                    Label("Galeria", systemImage: "photo.on.rectangle")
                        .font(.system(size: 15, weight: .medium))
                }

                Button { showCamera = true } label: {
                    Label("Câmara", systemImage: "camera")
                        .font(.system(size: 15, weight: .medium))
                }
            }
        }
        .onChange(of: photoSelection) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data),
                       let name = AttachmentStore.save(img) {
                        fileNames.append(name)
                    }
                }
                photoSelection = []
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { image in
                if let name = AttachmentStore.save(image) {
                    fileNames.append(name)
                }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $fullScreenImage) { name in
            AttachmentFullScreen(fileName: name)
        }
    }

    private func attachmentThumb(_ name: String) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = AttachmentStore.load(name) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Color(UIColor.systemFill))
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { fullScreenImage = name }

            Button {
                AttachmentStore.delete(name)
                fileNames.removeAll { $0 == name }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
        }
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

// MARK: - Full-screen viewer

struct AttachmentFullScreen: View {
    let fileName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let img = AttachmentStore.load(fileName) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    ContentUnavailableView("Imagem indisponível", systemImage: "photo")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

// MARK: - Camera

struct CameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        init(onCapture: @escaping (UIImage) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { onCapture(img) }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
