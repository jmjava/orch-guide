package com.embabel.guide.spdd

import com.embabel.agent.rag.service.NamedEntityDataRepository
import com.embabel.agent.rag.service.support.InMemoryNamedEntityDataRepository
import com.embabel.common.ai.model.EmbeddingService
import com.embabel.guide.ContentConfig
import com.embabel.guide.GuideProperties
import com.embabel.guide.VersionedContentConfig
import com.fasterxml.jackson.databind.ObjectMapper
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import org.mockito.Mockito
import java.nio.file.Files
import java.nio.file.Path

class SpddDomainToolsTest {

  @TempDir
  lateinit var tempDir: Path

  private val objectMapper = ObjectMapper()
  private lateinit var tools: SpddDomainTools

  @BeforeEach
  fun setUp() {
    val root = buildProject(tempDir.resolve("project"))
    val service = SpddMarkdownProjectionService(guideProperties(root.toString()), inMemoryRepository(), objectMapper)
    service.load()
    tools = SpddDomainTools(service, objectMapper)
  }

  @Test
  fun `workSubgraph returns typed neighbors as json`() {
    val json = objectMapper.readTree(tools.workSubgraph("SPIKE-FIX-001-retrieval-fixture"))
    assertTrue(json["found"].asBoolean())
    assertEquals("SPIKE-FIX-001-retrieval-fixture:canvas", json["canvases"][0]["id"].asText())
    assertEquals("retry storms", json["pitfalls"][0]["name"].asText())
  }

  @Test
  fun `workSubgraph reports not found without error`() {
    val json = objectMapper.readTree(tools.workSubgraph("FEAT-999-unknown"))
    assertFalse(json["found"].asBoolean())
    assertFalse(json.has("error"))
  }

  @Test
  fun `workSubgraph surfaces blank work id as error payload`() {
    val json = objectMapper.readTree(tools.workSubgraph("   "))
    assertTrue(json.has("error"))
  }

  @Test
  fun `workSubgraph caps list sizes with default limit`() {
    val root = buildProjectManyPitfalls(tempDir.resolve("many"), count = 25)
    val service = SpddMarkdownProjectionService(guideProperties(root.toString()), inMemoryRepository(), objectMapper)
    service.load()
    val manyTools = SpddDomainTools(service, objectMapper)

    val json = objectMapper.readTree(manyTools.workSubgraph("SPIKE-FIX-001-retrieval-fixture"))
    assertEquals(SpddMarkdownProjectionService.TOOL_DEFAULT_LIMIT, json["pitfalls"].size())
  }

  @Test
  fun `workSubgraph truncates long descriptions`() {
    val longBody = "z".repeat(400)
    val root = buildProject(
      tempDir.resolve("truncate"),
      lessonsJsonl = """
        {"id":"pitfall:SPIKE-FIX-001-retrieval-fixture:src/billing:p.md","kind":"pitfall","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","title":"short","body":"$longBody","source":"p.md","schema":1}
      """.trimIndent(),
    )
    val service = SpddMarkdownProjectionService(guideProperties(root.toString()), inMemoryRepository(), objectMapper)
    service.load()
    val truncTools = SpddDomainTools(service, objectMapper)

    val json = objectMapper.readTree(truncTools.workSubgraph("SPIKE-FIX-001-retrieval-fixture"))
    val desc = json["pitfalls"][0]["description"].asText()
    assertTrue(desc.contains(SpddMarkdownProjectionService.TRUNCATE_MARKER))
  }

  @Test
  fun `projectionStats counts all schema labels including session and analysis`() {
    val json = objectMapper.readTree(tools.projectionStats())
    assertEquals(1, json["workIdCount"].asInt())
    assertEquals(1, json["pitfallCount"].asInt())
    assertTrue(json.has("sessionCount"))
    assertTrue(json.has("analysisCount"))
    assertEquals("__Entity__", json["entityLabel"].asText())
  }

  @Test
  fun `findByLabel lists entities for a schema label`() {
    val json = objectMapper.readTree(tools.findByLabel("WorkId"))
    assertEquals(1, json.size())
    assertEquals("SPIKE-FIX-001-retrieval-fixture", json[0]["id"].asText())
  }

  @Test
  fun `findByLabel honors limit parameter`() {
    val root = buildProjectManyPitfalls(tempDir.resolve("label-cap"), count = 30)
    val service = SpddMarkdownProjectionService(guideProperties(root.toString()), inMemoryRepository(), objectMapper)
    service.load()
    val capTools = SpddDomainTools(service, objectMapper)

    val json = objectMapper.readTree(capTools.findByLabel("Pitfall", limit = 5))
    assertEquals(5, json.size())
  }

  @Test
  fun `findByLabel surfaces unknown label as error payload`() {
    val json = objectMapper.readTree(tools.findByLabel("DROP TABLE"))
    assertTrue(json.has("error"))
    assertTrue(json["error"].asText().contains("Known labels"))
  }

  @Test
  fun `areaLessons returns cross-run lessons as json`() {
    val json = objectMapper.readTree(tools.areaLessons("src/billing"))
    assertTrue(json["found"].asBoolean())
    assertEquals("retry storms", json["pitfalls"][0]["name"].asText())
  }

  @Test
  fun `areaLessons surfaces blank area as error payload`() {
    val json = objectMapper.readTree(tools.areaLessons(""))
    assertTrue(json.has("error"))
  }

  @Test
  fun `getLesson returns full body untruncated`() {
    val longBody = "y".repeat(500)
    val root = buildProject(
      tempDir.resolve("get-lesson"),
      lessonsJsonl = """
        {"id":"pitfall:SPIKE-FIX-001-retrieval-fixture:src/billing:p.md","kind":"pitfall","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","title":"t","body":"$longBody","source":"p.md","schema":1}
      """.trimIndent(),
    )
    val service = SpddMarkdownProjectionService(guideProperties(root.toString()), inMemoryRepository(), objectMapper)
    service.load()
    val lessonTools = SpddDomainTools(service, objectMapper)

    val json = objectMapper.readTree(lessonTools.getLesson("pitfall:SPIKE-FIX-001-retrieval-fixture:src/billing:p.md"))
    assertEquals(longBody, json["body"].asText())
    assertFalse(json["body"].asText().contains(SpddMarkdownProjectionService.TRUNCATE_MARKER))
  }

  @Test
  fun `getLesson reports not found for unknown id`() {
    val json = objectMapper.readTree(tools.getLesson("pitfall:UNKNOWN:area:src"))
    assertFalse(json["found"].asBoolean())
  }

  private fun buildProject(root: Path, lessonsJsonl: String = DEFAULT_LESSONS): Path {
    Files.createDirectories(root.resolve("spdd/canvas"))
    Files.createDirectories(root.resolve("spdd/memory"))
    Files.writeString(
      root.resolve("spdd/canvas/SPIKE-FIX-001-retrieval-fixture.md"),
      """
        # REASONS Canvas: SPIKE-FIX-001-retrieval-fixture - Retrieval experiment fixture

        ## Metadata

        - Work ID: SPIKE-FIX-001-retrieval-fixture
      """.trimIndent(),
    )
    Files.writeString(root.resolve("spdd/memory/lessons.jsonl"), lessonsJsonl)
    return root
  }

  private fun buildProjectManyPitfalls(root: Path, count: Int): Path {
    val lines = (1..count).joinToString("\n") { i ->
      """{"id":"pitfall:SPIKE-FIX-001-retrieval-fixture:src/billing:p$i.md","kind":"pitfall","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","title":"pitfall $i","body":"body $i","source":"p$i.md","schema":1}"""
    }
    return buildProject(root, lines)
  }

  private fun guideProperties(defaultRootPath: String) =
    GuideProperties(
      reloadContentOnStartup = false,
      defaultPersona = "adaptive",
      projectsPath = ".",
      chunkerConfig = null,
      referencesFile = "references.yml",
      content = ContentConfig(
        versioned = VersionedContentConfig(baseUrl = "https://example.invalid/", versions = emptyList()),
        supplementary = emptyList(),
      ),
      toolPrefix = "",
      directories = emptyList(),
      toolGroups = emptySet(),
      spddProjection = GuideProperties.SpddProjection(enabled = true, defaultRootPath = defaultRootPath),
    )

  private fun inMemoryRepository(): NamedEntityDataRepository {
    val embeddingService = Mockito.mock(EmbeddingService::class.java)
    Mockito.`when`(embeddingService.embed(Mockito.anyString())).thenReturn(floatArrayOf(0.1f, 0.2f, 0.3f))
    return InMemoryNamedEntityDataRepository(
      SpddEntityDictionary.create(),
      embeddingService,
      ObjectMapper(),
    )
  }

  companion object {
    private val DEFAULT_LESSONS = """
      {"id":"pitfall:SPIKE-FIX-001-retrieval-fixture:src/billing:pitfalls.md","kind":"pitfall","work_id":"SPIKE-FIX-001-retrieval-fixture","area":"src/billing","phase":"code","ts":"2026-07-05T13:00:00Z","title":"retry storms","body":"avoid unbounded retries","source":"pitfalls.md","schema":1}
    """.trimIndent()
  }
}
