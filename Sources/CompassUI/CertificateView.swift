import CompassDomain
import SwiftUI

/// Everything the certificate draws, as one plain value.
///
/// The view takes this and nothing else, which is what makes what the certificate
/// *says* testable — `.claude/skills/architecture.md`: behaviour goes in a plain
/// value beside the `View`; the `View` keeps the layout. On this screen that rule
/// is not stylistic: the whole product is a claim that what this document says is
/// true.
public struct CertificatePresentation: Hashable, Sendable, Identifiable {
    public let id: AchievementID
    public let copy: CertificateCopy
    /// `witness.evidenceRoot`. The seal's first 64 bits come from here.
    public let evidenceRoot: Data

    public init(id: AchievementID, copy: CertificateCopy, evidenceRoot: Data) {
        self.id = id
        self.copy = copy
        self.evidenceRoot = evidenceRoot
    }
}

/// Surface 2 of the 3 the v1 budget allows off the launch path. `docs/product.md`,
/// `.claude/skills/ui.md`.
///
/// A `.fullScreenCover` over Today. **Full-bleed paper: the screen *is* the
/// sheet**, which is why the seal has nothing to float above. Type is
/// left-ranged and the impression sits at the left margin — a notary die on a
/// letter, not a centred certificate of achievement.
///
/// It **deliberately breaks the bottom-anchored rule** that governs Today. This
/// is not a daily interaction; it is a document, shown once. There is no
/// sub-navigation, no detail view and no second tap — `docs/product.md` cut a
/// separate certificate detail screen from v1 precisely so it could not be
/// smuggled back in as already designed.
///
/// ### No colour at all
///
/// No gold, no accent, no tint. It is entirely type and paper, and the only image
/// in it is the die frame. `docs/product.md` bans every token vocabulary a colour
/// would import; the certificate reads as a document rather than a payout.
///
/// ### One animation
///
/// The card fades up 12pt over 220ms, and nothing else on the screen moves.
///
/// The design adds a second — the seal scaling 1.035 to 1.0 over 180ms from
/// t=60ms — and it is **not shipped**. `.claude/skills/ui.md` line 46 enumerates
/// exactly one certificate animation and adds "It does not pop, bounce, fly, or
/// spin"; a scale-in is the nearest thing on that list, and `ui.md` authorises no
/// second animation. The design concedes the point itself: "the certificate would
/// lose nothing by being still, and stillness is more in character for a
/// document." So it is still. `memory/decisions.md`, 2026-08-01.
public struct CertificateView: View {

    private let presentation: CertificatePresentation
    private let onDone: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The card's own entry. `.claude/skills/ui.md`: "fades up 12pt over 220ms.
    /// It does not pop, bounce, fly, or spin. Readable and dismissable by 300ms."
    @State private var hasAppeared = false

    /// The share export, rendered once after the first frame.
    ///
    /// It holds a finished image and no decision: the composition it renders is
    /// ``CertificateExport``, which is an ordinary view built from the same
    /// document, and the geometry it is rendered at is pinned in
    /// `CertificateMetricsTests`. Rendering 1206 x 1962 pixels inside `body`
    /// would do it again on every re-evaluation.
    @State private var shareImage: Image?

    public init(
        presentation: CertificatePresentation, onDone: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.onDone = onDone
    }

    public var body: some View {
        ZStack {
            CertificatePalette.paper(for: colorScheme).ignoresSafeArea()
            layout
        }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 12)
        .task {
            withAnimation(.easeOut(duration: 0.22)) { hasAppeared = true }
            shareImage = CertificateExport.render(
                presentation: presentation, colorScheme: colorScheme
            )
        }
    }

    // MARK: The two layouts

    /// **"This screen would rather be long than crowded."**
    ///
    /// Above `accessibility1` the sheet becomes a `ScrollView` with the two
    /// controls pinned below it in their own block, separated by the lower rule.
    /// That is a structural change rather than a scale factor, and it is the only
    /// reason a 42pt identifier block can be readable in full: the identifier is
    /// "the one thing on the screen that must be readable in full", so it wraps
    /// on characters and never truncates, which means it has to be allowed off
    /// the bottom of the frame.
    @ViewBuilder
    private var layout: some View {
        if CertificateMetrics.isStructural(dynamicTypeSize) {
            VStack(spacing: 0) {
                ScrollView {
                    CertificateDocument(presentation: presentation)
                        .padding(.horizontal, CertificateMetrics.horizontalMargin)
                        .padding(.top, CertificateMetrics.topInset)
                        .padding(.bottom, CertificateMetrics.scrollEdgeHeight)
                }
                .scrollBounceBehavior(.basedOnSize)
                // Transparent to paper, so a line of type never appears to be cut
                // in half by the control block below it.
                .overlay(alignment: .bottom) { scrollEdge }
                rule(CertificatePalette.lowerRule(for: colorScheme))
                controls
                    .padding(.horizontal, CertificateMetrics.horizontalMargin)
                    .padding(.bottom, CertificateMetrics.bottomInset)
                    .padding(.top, CertificateMetrics.ruleToIdentifier)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                CertificateDocument(presentation: presentation)
                Spacer(minLength: CertificateMetrics.minimumSpacer)
                controls
            }
            .padding(.horizontal, CertificateMetrics.horizontalMargin)
            .padding(.top, CertificateMetrics.topInset)
            .padding(.bottom, CertificateMetrics.bottomInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scrollEdge: some View {
        LinearGradient(
            colors: [
                CertificatePalette.paper(for: colorScheme).opacity(0),
                CertificatePalette.paper(for: colorScheme),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: CertificateMetrics.scrollEdgeHeight)
        .allowsHitTesting(false)
    }

    private func rule(_ colour: Color) -> some View {
        colour.frame(height: CertificateMetrics.ruleHeight)
    }

    // MARK: The controls

    /// A space-between row. **No fills, no background.** "Done" is the only one
    /// that must be reachable, which is why it is the one that is never
    /// conditional.
    ///
    /// `ShareLink` here is **the single one in the product** — `.claude/skills/ui.md`
    /// permits exactly one, on the certificate, rendered via `ImageRenderer`. The
    /// settings sheet's bundle export uses `fileExporter` instead, specifically so
    /// that sentence stays literally true.
    private var controls: some View {
        HStack(spacing: 0) {
            if let shareImage {
                ShareLink(
                    item: shareImage,
                    preview: SharePreview(
                        presentation.copy.claimLines.joined(separator: " "), image: shareImage
                    )
                ) {
                    Text("Share")
                        .font(.system(.body))
                        .foregroundStyle(CertificatePalette.ink(for: colorScheme))
                        .frame(
                            minWidth: CertificateMetrics.controlTarget(at: dynamicTypeSize),
                            minHeight: CertificateMetrics.controlTarget(at: dynamicTypeSize),
                            alignment: .leading
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button(action: onDone) {
                Text("Done")
                    .font(.system(.body).weight(.semibold))
                    .foregroundStyle(CertificatePalette.ink(for: colorScheme))
                    .frame(
                        minWidth: CertificateMetrics.controlTarget(at: dynamicTypeSize),
                        minHeight: CertificateMetrics.controlTarget(at: dynamicTypeSize),
                        alignment: .trailing
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Presenting it

extension View {

    /// `.fullScreenCover` where the certificate ships, `.sheet` where it does
    /// not exist.
    ///
    /// `Package.swift` declares macOS **only** so the pure suites run under
    /// `swift test` with no simulator; nothing ships there, and `.fullScreenCover`
    /// is unavailable on it. The shipped presentation is the full-screen one,
    /// because the certificate is full-bleed paper — the screen *is* the sheet.
    ///
    /// It is one modifier rather than two `#if`s at the two call sites, so that
    /// "the certificate is presented the same way from Today and from the list"
    /// is a fact about this function rather than a thing to remember twice.
    func certificateCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        return fullScreenCover(item: item, content: content)
        #else
        return sheet(item: item, content: content)
        #endif
    }
}

// MARK: - The document itself

/// Masthead, claim, date, seal, identifier — **and nothing else**.
///
/// It is factored out because the share export is "identical composition with the
/// status bar and both controls removed and nothing added". Two copies of this
/// arrangement would be two documents that could disagree, and the one that was
/// wrong would be the one that left the phone.
struct CertificateDocument: View {

    let presentation: CertificatePresentation

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            masthead
            Spacer().frame(height: CertificateMetrics.mastheadToRule)
            CertificatePalette.mastheadRule(for: colorScheme)
                .frame(height: CertificateMetrics.ruleHeight)
            Spacer().frame(height: CertificateMetrics.ruleToClaim)

            claim
            Spacer().frame(height: CertificateMetrics.spaceAboveDate(at: dynamicTypeSize))
            date
            Spacer().frame(height: CertificateMetrics.spaceAboveSeal(at: dynamicTypeSize))

            sealRow

            Spacer().frame(height: CertificateMetrics.sealRowToRule)
            CertificatePalette.lowerRule(for: colorScheme)
                .frame(height: CertificateMetrics.ruleHeight)
            Spacer().frame(height: CertificateMetrics.ruleToIdentifier)
            identifier
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Masthead

    /// One word. Clamped at `xxLarge` because at 42pt, tracked and uppercase, it
    /// stops being a letterhead and starts shouting the one word on the screen
    /// that carries no information.
    private var masthead: some View {
        Text(CertificateCopy.masthead)
            .font(.system(.caption2).weight(.semibold))
            .textCase(.uppercase)
            .tracking(CertificateMetrics.mastheadTracking)
            .foregroundStyle(CertificatePalette.mastheadInk(for: colorScheme))
            .dynamicTypeSize(...CertificateMetrics.mastheadClamp)
    }

    // MARK: Claim

    /// **The content, and the only thing here that scales all the way.**
    /// `.system(.largeTitle, design: .serif)` — a relative metric, so 34 becomes
    /// 60 at AX5 and the claim reflows to three lines.
    ///
    /// Above the structural threshold the hard line break is dropped and the two
    /// sentences render as one run: an explicit break inside a paragraph that is
    /// already wrapping produces a ragged orphan.
    private var claim: some View {
        Text(
            CertificateMetrics.claimBreaksLines(at: dynamicTypeSize)
                ? presentation.copy.claimLines.joined(separator: "\n")
                : presentation.copy.claimLines.joined(separator: " ")
        )
        .font(.system(.largeTitle, design: .serif))
        .tracking(CertificateMetrics.claimTracking)
        .lineSpacing(
            CertificateMetrics.lineSpacing(
                pointSize: CertificateMetrics.claimPointSize,
                lineHeight: CertificateMetrics.claimLineHeight
            )
        )
        .foregroundStyle(CertificatePalette.ink(for: colorScheme))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var date: some View {
        Text(presentation.copy.date)
            .font(.system(.body, design: .serif))
            .lineSpacing(
                CertificateMetrics.lineSpacing(
                    pointSize: CertificateMetrics.datePointSize,
                    lineHeight: CertificateMetrics.dateLineHeight
                )
            )
            .foregroundStyle(CertificatePalette.secondaryInk(for: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: The seal, and the attestation beside or below it

    /// Bottom-ranged, gap 20, seal flush to the left margin and fixed.
    ///
    /// This void was dead space in the earlier turns; the attestation fills it,
    /// "which is where a notary block sits on a real document". Above the
    /// structural threshold the row cannot hold 44pt text beside a 120pt die, so
    /// the attestation stacks underneath instead — the seal never shrinks below
    /// its accessibility size to make room for text.
    @ViewBuilder
    private var sealRow: some View {
        if CertificateMetrics.isStructural(dynamicTypeSize) {
            VStack(alignment: .leading, spacing: 0) {
                seal
                Spacer().frame(height: CertificateMetrics.spaceAboveStackedAttestation)
                attestation
            }
        } else {
            HStack(alignment: .bottom, spacing: CertificateMetrics.sealRowGap) {
                seal
                attestation
                    .padding(.bottom, CertificateMetrics.attestationBottomPadding)
            }
        }
    }

    private var seal: some View {
        SealView(
            evidenceRoot: presentation.evidenceRoot,
            size: CertificateMetrics.sealSize(at: dynamicTypeSize)
        )
    }

    /// **It changes by gaining a line, never by moving anything.**
    ///
    /// One line by default and possibly forever — "Sealed on this device", with
    /// no anchoring language of any kind before `AnchorState == .confirmed`.
    private var attestation: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presentation.copy.attestationLines, id: \.self) { line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.footnote)
        .lineSpacing(
            CertificateMetrics.lineSpacing(
                pointSize: CertificateMetrics.attestationPointSize,
                lineHeight: CertificateMetrics.attestationLineHeight
            )
        )
        .foregroundStyle(CertificatePalette.secondaryInk(for: colorScheme))
    }

    // MARK: The identifier block

    /// Monospaced, so line 3 aligns under line 2's first hex character.
    ///
    /// **It wraps and never truncates.** It is the one thing on the screen that
    /// must be readable in full — the whole digest is here precisely because
    /// sixteen hex characters verify nothing, and a truncated digest on a
    /// document that invites verification is worse than no digest at all.
    private var identifier: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presentation.copy.identifierLines, id: \.self) { line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .lineSpacing(
            CertificateMetrics.lineSpacing(
                pointSize: CertificateMetrics.identifierPointSize,
                lineHeight: CertificateMetrics.identifierLineHeight
            )
        )
        .foregroundStyle(CertificatePalette.identifierInk(for: colorScheme))
        .textSelection(.enabled)
    }
}

// MARK: - The share export

/// 402 x 654 at 1x, rendered at @3x to 1206 x 1962.
///
/// **Identical composition with the status bar and both controls removed, and
/// nothing added.** No app name, no URL, no QR, no invitation to anyone.
///
/// It is self-sufficient and independently checkable because the full digest is
/// on the artifact: a stranger holding this image and the export bundle can
/// recompute and compare without asking anyone anything. In the design's own
/// words, "it would look wrong on a feed, which is the intended outcome."
struct CertificateExport: View {

    let presentation: CertificatePresentation

    var body: some View {
        ZStack {
            CertificatePalette.paper
            CertificateDocument(presentation: presentation)
                .padding(.horizontal, CertificateMetrics.horizontalMargin)
                .padding(.vertical, CertificateMetrics.exportPadding)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(
            width: CertificateMetrics.exportWidth, height: CertificateMetrics.exportHeight
        )
    }

    /// Renders the export, or `nil` if the renderer produces nothing.
    ///
    /// `ImageRenderer` is `@MainActor` and the caller is a `.task` on the main
    /// actor, which is where a view hierarchy can be walked at all.
    @MainActor
    static func render(
        presentation: CertificatePresentation, colorScheme: ColorScheme
    ) -> Image? {
        let renderer = ImageRenderer(
            content: CertificateExport(presentation: presentation)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = CertificateMetrics.exportScale
        #if canImport(UIKit)
        guard let image = renderer.uiImage else { return nil }
        return Image(uiImage: image)
        #else
        guard let image = renderer.nsImage else { return nil }
        return Image(nsImage: image)
        #endif
    }
}
