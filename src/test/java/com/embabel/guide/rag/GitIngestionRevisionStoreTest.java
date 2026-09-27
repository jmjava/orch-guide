package com.embabel.guide.rag;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Incremental ingest skips a directory when HEAD matches the stored commit.
 * The state file keeps that commit per absolute path, and a corrupt file
 * must load empty instead of failing the ingest.
 */
class GitIngestionRevisionStoreTest {

    @TempDir
    Path tempDir;

    @Test
    void persistsLastIngestedCommitPerAbsoluteRepoPath() throws Exception {
        Path stateFile = tempDir.resolve("state/git-revisions.json");
        String repo = "/abs/repo";
        String other = "/abs/other";

        GitIngestionRevisionStore store = new GitIngestionRevisionStore(stateFile);
        store.load();
        assertThat(store.getRevision(repo)).isEmpty();
        assertThat(store.isDirty()).isFalse();

        store.putRevision(repo, "abc123");
        store.putRevision(other, "def456");
        assertThat(store.isDirty()).isTrue();
        store.save();
        assertThat(store.isDirty()).isFalse();
        assertThat(Files.isRegularFile(stateFile)).isTrue();

        GitIngestionRevisionStore reloaded = new GitIngestionRevisionStore(stateFile);
        reloaded.load();
        assertThat(reloaded.isDirty()).isFalse();
        assertThat(reloaded.getRevision(repo)).contains("abc123");
        assertThat(reloaded.getRevision(other)).contains("def456");

        assertThat(reloaded.removeRevision(repo)).isTrue();
        assertThat(reloaded.removeRevision("/abs/missing")).isFalse();
        assertThat(reloaded.isDirty()).isTrue();
        reloaded.save();

        GitIngestionRevisionStore afterRemove = new GitIngestionRevisionStore(stateFile);
        afterRemove.load();
        assertThat(afterRemove.getRevision(repo)).isEmpty();
        assertThat(afterRemove.getRevision(other)).contains("def456");

        Files.writeString(stateFile, "{not-json", StandardCharsets.UTF_8);
        GitIngestionRevisionStore corrupt = new GitIngestionRevisionStore(stateFile);
        corrupt.load();
        assertThat(corrupt.getRevision(other)).isEmpty();
        assertThat(corrupt.isDirty()).isFalse();
    }
}
