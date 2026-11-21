import Foundation

struct FilesStrings: Equatable, Sendable {
    private let settings: SettingsStrings

    init(
        language: OhMyGhosttyLanguage = .system,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.settings = SettingsStrings(
            language: language,
            preferredLanguages: preferredLanguages
        )
    }

    @MainActor static var current: Self {
        .init(language: OhMyGhosttySettings.shared.language)
    }

    private func t(_ english: String, _ chinese: String) -> String {
        settings.isChinese ? chinese : english
    }

    var title: String { t("Files", "文件") }

    // Empty states
    var noWorkingDirectory: String {
        t("The terminal has not reported a working directory.", "终端尚未报告工作目录。")
    }
    var workingDirectoryUnavailable: String {
        t("The current working directory is unavailable.", "当前工作目录不可用。")
    }
    var loading: String { t("Loading…", "正在加载…") }

    // Toolbar
    var newFile: String { t("New File", "新建文件") }
    var newFolder: String { t("New Folder", "新建文件夹") }
    var locateCurrentFile: String { t("Locate Current File", "定位当前文件") }
    var collapseAll: String { t("Collapse All", "全部折叠") }
    var expandAll: String { t("Expand All", "全部展开") }

    // Context menu
    var copyPath: String { t("Copy Path", "复制路径") }
    var copyRelativePath: String { t("Copy Relative Path", "复制相对路径") }
    var rename: String { t("Rename…", "重命名…") }
    var openIn: String { t("Open in…", "打开方式…") }
    var openInEditor: String { t("Open in Editor", "在编辑器中打开") }
    var openToTheSide: String { t("Open to the Side", "在侧边打开") }
    func destinationTitle(_ destination: EditorOpenDestination) -> String {
        settings.editorOpenDestinationTitle(destination)
    }

    // Dialogs
    var operationFailed: String { t("File operation failed", "文件操作失败") }
    var closeBeforeRenaming: String {
        t("Close this file and any open files inside this folder before renaming it.",
          "重命名前，请先关闭此文件以及此文件夹内已打开的文件。")
    }
    func renameTitle(_ name: String) -> String { t("Rename \(name)", "重命名 \(name)") }
    var renameButton: String { t("Rename", "重命名") }
    var cancel: String { t("Cancel", "取消") }
    var create: String { t("Create", "创建") }
    func createMessage(folder: String) -> String {
        t("Enter a name. It is created in \(folder).", "请输入名称，将创建在 \(folder) 中。")
    }
    var folderPlaceholder: String { t("folder", "文件夹") }

    // Open in another application
    var remoteFoldersUnsupported: String {
        t("Open in… supports remote files, but not remote folders.",
          "「打开方式…」支持远端文件，但不支持远端文件夹。")
    }
    var openRemoteCopyIn: String {
        t("Open a read-only downloaded copy in…", "用其他应用打开下载的只读副本…")
    }
    var remoteCopyMessage: String {
        t("Changes in the other app will not be uploaded to the server.",
          "在其他应用中所做的修改不会上传到服务器。")
    }
    var chooseApplication: String { t("Choose an application.", "请选择一个应用。") }
    var open: String { t("Open", "打开") }
}
