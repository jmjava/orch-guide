package com.embabel.guide.rag;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

class GitIncrementalDirectorySupportTest {

    @TempDir
    Path repo;

    @Test
    void headAndChangedFilesBetweenCommits() throws Exception {
        Assumptions.assumeTrue(gitAvailable(), "git must be on PATH");

        run(repo, "git", "init");
        run(repo, "git", "config", "user.email", "test@test.local");
        run(repo, "git", "config", "user.name", "Test");
        Files.writeString(repo.resolve("a.txt"), "v1", StandardCharsets.UTF_8);
        run(repo, "git", "add", "a.txt");
        run(repo, "git", "commit", "-m", "first");
        String first = GitIncrementalDirectorySupport.headCommit(repo).orElseThrow();

        Files.writeString(repo.resolve("b.txt"), "new", StandardCharsets.UTF_8);
        run(repo, "git", "add", "b.txt");
        run(repo, "git", "commit", "-m", "second");
        String second = GitIncrementalDirectorySupport.headCommit(repo).orElseThrow();

        assertThat(first).isNotEqualTo(second);
        assertThat(GitIncrementalDirectorySupport.isGitWorkTree(repo)).isTrue();

        List<String> changed = GitIncrementalDirectorySupport.changedPathsBetween(repo, first, second);
        assertThat(changed).containsExactly("b.txt");
    }

    @Test
    void changedPathsBetweenOmitsPureDeletes() throws Exception {
        Assumptions.assumeTrue(gitAvailable(), "git must be on PATH");

        run(repo, "git", "init");
        run(repo, "git", "config", "user.email", "test@test.local");
        run(repo, "git", "config", "user.name", "Test");
        Files.writeString(repo.resolve("keep.txt"), "v1", StandardCharsets.UTF_8);
        Files.writeString(repo.resolve("gone.txt"), "v1", StandardCharsets.UTF_8);
        run(repo, "git", "add", "keep.txt", "gone.txt");
        run(repo, "git", "commit", "-m", "first");
        String first = GitIncrementalDirectorySupport.headCommit(repo).orElseThrow();

        Files.delete(repo.resolve("gone.txt"));
        Files.writeString(repo.resolve("added.txt"), "new", StandardCharsets.UTF_8);
        run(repo, "git", "add", "-A");
        run(repo, "git", "commit", "-m", "delete and add");
        String second = GitIncrementalDirectorySupport.headCommit(repo).orElseThrow();

        List<String> changed = GitIncrementalDirectorySupport.changedPathsBetween(repo, first, second);
        assertThat(changed).containsExactly("added.txt");
    }

    @Test
    void findGitWorkTreeRootWalksUpFromSubdirectory() throws Exception {
        Assumptions.assumeTrue(gitAvailable(), "git must be on PATH");

        run(repo, "git", "init");
        Path nested = repo.resolve("spdd/canvas");
        Files.createDirectories(nested);
        Files.writeString(nested.resolve("readme.md"), "x", StandardCharsets.UTF_8);
        run(repo, "git", "config", "user.email", "test@test.local");
        run(repo, "git", "config", "user.name", "Test");
        run(repo, "git", "add", ".");
        run(repo, "git", "commit", "-m", "init");

        assertThat(GitIncrementalDirectorySupport.isGitWorkTree(nested)).isFalse();
        assertThat(GitIncrementalDirectorySupport.findGitWorkTreeRoot(nested))
                .contains(repo.toAbsolutePath().normalize());
    }

    @Test
    void filterPathsUnderDirectoryScopesRepoDiffToConfiguredSubdir() {
        Path root = Path.of("/repo").toAbsolutePath().normalize();
        Path canvas = root.resolve("spdd/canvas");
        List<String> changed = List.of(
                "spdd/canvas/FEAT-001.md",
                "spdd/analysis/notes.md",
                "README.md",
                "spdd/canvas/extra/nested.md"
        );
        assertThat(GitIncrementalDirectorySupport.filterPathsUnderDirectory(root, canvas, changed))
                .containsExactly("spdd/canvas/FEAT-001.md", "spdd/canvas/extra/nested.md");
        assertThat(GitIncrementalDirectorySupport.filterPathsUnderDirectory(root, root, changed))
                .containsExactlyElementsOf(changed);
    }

    private static boolean gitAvailable() throws Exception {
        Process p = new ProcessBuilder("git", "--version").start();
        return p.waitFor(5, TimeUnit.SECONDS) && p.exitValue() == 0;
    }

    private static void run(Path cwd, String... cmd) throws Exception {
        ProcessBuilder pb = new ProcessBuilder(cmd);
        pb.directory(cwd.toFile());
        pb.redirectErrorStream(true);
        Process p = pb.start();
        String out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        assertThat(p.waitFor(30, TimeUnit.SECONDS)).as(out).isTrue();
        assertThat(p.exitValue()).as(out).isZero();
    }
}
