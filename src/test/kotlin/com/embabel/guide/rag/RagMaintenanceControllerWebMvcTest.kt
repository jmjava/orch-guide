package com.embabel.guide.rag

import com.embabel.hub.JwtTokenService
import com.fasterxml.jackson.databind.ObjectMapper
import org.hamcrest.Matchers.nullValue
import org.junit.jupiter.api.Test
import org.mockito.Mockito.`when`
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest
import org.springframework.context.annotation.Import
import org.springframework.http.MediaType
import org.springframework.test.context.ActiveProfiles
import org.springframework.test.context.bean.override.mockito.MockitoBean
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status

@WebMvcTest(controllers = [RagMaintenanceController::class])
@Import(RagMaintenanceExceptionHandler::class)
@AutoConfigureMockMvc(addFilters = false)
@ActiveProfiles("test")
class RagMaintenanceControllerWebMvcTest {

    @Autowired
    lateinit var mockMvc: MockMvc

    @Autowired
    lateinit var objectMapper: ObjectMapper

    @MockitoBean
    lateinit var maintenanceService: RagContentMaintenanceService

    @MockitoBean
    lateinit var jwtTokenService: JwtTokenService

    @Test
    fun `purge-preview returns ok body`() {
        `when`(
            maintenanceService.previewPurge(null, "~/repo", 10),
        ).thenReturn(
            RagContentMaintenanceService.PurgePreviewResult("file:/abs/repo/", 3L, listOf("file:/abs/repo/a.md")),
        )

        val body = objectMapper.writeValueAsString(
            mapOf("directory" to "~/repo", "sampleLimit" to 10),
        )

        mockMvc.perform(
            post("/api/v1/data/content-elements/purge-preview")
                .contentType(MediaType.APPLICATION_JSON)
                .content(body),
        )
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.appliedUriPrefix").value("file:/abs/repo/"))
            .andExpect(jsonPath("$.matchCount").value(3))
            .andExpect(jsonPath("$.sampleUris[0]").value("file:/abs/repo/a.md"))
    }

    @Test
    fun `purge-preview bad request from maintenance service`() {
        `when`(maintenanceService.previewPurge("", "", 10))
            .thenThrow(IllegalArgumentException("Provide uriPrefix or directory"))

        val body = objectMapper.writeValueAsString(mapOf("uriPrefix" to "", "directory" to ""))

        mockMvc.perform(
            post("/api/v1/data/content-elements/purge-preview")
                .contentType(MediaType.APPLICATION_JSON)
                .content(body),
        )
            .andExpect(status().isBadRequest)
    }

    @Test
    fun `git revision reset returns 500 when the revision file cannot be saved`() {
        `when`(maintenanceService.resetGitIngestionRevision("/srv/repo"))
            .thenThrow(java.io.IOException("disk full"))

        val body = objectMapper.writeValueAsString(mapOf("directory" to "/srv/repo"))

        mockMvc.perform(
            post("/api/v1/data/git-ingestion/revision/reset")
                .contentType(MediaType.APPLICATION_JSON)
                .content(body),
        )
            .andExpect(status().isInternalServerError)
            .andExpect(jsonPath("$.absolutePath").value(nullValue()))
            .andExpect(jsonPath("$.removed").value(false))
            .andExpect(jsonPath("$.message").value("Failed to save revision file: disk full"))
    }
}
