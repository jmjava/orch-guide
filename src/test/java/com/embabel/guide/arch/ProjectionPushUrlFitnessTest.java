package com.embabel.guide.arch;

import com.embabel.guide.rag.CallsEmbabelGuidePushUrlOutsideProjection;
import com.embabel.guide.spdd.ProjectionPushUrlFixtures;
import com.embabel.guide.spdd.SpddMarkdownProjectionService;
import com.tngtech.archunit.core.domain.JavaClass;
import com.tngtech.archunit.core.domain.JavaClasses;
import com.tngtech.archunit.core.importer.ClassFileImporter;
import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.lang.ArchCondition;
import com.tngtech.archunit.lang.ArchRule;
import com.tngtech.archunit.lang.ConditionEvents;
import com.tngtech.archunit.lang.SimpleConditionEvent;
import org.junit.jupiter.api.Test;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.FieldNode;
import org.objectweb.asm.tree.InvokeDynamicInsnNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;

import java.io.IOException;
import java.io.InputStream;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Pattern;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.classes;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Fitness function: projection code may not call embabel/guide push URLs.
 * A class that only mentions the URL, or that calls a jmjava/orch-guide or
 * jmjava/guide URL, stays allowed.
 */
class ProjectionPushUrlFitnessTest {

    static final ArchRule PROJECTION_MUST_NOT_CALL_EMBABEL_GUIDE_PUSH_URLS =
            classes()
                    .that().resideInAPackage("com.embabel.guide.spdd..")
                    .should(notCallEmbabelGuidePushUrls())
                    .because("projection code may not call embabel/guide push URLs");

    /**
     * Repo URL only. A subpath such as /pull/1 is not a push URL.
     * Lookalikes (guidebook, guide-extra, jmjava/guide, jmjava/orch-guide,
     * notembabel/guide) do not match.
     */
    private static final Pattern EMBABEL_GUIDE_PUSH_URL = Pattern.compile(
            "(?i)(?:(?:https?://|ssh://(?:git@)?|git@)github\\.com[:/]+|(?<![A-Za-z0-9._-]))"
                    + "embabel/guide(?:\\.git)?/?(?![A-Za-z0-9._/-])");

    @Test
    void projectionCodeDoesNotCallEmbabelGuidePushUrls() {
        JavaClasses production = new ClassFileImporter()
                .withImportOption(ImportOption.Predefined.DO_NOT_INCLUDE_TESTS)
                .importPackages("com.embabel.guide.spdd");
        assertFalse(production.isEmpty(), "projection package imported no classes");
        boolean sawService = false;
        int projectionTypes = 0;
        for (JavaClass javaClass : production) {
            String name = javaClass.getName();
            assertFalse(name.contains("ProjectionPushUrlFixtures"), name);
            assertFalse(name.contains("CallsEmbabelGuidePushUrlOutsideProjection"), name);
            if (name.startsWith("com.embabel.guide.spdd")) {
                projectionTypes++;
            }
            if (name.equals(SpddMarkdownProjectionService.class.getName())) {
                sawService = true;
            }
        }
        assertTrue(sawService, "SpddMarkdownProjectionService was not imported");
        assertTrue(projectionTypes >= 8, "imported " + projectionTypes + " projection types");
        PROJECTION_MUST_NOT_CALL_EMBABEL_GUIDE_PUSH_URLS.check(production);
    }

    @Test
    void rejectsProjectionCallsToEmbabelGuidePushUrls() {
        List<Class<?>> violators = List.of(
                ProjectionPushUrlFixtures.Direct.class,
                ProjectionPushUrlFixtures.Http.class,
                ProjectionPushUrlFixtures.Ssh.class,
                ProjectionPushUrlFixtures.SshUrl.class,
                ProjectionPushUrlFixtures.ShortForm.class,
                ProjectionPushUrlFixtures.Process.class,
                ProjectionPushUrlFixtures.Helper.class,
                ProjectionPushUrlFixtures.Constant.class,
                ProjectionPushUrlFixtures.StoredField.class);
        for (Class<?> violator : violators) {
            JavaClasses classes = new ClassFileImporter().importClasses(violator);
            AssertionError error = assertThrows(
                    AssertionError.class,
                    () -> PROJECTION_MUST_NOT_CALL_EMBABEL_GUIDE_PUSH_URLS.check(classes),
                    violator.getName());
            assertTrue(error.getMessage().contains(violator.getSimpleName()), error.getMessage());
            assertTrue(error.getMessage().contains("embabel/guide"), error.getMessage());
        }
    }

    @Test
    void allowsForkUrlsAndMentionsThatAreNotCalls() {
        JavaClasses classes = new ClassFileImporter().importClasses(
                ProjectionPushUrlFixtures.Fork.class,
                ProjectionPushUrlFixtures.Mention.class);
        PROJECTION_MUST_NOT_CALL_EMBABEL_GUIDE_PUSH_URLS.check(classes);
    }

    @Test
    void ignoresTheSameCallOutsideTheProjectionPackage() {
        JavaClasses classes = new ClassFileImporter().importClasses(
                CallsEmbabelGuidePushUrlOutsideProjection.class,
                ProjectionPushUrlFixtures.Fork.class);
        PROJECTION_MUST_NOT_CALL_EMBABEL_GUIDE_PUSH_URLS.check(classes);
    }

    @Test
    void pushUrlMatcherAcceptsPushFormsAndRejectsLookalikes() {
        assertTrue(isEmbabelGuidePushUrl("https://github.com/embabel/guide.git"));
        assertTrue(isEmbabelGuidePushUrl("https://github.com/embabel/guide"));
        assertTrue(isEmbabelGuidePushUrl("https://github.com/embabel/guide/"));
        assertTrue(isEmbabelGuidePushUrl("http://github.com/embabel/guide.git"));
        assertTrue(isEmbabelGuidePushUrl("git@github.com:embabel/guide.git"));
        assertTrue(isEmbabelGuidePushUrl("ssh://git@github.com/embabel/guide.git"));
        assertTrue(isEmbabelGuidePushUrl("embabel/guide.git"));
        assertTrue(isEmbabelGuidePushUrl("embabel/guide"));
        assertTrue(isEmbabelGuidePushUrl("git push https://github.com/embabel/guide.git"));
        assertFalse(isEmbabelGuidePushUrl("https://github.com/jmjava/orch-guide.git"));
        assertFalse(isEmbabelGuidePushUrl("https://github.com/jmjava/guide.git"));
        assertFalse(isEmbabelGuidePushUrl("https://github.com/embabel/guidebook.git"));
        assertFalse(isEmbabelGuidePushUrl("https://github.com/embabel/guide-extra.git"));
        assertFalse(isEmbabelGuidePushUrl("https://github.com/embabel/guide/pull/1"));
        assertFalse(isEmbabelGuidePushUrl("https://github.com/notembabel/guide.git"));
        assertFalse(isEmbabelGuidePushUrl("notembabel/guide"));
        assertFalse(isEmbabelGuidePushUrl(""));
        assertFalse(isEmbabelGuidePushUrl(null));
    }

    static boolean isEmbabelGuidePushUrl(String value) {
        if (value == null || value.isBlank()) {
            return false;
        }
        return EMBABEL_GUIDE_PUSH_URL.matcher(value.trim()).find();
    }

    private static ArchCondition<JavaClass> notCallEmbabelGuidePushUrls() {
        return new ArchCondition<JavaClass>("not call embabel/guide push URLs") {
            @Override
            public void check(JavaClass item, ConditionEvents events) {
                byte[] bytes;
                try {
                    bytes = classBytes(item);
                } catch (IOException ex) {
                    events.add(SimpleConditionEvent.violated(
                            item,
                            item.getName() + " class file could not be read: " + ex.getMessage()));
                    return;
                }
                for (String method : methodsThatCallEmbabelGuidePushUrl(bytes)) {
                    events.add(SimpleConditionEvent.violated(
                            item,
                            item.getName() + " calls an embabel/guide push URL from " + method));
                }
            }
        };
    }

    private static byte[] classBytes(JavaClass javaClass) throws IOException {
        String resource = javaClass.getName().replace('.', '/') + ".class";
        ClassLoader loader = javaClass.reflect().getClassLoader();
        InputStream in = loader == null
                ? ClassLoader.getSystemResourceAsStream(resource)
                : loader.getResourceAsStream(resource);
        if (in == null) {
            throw new IOException(resource);
        }
        try (in) {
            return in.readAllBytes();
        }
    }

    /**
     * A method calls a push URL when it loads one and invokes something, or when
     * it invokes a sibling method that loads one and also invokes something else.
     * A method that only returns the URL does not call it.
     */
    static List<String> methodsThatCallEmbabelGuidePushUrl(byte[] classBytes) {
        ClassNode node = new ClassNode();
        new ClassReader(classBytes).accept(node, 0);
        Set<String> forbiddenFields = forbiddenFields(node);
        Set<String> producers = new HashSet<>();
        for (MethodNode method : node.methods) {
            if (loadsPushUrl(method, node.name, forbiddenFields)) {
                producers.add(method.name + method.desc);
            }
        }
        java.util.ArrayList<String> calls = new java.util.ArrayList<>();
        for (MethodNode method : node.methods) {
            if (callsPushUrl(method, node.name, producers, forbiddenFields)) {
                calls.add(method.name + method.desc);
            }
        }
        return calls;
    }

    private static Set<String> forbiddenFields(ClassNode node) {
        Set<String> fields = new HashSet<>();
        for (FieldNode field : node.fields) {
            if (field.value instanceof String value && isEmbabelGuidePushUrl(value)) {
                fields.add(field.name);
            }
        }
        for (MethodNode method : node.methods) {
            String pending = null;
            for (AbstractInsnNode insn : method.instructions) {
                if (insn instanceof LdcInsnNode ldc
                        && ldc.cst instanceof String value
                        && isEmbabelGuidePushUrl(value)) {
                    pending = value;
                    continue;
                }
                if (insn instanceof FieldInsnNode field
                        && field.getOpcode() == Opcodes.PUTSTATIC
                        && field.owner.equals(node.name)
                        && pending != null) {
                    fields.add(field.name);
                    pending = null;
                    continue;
                }
                if (insn.getOpcode() >= 0) {
                    pending = null;
                }
            }
        }
        return fields;
    }

    private static boolean loadsPushUrl(MethodNode method, String owner, Set<String> forbiddenFields) {
        if (method.instructions == null) {
            return false;
        }
        for (AbstractInsnNode insn : method.instructions) {
            if (insn instanceof LdcInsnNode ldc
                    && ldc.cst instanceof String value
                    && isEmbabelGuidePushUrl(value)) {
                return true;
            }
            if (insn instanceof FieldInsnNode field
                    && field.getOpcode() == Opcodes.GETSTATIC
                    && field.owner.equals(owner)
                    && forbiddenFields.contains(field.name)) {
                return true;
            }
        }
        return false;
    }

    private static boolean callsPushUrl(
            MethodNode method,
            String owner,
            Set<String> producers,
            Set<String> forbiddenFields) {
        if (method.instructions == null) {
            return false;
        }
        boolean loads = loadsPushUrl(method, owner, forbiddenFields);
        boolean invokesProducer = false;
        boolean invokesOther = false;
        int invokes = 0;
        for (AbstractInsnNode insn : method.instructions) {
            if (insn instanceof MethodInsnNode called) {
                invokes++;
                if (called.owner.equals(owner) && producers.contains(called.name + called.desc)) {
                    invokesProducer = true;
                } else {
                    invokesOther = true;
                }
            } else if (insn instanceof InvokeDynamicInsnNode) {
                invokes++;
                invokesOther = true;
            }
        }
        if (loads && invokes > 0) {
            return true;
        }
        return invokesProducer && invokesOther;
    }
}
