import Foundation
import Testing
@testable import Ghostty

struct GitTerminalCommandsTests {
    private let repository = GitRepositoryIdentity(
        worktreePath: "/tmp/project with space",
        gitDirPath: "/tmp/project with space/.git",
        commonGitDirPath: "/tmp/project with space/.git"
    )

    @Test func quotesRepositoryAndFileArguments() {
        let intent = GitTerminalCommandIntent.diff(
            repository: repository,
            scope: .unstaged,
            file: "a file's name.txt"
        )
        let command = GitTerminalCommandFormatter.format(intent)

        #expect(command.argv == [
            "git", "-C", "/tmp/project with space", "diff", "--", "a file's name.txt",
        ])
        #expect(command.shellCommand == "git -C '/tmp/project with space' diff -- 'a file'\\''s name.txt'")
    }

    @Test func preservesMultilineCommitMessageWithoutEnter() {
        let message = "first line\nsecond line's detail"
        let command = GitTerminalCommandFormatter.format(
            .commit(repository: repository, message: message)
        )

        #expect(command.shellCommand == "git -C '/tmp/project with space' commit -m 'first line\nsecond line'\\''s detail' --")
        #expect(!command.shellCommand.hasSuffix("\n"))
        #expect(command.argv == [
            "git", "-C", "/tmp/project with space", "commit", "-m", message, "--",
        ])
    }

    @Test func formatsTypedCommitAndShowArguments() {
        let commit = GitCommitID("abc1234")
        #expect(
            GitTerminalCommandFormatter.format(
                .show(repository: repository, commit: commit)
            ).shellCommand == "git -C '/tmp/project with space' show 'abc1234'"
        )
        #expect(
            GitTerminalCommandFormatter.format(
                .switchBranch(repository: repository, branch: "feature/new branch")
            ).shellCommand == "git -C '/tmp/project with space' switch -- 'feature/new branch'"
        )
    }
}
