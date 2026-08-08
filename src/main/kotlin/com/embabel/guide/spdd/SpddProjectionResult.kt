package com.embabel.guide.spdd

data class SpddProjectionResult(
    val rootPath: String,
    val workIds: Int,
    val canvases: Int,
    val areas: Int,
    val operations: Int,
    val decisions: Int,
    val pitfalls: Int,
    val patterns: Int = 0,
    val sessions: Int = 0,
    val analyses: Int = 0,
    val relationships: Int,
    /** Source files that failed to parse/persist and were skipped (load continues past them). */
    val skippedFiles: Int = 0,
)

/** Read-side summary for domain retrieval (leg 3). */
data class SpddEntitySummary(
    val id: String,
    val name: String,
    val description: String,
    val labels: List<String>,
    val uri: String?,
)

/**
 * WorkId-centered subgraph returned by the projection read API.
 * Neighbors are included via typed edges (`canvas`, `area`, `decision`, `pitfall`, `pattern`),
 * not embedding similarity.
 */
data class SpddWorkIdSubgraph(
    val workId: String,
    val found: Boolean,
    val work: SpddEntitySummary? = null,
    val canvases: List<SpddEntitySummary> = emptyList(),
    val areas: List<SpddEntitySummary> = emptyList(),
    val decisions: List<SpddEntitySummary> = emptyList(),
    val pitfalls: List<SpddEntitySummary> = emptyList(),
    val patterns: List<SpddEntitySummary> = emptyList(),
    val sessions: List<SpddEntitySummary> = emptyList(),
    val analyses: List<SpddEntitySummary> = emptyList(),
)

/**
 * Area-centered cross-run lessons: what any prior Work ID recorded against a code area.
 * Lessons arrive via incoming `about` edges; Work IDs via incoming `area` edges.
 */
data class SpddAreaLessons(
    val area: String,
    val found: Boolean,
    val areaEntity: SpddEntitySummary? = null,
    val workIds: List<SpddEntitySummary> = emptyList(),
    val decisions: List<SpddEntitySummary> = emptyList(),
    val pitfalls: List<SpddEntitySummary> = emptyList(),
    val patterns: List<SpddEntitySummary> = emptyList(),
    val sessions: List<SpddEntitySummary> = emptyList(),
    val analyses: List<SpddEntitySummary> = emptyList(),
)

/** Full lesson record for on-demand fetch (untruncated body). */
data class SpddLessonDetail(
    val id: String,
    val name: String,
    val description: String,
    val body: String,
    val labels: List<String>,
    val uri: String?,
    val keywords: List<String> = emptyList(),
    val workId: String? = null,
    val area: String? = null,
    val source: String? = null,
    val phase: String? = null,
    val ts: String? = null,
)

/** Label listing response for HTTP parity checks. */
data class SpddLabelListResponse(
    val label: String,
    val count: Int,
    val items: List<SpddEntitySummary>,
)
