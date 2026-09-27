package com.embabel.guide.rag

import com.embabel.agent.rag.ingestion.ChunkTransformationContext
import com.embabel.agent.rag.model.Chunk
import com.embabel.agent.rag.model.LeafSection
import com.embabel.agent.rag.model.MaterializedDocument
import com.embabel.guide.ContentConfig
import com.embabel.guide.GuideProperties
import com.embabel.guide.VersionedContentConfig
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import java.time.Instant

class VersionChunkTransformerTest {

    @Test
    fun `versioned uri stamps only the first path segment`() {
        val baseUrl = "https://docs.example/guide/"
        val uri = baseUrl + "2.0/concepts/intro"
        val transformer = VersionChunkTransformer(guideProperties(baseUrl))
        val document = MaterializedDocument(
            "doc-1",
            uri,
            "Guide",
            Instant.EPOCH,
            emptyList(),
            emptyMap(),
        )
        val section = LeafSection("s1", uri, "Intro", "body", "doc-1", emptyMap())

        val metadata = transformer.additionalMetadata(
            Chunk.create("c1", "text"),
            ChunkTransformationContext(section, document),
        )

        assertEquals("2.0", metadata["version"])
    }

    private fun guideProperties(baseUrl: String) =
        GuideProperties(
            reloadContentOnStartup = false,
            defaultPersona = "adaptive",
            projectsPath = ".",
            chunkerConfig = null,
            referencesFile = "references.yml",
            content = ContentConfig(
                versioned = VersionedContentConfig(baseUrl = baseUrl),
                supplementary = emptyList(),
            ),
            toolPrefix = "",
            directories = emptyList(),
            toolGroups = emptySet(),
        )
}
