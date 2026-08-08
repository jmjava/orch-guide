package com.embabel.guide.spdd

import com.embabel.agent.rag.model.NamedEntityData
import com.embabel.agent.rag.model.RelationshipDirection
import com.embabel.agent.rag.model.SimpleNamedEntityData
import com.embabel.agent.rag.service.NamedEntityDataRepository
import com.embabel.agent.rag.service.RelationshipData
import com.embabel.agent.rag.service.RetrievableIdentifier
import com.embabel.guide.GuideProperties
import com.fasterxml.jackson.databind.ObjectMapper
import org.slf4j.LoggerFactory
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.stereotype.Service
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.isRegularFile

/**
 * Leg 3 ingest: project structured SPDD artifacts into Neo4j [NamedEntityData.ENTITY_LABEL] nodes.
 *
 * Coexists with leg 2 RAG chunk ingest ([com.embabel.guide.rag.DataManager]) — same Neo4j store,
 * different node layer. Does **not** use the DICE proposition extraction pipeline.
 *
 * Persist contract: lessons.jsonl + canvas markdown are source of truth; [load] is idempotent
 * merge-by-id via [NamedEntityDataRepository.save] + [NamedEntityDataRepository.mergeRelationship].
 * Retrieve contract: [subgraphForWorkId] walks typed edges from the WorkId join key.
 */
@Service
@ConditionalOnProperty(prefix = "guide.spdd-projection", name = ["enabled"], havingValue = "true")
class SpddMarkdownProjectionService(
    private val guideProperties: GuideProperties,
    private val entityRepository: NamedEntityDataRepository,
    private val objectMapper: ObjectMapper,
) {

    private val log = LoggerFactory.getLogger(javaClass)

    private val entityDictionary = SpddEntityDictionary.create()

    fun load(rootPath: String? = null): SpddProjectionResult {
        val projection = guideProperties.spddProjection
        if (!projection.enabled) {
            throw IllegalStateException("guide.spdd-projection.enabled is false")
        }
        val root = resolveEffectiveRoot(resolveRoot(rootPath))
        require(Files.isDirectory(root)) { "SPDD projection root not found: $root" }

        var workIds = 0
        var canvases = 0
        var areas = 0
        var operations = 0
        var decisions = 0
        var pitfalls = 0
        var patterns = 0
        var sessions = 0
        var analyses = 0
        var relationships = 0
        var skippedFiles = 0

        val canvasDir = root.resolve("spdd/canvas")
        if (Files.isDirectory(canvasDir)) {
            Files.list(canvasDir).use { stream ->
                stream.filter { it.isRegularFile() && it.fileName.toString().endsWith(".md") }
                    .sorted()
                    .forEach { path ->
                        val r = runCatching { projectCanvas(root, path) }
                            .onFailure { log.warn("SPDD projection: skipping canvas {}: {}", path, it.message) }
                            .getOrNull()
                        if (r == null) {
                            skippedFiles++
                        } else {
                            workIds += r.workIds
                            canvases += r.canvases
                            operations += r.operations
                            relationships += r.relationships
                        }
                    }
            }
        }

        val lessonsPath = root.resolve("spdd/memory/lessons.jsonl")
        if (Files.isRegularFile(lessonsPath)) {
            val r = runCatching { projectLessonsLedger(root, lessonsPath) }
                .onFailure { log.warn("SPDD projection: skipping lessons ledger {}: {}", lessonsPath, it.message) }
                .getOrNull()
            if (r == null) {
                skippedFiles++
            } else {
                areas += r.areas
                decisions += r.decisions
                pitfalls += r.pitfalls
                patterns += r.patterns
                sessions += r.sessions
                analyses += r.analyses
                relationships += r.relationships
            }
        } else {
            log.debug("SPDD projection: no lessons.jsonl under spdd/memory")
        }

        log.info(
            "SPDD projection complete root={} workIds={} canvases={} areas={} ops={} rels={} skipped={}",
            root, workIds, canvases, areas, operations, relationships, skippedFiles,
        )

        return SpddProjectionResult(
            rootPath = root.toString(),
            workIds = workIds,
            canvases = canvases,
            areas = areas,
            operations = operations,
            decisions = decisions,
            pitfalls = pitfalls,
            patterns = patterns,
            sessions = sessions,
            analyses = analyses,
            relationships = relationships,
            skippedFiles = skippedFiles,
        )
    }

    /**
     * Resolve the projection root. Overrides are only honoured when the resolved path lives
     * under the default root or one of `guide.spdd-projection.allowed-roots`.
     */
    private fun resolveRoot(rootPath: String?): Path {
        val projection = guideProperties.spddProjection
        val defaultRoot = Path.of(guideProperties.resolvePath(projection.defaultRootPath)).normalize()
        val requested = rootPath?.trim()?.takeIf { it.isNotEmpty() } ?: return defaultRoot
        val override = Path.of(guideProperties.resolvePath(requested)).normalize()
        val allowedRoots = projection.allowedRoots
            .map { Path.of(guideProperties.resolvePath(it)).normalize() } + listOf(defaultRoot)
        require(allowedRoots.any { override.startsWith(it) }) {
            "rootPath override '$override' is not under an allowed root $allowedRoots; " +
                "configure guide.spdd-projection.allowed-roots to permit it"
        }
        return override
    }

    /**
     * When rootPath points at a parent workspace, descend into the `sdlc-spdd/`
     * framework home if that directory exists; otherwise use rootPath as-is.
     */
    internal fun resolveEffectiveRoot(root: Path): Path {
        val home = root.resolve("sdlc-spdd")
        return if (Files.isDirectory(home)) home.normalize() else root
    }

    fun entityCountByLabel(label: String): Int =
        entityRepository.findByLabel(label).size

    fun listByLabel(label: String, maxResults: Int = DEFAULT_LIST_RESULTS): List<SpddEntitySummary> {
        val normalized = requireKnownLabel(label)
        val cap = maxResults.coerceIn(1, MAX_LIST_RESULTS)
        return entityRepository.findByLabel(normalized).take(cap).map { toSummary(it) }
    }

    private fun requireKnownLabel(label: String): String {
        val normalized = label.trim()
        require(normalized in SpddEntityDictionary.knownLabels) {
            "Unknown entity label '$normalized'. Known labels: ${SpddEntityDictionary.knownLabels.sorted()}"
        }
        return normalized
    }

    fun subgraphForWorkId(workId: String): SpddWorkIdSubgraph {
        require(workId.isNotBlank()) { "workId must not be blank" }
        val work = entityRepository.findById(workId)
            ?: return SpddWorkIdSubgraph(workId = workId, found = false)
        val workRef = RetrievableIdentifier(workId, "WorkId")
        val canvases = entityRepository.findRelated(workRef, REL_CANVAS, RelationshipDirection.OUTGOING)
        val areas = entityRepository.findRelated(workRef, REL_AREA, RelationshipDirection.OUTGOING)
        val decisions = entityRepository.findRelated(workRef, REL_DECISION, RelationshipDirection.OUTGOING)
        val pitfalls = entityRepository.findRelated(workRef, REL_PITFALL, RelationshipDirection.OUTGOING)
        val patterns = entityRepository.findRelated(workRef, REL_PATTERN, RelationshipDirection.OUTGOING)
        val sessions = entityRepository.findRelated(workRef, REL_SESSION, RelationshipDirection.OUTGOING)
        val analyses = entityRepository.findRelated(workRef, REL_ANALYSIS, RelationshipDirection.OUTGOING)
        return SpddWorkIdSubgraph(
            workId = workId,
            found = true,
            work = toSummary(work),
            canvases = canvases.map { toSummary(it) },
            areas = areas.map { toSummary(it) },
            decisions = decisions.map { toSummary(it) },
            pitfalls = pitfalls.map { toSummary(it) },
            patterns = patterns.map { toSummary(it) },
            sessions = sessions.map { toSummary(it) },
            analyses = analyses.map { toSummary(it) },
        )
    }

    fun lessonsForArea(area: String): SpddAreaLessons {
        require(area.isNotBlank()) { "area must not be blank" }
        val normalized = area.trim().removePrefix("area:")
        val areaId = "area:$normalized"
        val areaEntity = entityRepository.findById(areaId)
            ?: return SpddAreaLessons(area = normalized, found = false)
        val areaRef = RetrievableIdentifier(areaId, "Area")
        val lessons = entityRepository.findRelated(areaRef, REL_ABOUT, RelationshipDirection.INCOMING)
        val works = entityRepository.findRelated(areaRef, REL_AREA, RelationshipDirection.INCOMING)
        return SpddAreaLessons(
            area = normalized,
            found = true,
            areaEntity = toSummary(areaEntity),
            workIds = works.map { toSummary(it) },
            decisions = lessons.filter { "Decision" in it.labels() }.map { toSummary(it) },
            pitfalls = lessons.filter { "Pitfall" in it.labels() }.map { toSummary(it) },
            patterns = lessons.filter { "Pattern" in it.labels() }.map { toSummary(it) },
            sessions = lessons.filter { "Session" in it.labels() }.map { toSummary(it) },
            analyses = lessons.filter { "Analysis" in it.labels() }.map { toSummary(it) },
        )
    }

    /**
     * Fetch one lesson entity by id with full (untruncated) body from persisted properties.
     */
    fun getLesson(id: String): SpddLessonDetail? {
        require(id.isNotBlank()) { "id must not be blank" }
        val entity = entityRepository.findById(id.trim()) ?: return null
        val props = entity.properties
        return SpddLessonDetail(
            id = entity.id,
            name = entity.name,
            description = entity.description,
            body = props["body"]?.toString() ?: entity.description,
            labels = entity.labels().toList(),
            uri = entity.uri,
            keywords = (props["keywords"] as? List<*>)?.mapNotNull { it?.toString() } ?: emptyList(),
            workId = props["workId"]?.toString(),
            area = props["area"]?.toString(),
            source = props["source"]?.toString(),
            phase = props["phase"]?.toString(),
            ts = props["ts"]?.toString(),
        )
    }

    private fun toSummary(entity: NamedEntityData): SpddEntitySummary =
        SpddEntitySummary(
            id = entity.id,
            name = entity.name,
            description = entity.description,
            labels = entity.labels().toList(),
            uri = entity.uri,
        )

    private data class PartialResult(
        val workIds: Int = 0,
        val canvases: Int = 0,
        val areas: Int = 0,
        val operations: Int = 0,
        val decisions: Int = 0,
        val pitfalls: Int = 0,
        val patterns: Int = 0,
        val sessions: Int = 0,
        val analyses: Int = 0,
        val relationships: Int = 0,
    )

    private fun projectCanvas(root: Path, canvasPath: Path): PartialResult {
        val text = Files.readString(canvasPath)
        val workId = WORK_ID_PATTERN.find(text)?.groupValues?.get(1)?.trim()
            ?: return PartialResult()
        val title = CANVAS_TITLE_PATTERN.find(text)?.groupValues?.get(2)?.trim() ?: workId
        val uri = canvasPath.toUri().toString()

        val workEntity = saveEntity(
            id = workId,
            uri = uri,
            name = workId,
            description = title,
            label = "WorkId",
            properties = mapOf("path" to canvasPath.toString()),
        )
        val canvasEntity = saveEntity(
            id = "$workId:canvas",
            uri = uri,
            name = title,
            description = "REASONS canvas for $workId",
            label = "Canvas",
            properties = mapOf("path" to canvasPath.toString()),
        )
        link(workEntity, canvasEntity, REL_CANVAS)

        return PartialResult(workIds = 1, canvases = 1, relationships = 1)
    }

    private fun projectLessonsLedger(root: Path, ledgerPath: Path): PartialResult {
        var areas = 0
        var decisions = 0
        var pitfalls = 0
        var patterns = 0
        var sessions = 0
        var analyses = 0
        var rels = 0
        val seenAreas = mutableSetOf<String>()
        val seenLessons = mutableSetOf<String>()

        Files.lines(ledgerPath).use { lines ->
            lines.filter { it.isNotBlank() }.forEach { line ->
                val record = runCatching { parseLessonRecord(line) }
                    .onFailure { log.warn("SPDD projection: skipping malformed JSONL line: {}", it.message) }
                    .getOrNull() ?: return@forEach

                val kind = record.kind.lowercase()
                val lessonLabel = LESSON_KIND_LABELS[kind] ?: return@forEach
                val workId = record.workId.trim()
                if (workId.isBlank()) return@forEach

                val area = record.area.trim().ifBlank { "(none)" }
                if (area != "(none)" && seenAreas.add(area)) {
                    saveEntity(
                        id = "area:$area",
                        uri = ledgerPath.toUri().toString() + "#area-$area",
                        name = area,
                        description = "Code area $area",
                        label = "Area",
                        properties = mapOf("area" to area),
                    )
                    areas++
                }

                val workRef = RetrievableIdentifier(workId, "WorkId")
                if (area != "(none)") {
                    val areaRef = RetrievableIdentifier("area:$area", "Area")
                    entityRepository.mergeRelationship(workRef, areaRef, RelationshipData(REL_AREA, emptyMap()))
                    rels++
                }

                val lessonId = record.id.ifBlank {
                    "$kind:$workId:$area:${record.source.ifBlank { "capture" }}"
                }
                if (!seenLessons.add(lessonId)) return@forEach

                val title = record.title.ifBlank { record.body.lines().firstOrNull()?.take(120) ?: kind }
                val description = capDescription(record.body.ifBlank { title })
                val lesson = saveEntity(
                    id = lessonId,
                    uri = ledgerPath.toUri().toString() + "#$lessonId",
                    name = title,
                    description = description,
                    label = lessonLabel,
                    properties = buildMap {
                        put("workId", workId)
                        put("area", area)
                        put("source", record.source)
                        put("body", record.body)
                        if (record.phase.isNotBlank()) put("phase", record.phase)
                        if (record.ts.isNotBlank()) put("ts", record.ts)
                        if (record.keywords.isNotEmpty()) put("keywords", record.keywords)
                    },
                )
                val lessonRef = RetrievableIdentifier(lesson.id, lessonLabel)
                entityRepository.mergeRelationship(workRef, lessonRef, RelationshipData(kind, emptyMap()))
                if (area != "(none)") {
                    val areaRef = RetrievableIdentifier("area:$area", "Area")
                    entityRepository.mergeRelationship(lessonRef, areaRef, RelationshipData(REL_ABOUT, emptyMap()))
                    rels++
                }
                rels++
                when (lessonLabel) {
                    "Decision" -> decisions++
                    "Pitfall" -> pitfalls++
                    "Pattern" -> patterns++
                    "Session" -> sessions++
                    "Analysis" -> analyses++
                }
            }
        }

        return PartialResult(
            areas = areas,
            decisions = decisions,
            pitfalls = pitfalls,
            patterns = patterns,
            sessions = sessions,
            analyses = analyses,
            relationships = rels,
        )
    }

    private fun parseLessonRecord(line: String): SpddLessonRecord {
        val node = objectMapper.readTree(line)
        return SpddLessonRecord(
            id = node.path("id").asText(""),
            kind = node.path("kind").asText(""),
            workId = node.path("work_id").asText(""),
            area = node.path("area").asText(""),
            phase = node.path("phase").asText(""),
            ts = node.path("ts").asText(""),
            title = node.path("title").asText(""),
            body = node.path("body").asText(""),
            source = node.path("source").asText("capture"),
            keywords = node.path("keywords").takeIf { it.isArray }?.map { it.asText() } ?: emptyList(),
        )
    }

    private fun capDescription(text: String): String =
        if (text.length <= MAX_ENTITY_DESCRIPTION) text else text.take(MAX_ENTITY_DESCRIPTION) + "…"

    private fun saveEntity(
        id: String,
        uri: String,
        name: String,
        description: String,
        label: String,
        properties: Map<String, Any> = emptyMap(),
    ): SimpleNamedEntityData {
        val entity = SimpleNamedEntityData(
            id = id,
            uri = uri,
            name = name,
            description = description,
            labels = setOf(label, NamedEntityData.ENTITY_LABEL),
            properties = properties,
            metadata = emptyMap(),
            linkedDomainType = entityDictionary.domainTypeForLabels(setOf(label)),
        )
        entityRepository.save(entity)
        return entity
    }

    private fun link(from: SimpleNamedEntityData, to: SimpleNamedEntityData, rel: String) {
        entityRepository.mergeRelationship(
            RetrievableIdentifier(from.id, from.labels.first { it != NamedEntityData.ENTITY_LABEL }),
            RetrievableIdentifier(to.id, to.labels.first { it != NamedEntityData.ENTITY_LABEL }),
            RelationshipData(rel, emptyMap()),
        )
    }

    companion object {
        const val DEFAULT_LIST_RESULTS = 50
        const val MAX_LIST_RESULTS = 200
        const val TOOL_DEFAULT_LIMIT = 20
        const val TOOL_MAX_LIMIT = 100
        const val TOOL_TRUNCATE_CHARS = 300
        const val MAX_ENTITY_DESCRIPTION = 500
        const val TRUNCATE_MARKER = "… [truncated — fetch by id]"

        const val REL_CANVAS = "canvas"
        const val REL_AREA = "area"
        const val REL_DECISION = "decision"
        const val REL_PITFALL = "pitfall"
        const val REL_PATTERN = "pattern"
        const val REL_SESSION = "session"
        const val REL_ANALYSIS = "analysis"
        const val REL_ABOUT = "about"

        private val LESSON_KIND_LABELS = mapOf(
            "decision" to "Decision",
            "pitfall" to "Pitfall",
            "pattern" to "Pattern",
            "session" to "Session",
            "analysis" to "Analysis",
        )

        private val WORK_ID_PATTERN = Regex("""- Work ID:\s*(\S+)""")
        private val CANVAS_TITLE_PATTERN = Regex("""#\s*REASONS Canvas:\s*([^-]+)\s*-\s*(.+)""")
    }
}

/** One line from `spdd/memory/lessons.jsonl`. */
internal data class SpddLessonRecord(
    val id: String = "",
    val kind: String = "",
    val workId: String = "",
    val area: String = "",
    val phase: String = "",
    val ts: String = "",
    val title: String = "",
    val body: String = "",
    val source: String = "capture",
    val keywords: List<String> = emptyList(),
)
