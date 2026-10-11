package com.embabel.guide.spdd;

/**
 * Bytecode fixtures for the projection push-URL fitness function.
 * These classes are test sources. Production import skips them.
 * Nothing here is executed; ArchUnit reads the class files.
 */
public final class ProjectionPushUrlFixtures {
    private ProjectionPushUrlFixtures() {
    }

    /** Direct call with the https push URL. */
    public static final class Direct {
        public void push(Appendable out) throws Exception {
            out.append("https://github.com/embabel/guide.git");
        }
    }

    /** Direct call with the http push URL. */
    public static final class Http {
        public void push(Appendable out) throws Exception {
            out.append("http://github.com/embabel/guide.git");
        }
    }

    /** scp-style git SSH push URL. */
    public static final class Ssh {
        public void push(Appendable out) throws Exception {
            out.append("git@github.com:embabel/guide.git");
        }
    }

    /** ssh:// push URL. */
    public static final class SshUrl {
        public void push(Appendable out) throws Exception {
            out.append("ssh://git@github.com/embabel/guide.git");
        }
    }

    /** Short owner/name form passed through a local. */
    public static final class ShortForm {
        public void push(Appendable out) throws Exception {
            String url = "embabel/guide.git";
            out.append(url);
        }
    }

    /** Varargs process invocation, the usual git push shape. */
    public static final class Process {
        public void push() throws Exception {
            new ProcessBuilder("git", "push", "https://github.com/embabel/guide.git").start();
        }
    }

    /** The URL is returned by one method and passed into a call by another. */
    public static final class Helper {
        public String url() {
            return "https://github.com/embabel/guide.git";
        }

        public void push(Appendable out) throws Exception {
            out.append(url());
        }
    }

    /** Compile-time constant inlined into the call site. */
    public static final class Constant {
        static final String PUSH = "https://github.com/embabel/guide.git";

        public void push(Appendable out) throws Exception {
            out.append(PUSH);
        }
    }

    /** Field assigned in a static initializer, then passed to a call. */
    public static final class StoredField {
        static String pushUrl;

        static {
            pushUrl = "https://github.com/embabel/guide.git";
        }

        public void push(Appendable out) throws Exception {
            out.append(pushUrl);
        }
    }

    /** Fork and lookalike URLs are allowed inside the projection package. */
    public static final class Fork {
        public void push(Appendable out) throws Exception {
            out.append("https://github.com/jmjava/orch-guide.git");
            out.append("https://github.com/jmjava/guide.git");
            out.append("https://github.com/embabel/guidebook.git");
            out.append("https://github.com/embabel/guide-extra.git");
            out.append("https://github.com/embabel/guide/pull/1");
            out.append("https://github.com/notembabel/guide.git");
        }
    }

    /**
     * The push URL is present, and another method makes a call, but nothing
     * calls the URL. That must stay allowed.
     */
    public static final class Mention {
        public String url() {
            return "https://github.com/embabel/guide.git";
        }

        public long clock() {
            return System.nanoTime();
        }
    }
}
