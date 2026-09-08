import SwiftUI
import CodeEditSourceEditor

struct GitEditorDiffRequest: Identifiable {
    let id = UUID()
    let repository: GitRepositoryIdentity
    let target: GitDiffTarget
    let file: GitDiffFile?
}

struct GitEditorDiffView: View {
    let request: GitEditorDiffRequest
    let theme: EditorTheme
    var isActive = true
    let close: () -> Void
    @State private var files: [GitDiffFile] = []
    @State private var selected: GitDiffFile?
    @State private var document: GitDiffDocument?
    @State private var before = ""
    @State private var after = ""
    @State private var lineMap = GitDiffLineMap("")
    @State private var error: String?
    @State private var sourceError: String?
    @State private var loading = true
    @State private var mode = "Source"
    private let service = GitDiffService()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(request.target.description).font(.caption).lineLimit(1)
                Spacer()
                Picker("View", selection: $mode) {
                    Text("Diff").tag("Diff")
                    Text("Source comparison").tag("Source")
                }.pickerStyle(.menu).fixedSize()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }.padding(8)
            if !files.isEmpty {
                Picker("File", selection: $selected) {
                    ForEach(files) { file in
                        Text(file.displayPath).tag(Optional(file))
                    }
                }.padding(.horizontal, 8)
            }
            Divider()
            if loading { ProgressView().padding() }
            if let error { Text(error).foregroundStyle(.red).padding() }
            if let document, !loading {
                if document.isBinary || document.isTruncated {
                    Text(document.summary ?? document.text).padding()
                } else if mode == "Source" {
                    if let sourceError {
                        Text(sourceError).foregroundStyle(.secondary).padding()
                    } else {
                        HSplitView {
                            sourcePane("Before", text: before, path: document.file.oldPath ?? document.file.path)
                            sourcePane("After", text: after, path: document.file.path)
                        }
                    }
                } else {
                    GitDiffTextView(text: document.text)
                }
            } else if !loading && error == nil {
                Text("No changed files").foregroundStyle(.secondary).padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            do {
                let list = try await service.listFiles(for: request.repository, target: request.target)
                try Task.checkCancellation()
                files = list.files
                selected = request.file.flatMap { requested in files.first { $0.id == requested.id } } ?? files.first
                loading = false
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription; loading = false }
        }
        .task(id: selected) {
            guard let selected else { return }
            document = nil
            error = nil
            sourceError = nil
            loading = true
            do {
                let diff = try await service.loadDiff(for: selected, repository: request.repository, target: request.target)
                try Task.checkCancellation()
                document = diff
                lineMap = GitDiffLineMap(diff.text)
                if !diff.isBinary && !diff.isTruncated {
                    do {
                        let versions = try await service.sourceVersions(for: selected, repository: request.repository,
                                                                        target: request.target)
                        try Task.checkCancellation()
                        before = versions.before
                        after = versions.after
                    } catch is CancellationError { return
                    } catch { sourceError = error.localizedDescription }
                }
                loading = false
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription; loading = false }
        }
    }

    private func sourcePane(_ title: String, text: String, path: String) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.caption).padding(6)
                .frame(maxWidth: .infinity)
                .background(title == "Before" ? Color.red.opacity(0.12) : Color.green.opacity(0.12))
            CodeEditorView(text: .constant(text), fileURL: URL(fileURLWithPath: path),
                           diffLines: title == "Before" ? lineMap.before : lineMap.after,
                           isEditable: false, isActive: isActive, terminalTheme: theme, onClose: close)
                .id("\(selected?.id ?? "")-\(title)")
        }.frame(minWidth: 120)
    }
}
