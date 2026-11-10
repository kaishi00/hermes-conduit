//
//  ProviderLogoView.swift
//  Conduit
//
//  A model provider's logo beside its name, wherever providers are listed:
//  the Model sheet's All providers page, every setting's Model page,
//  Models & providers, the Add a provider sheet and Settings > Usage.
//  Hermes sends a provider's slug and name, never a logo, so the logos are
//  bundled (Resources/ProviderLogos.xcassets, from lobe-icons, MIT; see
//  Resources/ProviderLogos-LICENSE.txt) and matched here. A provider
//  without one shows its initial.
//

import SwiftUI

enum ProviderLogo {
    /// Hermes' provider slugs, each to its logo's asset. A provider Hermes
    /// lists under several slugs (a region, a plan, a sign-in) shares one.
    static let bySlug: [String: String] = [
        "nous": "nous",
        "openrouter": "openrouter",
        "fireworks": "fireworks",
        "novita": "novita",
        "lmstudio": "lmstudio",
        "anthropic": "anthropic",
        "openai-codex": "openai",
        "openai-api": "openai",
        "openai": "openai",
        "alibaba": "qwen",
        "alibaba-cn": "qwen",
        "alibaba-coding-plan": "qwen",
        "alibaba-coding-plan-cn": "qwen",
        "alibaba-token-plan": "qwen",
        "alibaba-token-plan-cn": "qwen",
        "qwen-oauth": "qwen",
        "xai": "xai",
        "xai-oauth": "xai",
        "xai-grok-oauth": "xai",
        "tencent-tokenhub": "tencent",
        "tencent-tokenplan": "tencent",
        "nvidia": "nvidia",
        "huggingface": "huggingface",
        "gemini": "gemini",
        "google-gemini-cli": "gemini",
        "vertex": "vertex",
        "deepseek": "deepseek",
        "zai": "zai",
        "kimi": "kimi",
        "kimi-cn": "kimi",
        "kimi-coding": "kimi",
        "kimi-coding-cn": "kimi",
        "kimi-for-coding": "kimi",
        "kimi-for-coding-highspeed": "kimi",
        "stepfun": "stepfun",
        "minimax": "minimax",
        "minimax-cn": "minimax",
        "minimax-oauth": "minimax",
        "ollama-cloud": "ollama",
        "arcee": "arcee",
        "gmi": "gmi",
        "kilocode": "kilocode",
        "opencode-zen": "opencode",
        "opencode-go": "opencode",
        "bedrock": "bedrock",
        "azure-foundry": "azure",
        "ai-gateway": "vercel",
        "commandcode": "commandcode",
        "commandcode-anthropic": "commandcode",
        "deepinfra": "deepinfra",
        "meta-ai": "meta",
        "nebius-token-factory": "nebius",
        "upstage": "upstage",
        "copilot": "copilot",
        "copilot-acp": "copilot",
    ]

    /// Words in a slug or name that name a provider, for one Hermes has no
    /// slug of ours for: a custom endpoint ("lab-vllm", "Together AI") or a
    /// plugin's. Whole words only, so "xai" never matches inside another.
    static let byWord: [(word: String, logo: String)] = [
        ("openrouter", "openrouter"), ("ollama", "ollama"), ("vllm", "vllm"), ("lmstudio", "lmstudio"),
        ("together", "together"), ("groq", "groq"), ("mistral", "mistral"), ("cerebras", "cerebras"),
        ("perplexity", "perplexity"), ("cohere", "cohere"), ("sambanova", "sambanova"), ("chutes", "chutes"),
        ("siliconflow", "siliconflow"), ("fireworks", "fireworks"), ("deepinfra", "deepinfra"),
        ("deepseek", "deepseek"), ("anthropic", "anthropic"), ("claude", "anthropic"), ("openai", "openai"),
        ("chatgpt", "openai"), ("codex", "openai"), ("gemini", "gemini"), ("vertex", "vertex"),
        ("qwen", "qwen"), ("dashscope", "qwen"), ("kimi", "kimi"), ("moonshot", "kimi"), ("minimax", "minimax"),
        ("glm", "zai"), ("zhipu", "zai"), ("grok", "xai"), ("xai", "xai"), ("nvidia", "nvidia"),
        ("huggingface", "huggingface"), ("bedrock", "bedrock"), ("azure", "azure"), ("vercel", "vercel"),
        ("stepfun", "stepfun"), ("nebius", "nebius"), ("novita", "novita"), ("copilot", "copilot"),
        ("opencode", "opencode"), ("kilocode", "kilocode"), ("nous", "nous"),
    ]

    /// The asset for a provider, by its slug, then any alias, then a word
    /// in its slug or name; nil when none is bundled.
    static func asset(slug: String, name: String? = nil, aliases: [String] = []) -> String? {
        for spelling in [slug] + aliases {
            var key = ProviderInfo.normalized(spelling)
            // A custom endpoint's saved spelling.
            if key.hasPrefix("custom:") { key.removeFirst("custom:".count) }
            if let logo = bySlug[key] { return "provider-" + logo }
        }
        let words = Set(([slug, name ?? ""] + aliases).flatMap(Self.words))
        // "LM Studio" and "Hugging Face" are one word in a slug.
        let joined = Set(([slug, name ?? ""] + aliases).map { Self.words($0).joined() })
        return byWord.first { words.contains($0.word) || joined.contains($0.word) }.map { "provider-" + $0.logo }
    }

    /// The initial a provider without a logo shows.
    static func initial(_ title: String) -> String {
        title.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// A provider's logo, or its initial in a circle when none is bundled.
/// Single-colour logos take the text colour, so they read in both
/// appearances; the others keep their brand colours.
struct ProviderLogoView: View {
    let asset: String?
    let title: String
    @ScaledMetric private var size: CGFloat

    init(slug: String, title: String, aliases: [String] = [], size: CGFloat = 20) {
        asset = ProviderLogo.asset(slug: slug, name: title, aliases: aliases)
        self.title = title
        _size = ScaledMetric(wrappedValue: size, relativeTo: .subheadline)
    }

    init(provider: ProviderInfo, size: CGFloat = 20) {
        self.init(slug: provider.name, title: provider.title, aliases: provider.aliases, size: size)
    }

    var body: some View {
        Group {
            if let asset {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
            } else {
                Text(verbatim: ProviderLogo.initial(title))
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color.secondary.opacity(0.18), in: Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A provider's quota on its row in a Model list: "80% left · resets
/// 21:44", or "Limited until …". Orange under a fifth left, red when none
/// is.
struct ProviderQuotaLine: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let summary: ProviderQuotaSummary

    var body: some View {
        Text(Self.text(summary))
            .scaledFont(.caption.monospacedDigit())
            .foregroundStyle(Self.tint(summary))
            .lineLimit(1)
    }

    static func text(_ summary: ProviderQuotaSummary, now: Date = Date()) -> String {
        let reset = summary.resetsAt.map { time($0, now: now) }
        guard let left = summary.left, left > 0 else {
            return reset.map { AppLocalization.string("Limited until \($0)") } ?? AppLocalization.string("Limited")
        }
        // A window nearly used up reads 0.4%, not 0%.
        let digits = left < 0.1 ? 0...1 : 0...0
        let percent = left.formatted(.percent.precision(.fractionLength(digits)).locale(AppLocalization.formattingLocale))
        return reset.map { AppLocalization.string("\(percent) left · resets \($0)") } ?? AppLocalization.string("\(percent) left")
    }

    static func tint(_ summary: ProviderQuotaSummary) -> Color {
        guard let left = summary.left, left > 0 else { return .red }
        return left < 0.2 ? .orange : .secondary
    }

    /// The time alone today, with the weekday within the week, else the date.
    static func time(_ date: Date, now: Date = Date()) -> String {
        let locale = AppLocalization.formattingLocale
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute().locale(locale))
        }
        if date > now, date.timeIntervalSince(now) < 6 * 86_400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(locale))
        }
        return date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }
}
