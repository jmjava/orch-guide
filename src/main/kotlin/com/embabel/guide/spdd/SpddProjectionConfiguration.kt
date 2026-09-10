package com.embabel.guide.spdd

import com.embabel.agent.api.tool.ToolObject
import com.embabel.agent.mcpserver.McpToolExport
import com.embabel.agent.rag.graph.DrivineNamedEntityDataRepository
import com.embabel.agent.rag.graph.GraphRagServiceProperties
import com.embabel.agent.rag.service.NamedEntityDataRepository
import com.embabel.common.ai.model.EmbeddingService
import com.fasterxml.jackson.databind.ObjectMapper
import org.drivine.manager.GraphObjectManager
import org.drivine.manager.PersistenceManager
import org.springframework.beans.factory.annotation.Qualifier
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration

@Configuration
@ConditionalOnProperty(prefix = "guide.spdd-projection", name = ["enabled"], havingValue = "true")
class SpddProjectionConfiguration {

    @Bean
    fun spddNamedEntityDataRepository(
        @Qualifier("neo") persistenceManager: PersistenceManager,
        graphRagProperties: GraphRagServiceProperties,
        embeddingService: EmbeddingService,
        @Qualifier("neoGraphObjectManager") graphObjectManager: GraphObjectManager,
        objectMapper: ObjectMapper,
    ): NamedEntityDataRepository =
        DrivineNamedEntityDataRepository(
            persistenceManager,
            graphRagProperties,
            SpddEntityDictionary.create(),
            embeddingService,
            graphObjectManager,
            objectMapper,
        )

    /**
     * Expose leg-3 DICE retrieve as MCP tools (`spdd_workSubgraph`, `spdd_projectionStats`,
     * `spdd_findByLabel`, `spdd_areaLessons`, `spdd_getLesson`).
     */
    @Bean
    fun spddDomainMcpTools(
        projectionService: SpddMarkdownProjectionService,
        objectMapper: ObjectMapper,
    ): McpToolExport {
        val tools = SpddDomainTools(projectionService, objectMapper)
        // Prefer withPrefix only — withNamingStrategy replaces (does not compose) the prefix strategy.
        return McpToolExport.fromToolObject(ToolObject(tools).withPrefix("spdd_"))
    }
}
