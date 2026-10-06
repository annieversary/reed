import Foundation
import NaturalLanguage

public enum ArticleSpeech {
    /// The passages of a saved reader document to read aloud, one per block, starting with the title.
    /// Code, tables, drawings and equations are left out, since they don't make sense spoken. A picture standing on its own
    /// is its own passage, read by its alt text; one beside text is left out, so it doesn't break up the sentence.
    /// The rest of a figure, like its caption, is left out.
    public static func passages(title: String, html: String) -> [String] {
        var body = Substring(html)
        if let start = body.range(of: "<main>"), let end = body.range(of: "</main>", options: .backwards), start.upperBound <= end.lowerBound {
            body = body[start.upperBound..<end.lowerBound]
        }
        let unspoken = #/<(pre|table|svg|script|style)\b.*?</\1\s*>|<span class="missing-image">.*?</span>|<figure class="equation">.*?</figure\s*>/#
            .dotMatchesNewlines().ignoresCase()
        let figure = #/<figure\b[^>]*>(.*?)</figure\s*>/#.dotMatchesNewlines().ignoresCase()
        let block = #/</?(?:p|div|h[1-6]|li|ul|ol|dl|dt|dd|blockquote|section|article|header|footer|aside|hr)\b[^>]*>|<br\s*/?>/#
            .ignoresCase()
        // Source line breaks fall inside paragraphs, so blocks are separated with a character HTML text never contains.
        let blocks = String(body).replacing(unspoken, with: "\u{1}")
            .replacing(figure) { "\u{1}" + $0.output.1.matches(of: ArticleHTML.imageTag()).map { "\($0.output)\u{1}" }.joined() }
            .replacing(block, with: "\u{1}").split(separator: "\u{1}")
        return ([title] + blocks.flatMap { spoken(block: String($0)) })
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
    }

    /// A block's text, or each of its pictures by its alt text when it has nothing else to read.
    /// The reader's narration highlighting reads pictures the same way.
    private static func spoken(block: String) -> [String] {
        let text = ArticleText.plain(block)
        if text.contains(where: { $0.isLetter || $0.isNumber }) { return [text] }
        return block.matches(of: ArticleHTML.imageTag()).compactMap { image in
            let alt = ArticleText.plain(ArticleHTML.alt(of: String(image.output)))
            return isWorthReading(alt: alt) ? "Image: \(alt)" : nil
        }
    }

    /// Whether alt text says something: not TeX, which reads as a jumble of symbols, nor a file name or a word like "image".
    static func isWorthReading(alt: String) -> Bool {
        alt.contains { $0.isLetter || $0.isNumber }
            && !alt.contains { "\\^_{".contains($0) }
            && alt.wholeMatch(of: #/.*\.(?:jpe?g|png|gif|webp|avif|svg|bmp|tiff?|heic)/#.ignoresCase()) == nil
            && alt.wholeMatch(of: #/(?:image|img|picture|pic|photo|figure|graphic|untitled|null|undefined)\s*\d*/#.ignoresCase()) == nil
    }

    /// The sentences of a passage, in order. Fragments with nothing to say, like a lone dash, stay with the sentence before.
    public static func sentences(in passage: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = passage
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: passage.startIndex..<passage.endIndex) { range, _ in
            let sentence = passage[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.isEmpty { return true }
            if !sentence.contains(where: { $0.isLetter || $0.isNumber }), let last = sentences.popLast() {
                sentences.append(last + " " + sentence)
            } else {
                sentences.append(sentence)
            }
            return true
        }
        return sentences.isEmpty ? [passage] : sentences
    }

    /// A sentence as Kokoro should be given it. Kokoro reads punctuation as pauses and splits words on it,
    /// so names written with dots, underscores or symbols ("Node.js", "io_uring", "C++", "v1.2.3") are spelled the way they're said,
    /// names ending in an initialism ("CockroachDB", "SolidJS") are split so it's spelled out, and numeronyms ("k8s", "a11y") are said in full.
    /// Plural initialisms ("LLMs", "APIs") are written as possessives, which Kokoro spells out letter by letter,
    /// where it would otherwise sound them out as a word.
    public static func spoken(_ sentence: String) -> String {
        sentence
            .replacing(#/\b([a-z]\d+[a-z]s?)\b/#.ignoresCase()) { numeronyms[$0.1.lowercased()] ?? String($0.0) }
            .replacing(#/\b([CF])[#]/#) { "\($0.1) sharp" }
            .replacing(#/\bC\+\+/#, with: "C plus plus")
            .replacing(#/(^|[^\w.])\.NET\b/#) { "\($0.1)dot net" }
            .replacing(#/([A-Za-z0-9])\.(js|ts)\b/#.ignoresCase()) { "\($0.1) \($0.2.uppercased())" }
            .replacing(#/\b([A-Za-z][A-Za-z0-9]+)\.(?=[A-Za-z][A-Za-z0-9]+\b)/#.wordBoundaryKind(.simple)) { "\($0.1) dot " }
            .replacing(#/\bv(?=\d+(\.\d+)+\b)/#.wordBoundaryKind(.simple), with: "version ")
            .replacing(#/(^|[^\d.])(\d+)\.(\d+)\.(\d+)(?![.\d])/#) { "\($0.1)\($0.2) dot \($0.3) dot \($0.4)" }
            .replacing(#/([A-Za-z0-9])_+(?=[A-Za-z0-9])/#) { "\($0.1) " }
            .replacing(#/\b([A-Z][a-z]{2,})(DB|JS)\b/#) { "\($0.1) \($0.2)" }
            .replacing(#/\b([A-Z]{2,5})s\b/#) { "\($0.1)'s" }
    }

    /// Words abbreviated by their first and last letters around a count of the ones between, said in full.
    private static let numeronyms = [
        "k8s": "Kubernetes", "a11y": "accessibility", "i18n": "internationalization", "l10n": "localization",
        "o11y": "observability", "p13n": "personalization", "g11n": "globalization", "m17n": "multilingualization",
    ]

    /// Misaki IPA for technical terms Kokoro's lexicon lacks or gets wrong. Keys match exactly,
    /// or in lowercase when the key is lowercase, so "macos" covers "macOS" and "MacOS".
    public static let pronunciations: [String: String] = [
        // Data formats and protocols
        "JSON": "ʤˈAsᵊn",
        "YAML": "jˈæmᵊl",
        "TOML": "tˈɑmᵊl",
        "wasm": "wˈɑzᵊm",
        "webassembly": "wˈɛbəsˌɛmbli",
        "WASI": "wˈɑzi",
        "OAuth": "ˈO ˌɔθ",
        "CORS": "kˈɔɹz",
        "grpc": "ʤˌi ˌɑɹ pˌi sˈi",
        "protobuf": "pɹˈOtObˌʌf",
        "avro": "ˈævɹO",
        "webp": "wˈɛb pˈi",
        "webgl": "wˈɛb ʤˌi ˈɛl",
        "webgpu": "wˈɛb ʤˌi pˌi jˈu",
        "webrtc": "wˈɛb ˌɑɹ tˌi sˈi",
        "activitypub": "æktˈɪvəɾi pˌʌb",
        "fediverse": "fˈɛdəvˌɜɹs",
        "nostr": "nˈɑstəɹ",
        "wifi": "wˈIfˌI",
        // Hardware
        "CUDA": "kˈudə",
        "rocm": "ɹˈɑk ˈɛm",
        "SIMD": "sˈɪmdi",
        "CISC": "sˈɪsk",
        "riscv": "ɹˈɪsk fˈIv",
        "amd": "ˌA ˌɛm dˈi",
        "NUMA": "nˈumə",
        "nvme": "ˌɛn vˌi ˌɛm ˈi",
        "pcie": "pˌi sˌi ˌI ˈi",
        "arduino": "ɑɹdwˈinO",
        "vulkan": "vˈʌlkən",
        "opengl": "ˈOpən ʤˌi ˈɛl",
        "directx": "dəɹˈɛktˌɛks",
        // Operating systems and platforms
        "OS": "ˌO ˈɛs",
        "macos": "mˈæk ˌO ˈɛs",
        "ipados": "ˈIpˌæd ˌO ˈɛs",
        "watchos": "wˈɑʧ ˌO ˈɛs",
        "tvos": "tˌi vˈi ˌO ˈɛs",
        "visionos": "vˈɪʒən ˌO ˈɛs",
        "nixos": "nˈɪks ˌO ˈɛs",
        "centos": "sˈɛntˌɑs",
        "POSIX": "pˈɑzɪks",
        "SUSE": "sˈuzə",
        "freebsd": "fɹˈi bˌi ˌɛs dˈi",
        "openbsd": "ˈOpən bˌi ˌɛs dˈi",
        "netbsd": "nˈɛt bˌi ˌɛs dˈi",
        "debian": "dˈɛbiən",
        "wayland": "wˈAlənd",
        "xfce": "ˌɛks ˌɛf sˌi ˈi",
        "systemd": "sˈɪstəm dˈi",
        "cron": "kɹˈɑn",
        "ebpf": "ˌi bˌi pˌi ˈɛf",
        "dtrace": "dˈi tɹˌAs",
        "strace": "ˈɛs tɹˌAs",
        "epoll": "ˈipˌOl",
        "kqueue": "kˈA kjˌu",
        "mmap": "ˈɛm mˌæp",
        "malloc": "mˈælˌɑk",
        "printf": "pɹˈɪnt ˈɛf",
        "stdin": "stˈændəɹd ˈɪn",
        "stdout": "stˈændəɹd ˈWt",
        "qemu": "kˈimjˌu",
        "btrfs": "bˈʌɾəɹ ˌɛf ˈɛs",
        "ext": "ˌi ˌɛks tˈi",
        "seL": "ˌɛs ˌi ˈɛl",
        "selinux": "ˈɛs ˈi lˈɪnəks",
        "apparmor": "ˈæp ˌɑɹməɹ",
        "seccomp": "sˈɛk kˌɑmp",
        "iptables": "ˈI pˈi tˌAbᵊlz",
        "nftables": "ˌɛn ˈɛf tˌAbᵊlz",
        "dnsmasq": "dˌi ˌɛn ˈɛs mˌæsk",
        "openwrt": "ˈOpən dˌʌbᵊlju ˌɑɹ tˈi",
        "pfsense": "pˌi ˈɛf sˌɛns",
        "opnsense": "ˈOpən sˌɛns",
        "guix": "ɡˈiks",
        "nixpkgs": "nˈɪks pˌækɪʤᵻz",
        "dnf": "dˌi ˌɛn ˈɛf",
        "appimage": "ˈæp ˌɪmɪʤ",
        "iterm": "ˈI tˌɜɹm",
        "nushell": "nˈu ʃˌɛl",
        "xargs": "ˈɛks ˌɑɹɡz",
        "chroot": "ʧɹˈut",
        "fsync": "ˈɛf sˌɪŋk",
        "inode": "ˈI nˌOd",
        "execve": "ɪɡzˈɛk vˈi",
        "ioctl": "ˈI ˈɑktᵊl",
        "procfs": "pɹˈɑk ˌɛf ˈɛs",
        "sysfs": "sˈɪs ˌɛf ˈɛs",
        "tmpfs": "tˈɛmp ˌɛf ˈɛs",
        "cgroup": "sˈi ɡɹˌup",
        "cgroups": "sˈi ɡɹˌups",
        "openrc": "ˈOpən ˌɑɹ sˈi",
        "launchd": "lˈɔnʧ dˈi",
        // Languages and compilers
        "ocaml": "ˌOkˈæmᵊl",
        "erlang": "ˈɜɹlæŋ",
        "haskell": "hˈæskᵊl",
        "clojure": "klˈOʒəɹ",
        "golang": "ɡˈOlˌæŋ",
        "rustacean": "ɹʌstˈAʃən",
        "lua": "lˈuə",
        "luajit": "lˈuə ʤˌɪt",
        "matlab": "mˈætlˌæb",
        "TeX": "tˈɛk",
        "LaTeX": "lˈAtˌɛk",
        "typst": "tˈIpst",
        "JIT": "ʤˈɪt",
        "cpp": "sˌi pˌi pˈi",
        "rustc": "ɹˈʌst sˈi",
        "rustup": "ɹˈʌstˌʌp",
        "clippy": "klˈɪpi",
        "miri": "mˈɪɹi",
        "emscripten": "ɛmskɹˈɪptən",
        "valgrind": "vˈælɡɹˌɪnd",
        "gdb": "ʤˌi dˌi bˈi",
        "lldb": "ˌɛl ˌɛl dˌi bˈi",
        "GHCi": "ʤˌi ˌAʧ sˌi ˈI",
        "agda": "ˈæɡdə",
        "coq": "kˈOk",
        "isabelle": "ˈɪzəbˌɛl",
        "pharo": "fˈɑɹO",
        "elisp": "ˈi lˌɪsp",
        "tcl": "tˈɪkᵊl",
        "graalvm": "ɡɹˈAl vˌi ˈɛm",
        "openjdk": "ˈOpən ʤˌA dˌi kˈA",
        "rustfmt": "ɹˈʌst fˈɔɹmˌæt",
        "gofmt": "ɡˈO fˈʌmpt",
        "musl": "mˈʌsᵊl",
        "glibc": "ʤˈi lˌɪb sˈi",
        "libc": "lˈɪb sˈi",
        "libuv": "lˈɪb jˌu vˈi",
        "pthread": "pˈi θɹˌɛd",
        "pthreads": "pˈi θɹˌɛdz",
        "serde": "sˈɜɹdi",
        "objdump": "ˈɑbʤ dˌʌmp",
        "readelf": "ɹˈid ˌɛlf",
        "dlopen": "dˌi ˈɛl ˌOpən",
        "ccache": "sˈi kˌæʃ",
        "sccache": "ˌɛs sˈi kˌæʃ",
        "bazel": "bˈAzᵊl",
        "cmake": "sˈi mˌAk",
        "meson": "mˈɛsˌɑn",
        "vcpkg": "vˌi sˌi pˈækɪʤ",
        // Libraries, frameworks and tools
        "nginx": "ˈɛnʤənˌɛks",
        "kubernetes": "kˌubəɹnˈɛtiz",
        "kubectl": "kjˈub kəntɹˈOl",
        "istio": "ˈɪstiˌO",
        "ansible": "ˈænsəbᵊl",
        "podman": "pˈɑdmˌæn",
        "homebrew": "hˈOmbɹˌu",
        "powershell": "pˈWəɹʃˌɛl",
        "zsh": "zˌi ˌɛs ˈAʧ",
        "tmux": "tˈimˌʌks",
        "sudo": "sˈudˌu",
        "sed": "sˈɛd",
        "jq": "ʤˌA kjˈu",
        "wget": "dˈʌbᵊlju ɡˌɛt",
        "fzf": "ˌɛf zˌi ˈɛf",
        "ripgrep": "ɹˈɪpɡɹˌɛp",
        "emacs": "ˈimˌæks",
        "neovim": "nˈiOvˌɪm",
        "vscode": "vˌi ˌɛs kˈOd",
        "xcode": "ˈɛkskˌOd",
        "openssl": "ˈOpən ˌɛs ˌɛs ˈɛl",
        "wireguard": "wˈIəɹɡˌɑɹd",
        "jujutsu": "ʤuʤˈʊtsu",
        "npm": "ˌɛn pˌi ˈɛm",
        "pnpm": "pˌi ˌɛn pˌi ˈɛm",
        "pypi": "pˈI pˌi ˈI",
        "conda": "kˈɑndə",
        "uv": "jˌu vˈi",
        "deno": "dˈinO",
        "vite": "vˈit",
        "webpack": "wˈɛbpˌæk",
        "rollup": "ɹˈOlˌʌp",
        "esbuild": "ˈi ˈɛs bˌɪld",
        "eslint": "ˈi ˈɛs lˌɪnt",
        "vue": "vjˈu",
        "nuxt": "nˈʌkst",
        "sveltekit": "svˈɛltkˌɪt",
        "qwik": "kwˈɪk",
        "astro": "ˈæstɹO",
        "htmx": "ˌAʧ tˌi ˌɛm ˈɛks",
        "jquery": "ʤˈAkwˌɪɹi",
        "tauri": "tˈWɹi",
        "django": "ʤˈæŋɡO",
        "fastapi": "fˈæst ˌA pˌi ˈI",
        "laravel": "lˈæɹəvˌɛl",
        "swiftui": "swˈɪft jˌu ˈI",
        "numpy": "nˈʌmpˌI",
        "scipy": "sˈIpˌI",
        "jupyter": "ʤˈupəɾəɹ",
        "pytorch": "pˈItˌɔɹʧ",
        "tensorflow": "tˈɛnsəɹflˌO",
        "ONNX": "ˈɑnɪks",
        "vllm": "vˈi ˌɛl ˌɛl ˈɛm",
        "pandoc": "pˈændˌɑk",
        "asciidoc": "ˈæskidˌɑk",
        "webkit": "wˈɛbkˌɪt",
        "firefox": "fˈIəɹfˌɑks",
        "ollama": "Olˈɑmə",
        "langchain": "lˈæŋʧˌAn",
        "llamaindex": "lˈɑmə ˌɪndɛks",
        "JAX": "ʤˈæks",
        "xgboost": "ˌɛks ʤˌi bˈust",
        "sklearn": "sˈIkɪt lˌɜɹn",
        "cudnn": "kjˌu dˌi ˌɛn ˈɛn",
        "NCCL": "nˈɪkᵊl",
        "qlora": "kjˈu lˌɔɹə",
        "MoE": "ˌɛm ˌO ˈi",
        "relu": "ɹˈAlu",
        "tiktoken": "tˈɪk tˌOkən",
        "dalle": "dˈɑli",
        "trpc": "tˌi ˌɑɹ pˌi sˈi",
        "vitest": "vˈit ˌɛst",
        "shadcn": "ʃˈæd sˌi ˈɛn",
        "liveview": "lˈIv vjˌu",
        "etcd": "ˌɛt sˌi dˈi",
        "traefik": "tɹˈæfɪk",
        "haproxy": "ˌAʧ ˈA pɹˌɑksi",
        "memcached": "mˈɛm kˌæʃ dˈi",
        "rabbitmq": "ɹˈæbɪt ˌɛm kjˈu",
        "zeromq": "zˈɪɹO ˌɛm kjˈu",
        "NATS": "nˈæts",
        "hadoop": "hədˈup",
        "certbot": "sˈɜɹt bˌɑt",
        "sqlx": "ˌɛs kjˌu ˌɛl ˈɛks",
        // Databases
        "postgres": "pˈOstɡɹˌɛs",
        "postgresql": "pˈOstɡɹˌɛs kjˌu ˈɛl",
        "postgis": "pˈOstʤˌɪs",
        "pgvector": "pˌi ʤˈi vˈɛktəɹ",
        "mysql": "mˌI ˌɛs kjˌu ˈɛl",
        "sqlite": "ˌɛs kjˌu lˈIt",
        "nosql": "nˈO sˈikwəl",
        "sqlalchemy": "ˌɛs kjˌu ˈɛl ˈælkəmi",
        "graphql": "ɡɹˈæf kjˌu ˈɛl",
        "redis": "ɹˈɛdɪs",
        "kafka": "kˈɑfkə",
        "clickhouse": "klˈɪkhˌWs",
        "bigquery": "bˈɪɡkwˌɪɹi",
        "databricks": "dˈAɾəbɹˌɪks",
        "prisma": "pɹˈɪzmə",
        "qdrant": "kwˈɑdɹənt",
        "weaviate": "wivˈiˌAt",
        "libsql": "lˈɪb ˌɛs kjˌu ˈɛl",
        "TiDB": "tˈI dˌi bˈi",
        // Companies and services
        "github": "ɡˈɪthˌʌb",
        "gitlab": "ɡˈɪtlˌæb",
        "gitea": "ɡˈɪtˌi",
        "forgejo": "fɔɹʤˈAO",
        "codeberg": "kˈOdbˌɜɹɡ",
        "openai": "ˌOpən ˌA ˈI",
        "xAI": "ˈɛks ˌA ˈI",
        "deepseek": "dˈipsˌik",
        "qwen": "kwˈɛn",
        "chatgpt": "ʧˈæt ʤˌi pˌi tˈi",
        "FAANG": "fˈæŋ",
        "ycombinator": "wˈI kˈɑmbənˌAɾəɹ",
        "spacex": "spˈAsˌɛks",
        "starlink": "stˈɑɹlˌɪŋk",
        "qualcomm": "kwˈɑlkˌɑm",
        "huawei": "wˈɑwˌA",
        "xiaomi": "ʃˈWmi",
        "bytedance": "bˈItdˌæns",
        "tiktok": "tˈɪktˌɑk",
        "linkedin": "lˈɪŋktˌɪn",
        "whatsapp": "wˈʌtsˌæp",
        "substack": "sˈʌbstˌæk",
        "bluesky": "blˈuskˌI",
        "figma": "fˈɪɡmə",
        "jetbrains": "ʤˈɛtbɹˌAnz",
        "jira": "ʤˈɪɹə",
        "pagerduty": "pˈAʤəɹdˌuɾi",
        "datadog": "dˈAɾədˌɔɡ",
        "grafana": "ɡɹəfˈɑnə",
        "opentelemetry": "ˈOpən təlˈɛmətɹi",
        "shopify": "ʃˈɑpəfˌI",
        "bitwarden": "bˈɪtwˌɔɹdən",
        "tailscale": "tˈAlskˌAl",
        "cloudflare": "klˈWdflˌɛɹ",
        "vercel": "vəɹsˈɛl",
        "netlify": "nˈɛtləfˌI",
        "heroku": "həɹˈOku",
        "supabase": "sˈupəbˌAs",
        "hetzner": "hˈɛtsnəɹ",
        "digitalocean": "dˈɪʤəɾᵊl ˈOʃən",
        "linode": "lˈInˌOd",
        "iphone": "ˈIfˌOn",
        "ipad": "ˈIpˌæd",
        "icloud": "ˈIklˌWd",
        "airpods": "ˈɛɹpˌɑdz",
        "macbook": "mˈækbˌʊk",
        // Everything else
        "PhD": "pˌi ˌAʧ dˈi",
        "paas": "pˈæs",
        "iaas": "ˈIæs",
        "FOSS": "fˈɑs",
        "YAGNI": "jˈæɡni",
        "ethereum": "əθˈɪɹiəm",
        "monero": "mənˈɛɹO",
        "defi": "dˈifˌI",
        "gwern": "ɡwˈɜɹn",
    ]
}
