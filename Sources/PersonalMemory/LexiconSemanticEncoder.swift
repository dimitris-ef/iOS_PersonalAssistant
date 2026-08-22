import Foundation

/// A small, honest, offline encoder: text projected onto everyday concepts.
///
/// ## What this is
///
/// Each dimension is a concept a personal assistant actually deals in —
/// travelling, working, getting ready, money, people, health — plus a block of
/// hashed dimensions so that words outside the lexicon still tell two texts
/// apart. "It takes me half an hour to drive to work" and "how long is my
/// commute?" land close together because *commute*, *drive* and *work* all point
/// at the same few concepts, even though the two sentences share no content
/// word. That is the Part 9 example, and it is the property this exists for.
///
/// ## What this is not
///
/// Not a trained language model, and it does not pretend to be. It knows the
/// words in its lexicon and nothing else; it cannot tell that "the place I go
/// every morning" means work. Apple's `NaturalLanguage` sentence encoder is
/// better at exactly that and is used when the device has one — this is what
/// runs when it does not.
///
/// ## Why it is worth having anyway
///
/// Three reasons, and the third is the one that decided it.
///
/// 1. It is genuinely useful. Concept overlap is most of what "similar meaning"
///    means for sentences about somebody's commute.
/// 2. It works everywhere — Linux, Windows, CI, an old device, a Simulator
///    where the framework declines — with no model download and no network.
/// 3. It is deterministic, so the ranking tests assert on real behaviour rather
///    than on a mock that was written to make them pass. A test double that
///    encodes the answer is a test of nothing.
///
/// Bump ``version`` whenever the lexicon or the projection changes: stored
/// vectors are keyed on it, and a silent change is how stale vectors start
/// ranking the wrong memories forever.
public struct LexiconSemanticEncoder: SemanticEncoder {
    public let identity = SemanticEncoderIdentity(providerID: "lexicon.concept", version: 1)

    /// Always. That is the point of it.
    public var isAvailable: Bool { get async { true } }

    /// How many hashed dimensions carry words the lexicon does not know.
    ///
    /// Enough that two unrelated rare words rarely collide, small enough that a
    /// vector stays cheap. Collisions here cost a little spurious similarity
    /// between unrelated texts, which the relevance threshold absorbs.
    private static let residualDimensions = 48

    /// How much an unknown word counts relative to a recognised concept.
    ///
    /// Below one on purpose. "Sony" and "Nikon" being different words is worth
    /// something; it is worth less than both sentences being about cameras.
    private static let residualWeight: Float = 0.4

    public init() {}

    public func embedding(for text: String) async throws -> SemanticVector {
        let vector = Self.project(text)
        guard !vector.isEmpty else { throw SemanticEncodingError.emptyText }
        return vector
    }

    /// The synchronous core, so tests and the deduplicator can use it directly.
    public static func vector(for text: String) -> SemanticVector {
        project(text)
    }

    private static func project(_ text: String) -> SemanticVector {
        let profile = MemoryTextProfile(text)
        guard !profile.isEmpty else { return SemanticVector([]) }

        let conceptCount = Concept.allCases.count
        var components = [Float](repeating: 0, count: conceptCount + residualDimensions)

        for term in profile.terms {
            let concepts = Concept.concepts(for: term)
            if concepts.isEmpty {
                // Unknown word. It still distinguishes this text from another —
                // just less than a concept does.
                let slot = conceptCount + Int(stableHash(term) % UInt64(residualDimensions))
                components[slot] += residualWeight
            } else {
                // A word that means several things at once — "commute" is
                // travel and work and time — spreads over them rather than
                // counting three times. Otherwise the busiest words would
                // dominate every vector they appear in.
                let share = 1 / Float(concepts.count).squareRoot()
                for concept in concepts {
                    components[concept.index] += share
                }
            }
        }

        return SemanticVector(components)
    }

    /// FNV-1a, for the same reason ``MemoryContentHash`` uses it: `Hasher` is
    /// seeded per process, and a residual dimension that moved between launches
    /// would invalidate every cached vector on every start.
    private static func stableHash(_ text: String) -> UInt64 {
        let prime: UInt64 = 0x100000001b3
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* prime
        }
        return value
    }
}

extension LexiconSemanticEncoder {
    /// The concepts the lexicon knows about.
    ///
    /// Chosen from what people tell a personal assistant, not from a general
    /// ontology. Each case is one dimension of the vector; the ordering is
    /// therefore part of the encoder's version and must not be reshuffled
    /// without bumping it.
    enum Concept: Int, CaseIterable {
        case travel
        case work
        case time
        case preparation
        case home
        case food
        case drink
        case shopping
        case health
        case exercise
        case money
        case people
        case media
        case technology
        case assistantBehaviour
        case sleep
        case calendarDay
        case weather
        case trip
        case study
        case communication
        case admin
        case leisure
        case transportMode

        var index: Int { rawValue }

        /// The concepts a stemmed term belongs to, if any.
        static func concepts(for term: String) -> [Concept] {
            lexicon[term] ?? []
        }

        /// Terms are stored **stemmed**, matching `MemoryTextProfile.terms`.
        ///
        /// `MemoryTextNormalizer.stem` leaves words of four characters or fewer
        /// alone and strips a small set of suffixes from longer ones, so entries
        /// here are written the way that function would leave them — "minut",
        /// "groceri", "prefer" — and short words like "car" and "gym" unchanged.
        private static let lexicon: [String: [Concept]] = {
            var table: [String: [Concept]] = [:]

            func add(_ concept: Concept, _ words: [String]) {
                for word in words {
                    let stem = MemoryTextNormalizer.stem(word)
                    // Deduplicated, because plurals collapse: "minute" and
                    // "minutes" both stem to "minute", and counting the concept
                    // twice would let a word's inflections outweigh a word that
                    // happens to have none.
                    guard !(table[stem]?.contains(concept) ?? false) else { continue }
                    table[stem, default: []].append(concept)
                }
            }

            // "Commute" is three concepts at once — a journey, to work, taking
            // time — and saying so is most of why "how long is my commute?"
            // finds "it takes me 30 minutes to drive to work".
            add(.work, ["commute", "commuting"])
            add(.time, ["commute", "commuting"])
            add(.travel, [
                "commute", "commuting", "drive", "driving", "journey", "route",
                "traffic", "road", "travel", "travelling", "traveling", "trip",
                "distance", "away", "far", "near", "arrive", "arrival", "depart",
                "leave", "leaving", "mile", "miles", "km", "kilometre",
            ])
            add(.transportMode, [
                "car", "bus", "train", "tube", "metro", "subway", "bike",
                "bicycle", "cycle", "walk", "walking", "taxi", "uber", "tram",
                "ferry", "scooter",
            ])
            add(.work, [
                "work", "working", "office", "job", "shift", "employer",
                "meeting", "colleague", "boss", "desk", "workday", "workplace",
                "career", "client", "standup",
            ])
            add(.time, [
                "time", "minute", "minutes", "hour", "hours", "long", "duration",
                "early", "earlier", "late", "later", "quick", "slow", "clock",
                "oclock", "allow", "takes", "take", "spend", "half", "quarter",
                "soon", "advance", "beforehand", "start", "starting", "begin",
                "finish", "end", "before", "after", "until", "ahead", "while",
            ])
            add(.preparation, [
                "ready", "prepare", "preparing", "preparation", "shower",
                "dress", "dressed", "pack", "packing", "getting", "wake",
                "waking", "breakfast", "brush", "makeup", "iron", "sort",
            ])
            add(.home, [
                "home", "house", "flat", "apartment", "kitchen", "bedroom",
                "bathroom", "garden", "living", "indoors", "chore", "chores",
                "tidy", "clean", "cleaning", "laundry", "dishes", "washing",
            ])
            add(.food, [
                "eat", "eating", "food", "meal", "lunch", "dinner", "supper",
                "cook", "cooking", "recipe", "hungry", "snack", "vegetarian",
                "vegan", "allergy", "allergic", "gluten",
            ])
            add(.drink, [
                "coffee", "tea", "water", "beer", "wine", "drink", "drinking",
                "espresso", "latte", "caffeine", "alcohol", "cafe", "pub",
            ])
            add(.shopping, [
                "shop", "shopping", "buy", "buying", "store", "supermarket",
                "groceries", "grocery", "purchase", "order", "delivery",
                "market", "basket",
            ])
            add(.health, [
                "doctor", "dentist", "gp", "clinic", "hospital", "medication",
                "medicine", "pill", "prescription", "appointment", "therapy",
                "therapist", "checkup", "vitamin", "dose",
            ])
            add(.exercise, [
                "gym", "exercise", "workout", "training", "run", "running",
                "swim", "swimming", "yoga", "fitness", "weights", "cardio",
                "stretch", "sport",
            ])
            add(.money, [
                "rent", "bill", "bills", "pay", "paying", "payment", "invoice",
                "bank", "salary", "tax", "taxes", "budget", "mortgage",
                "subscription", "insurance", "expense", "money", "cost",
            ])
            add(.people, [
                "friend", "family", "mum", "mom", "dad", "father", "mother",
                "partner", "wife", "husband", "girlfriend", "boyfriend",
                "brother", "sister", "son", "daughter", "neighbour", "neighbor",
                "birthday", "anniversary", "name", "called",
            ])
            add(.media, [
                "camera", "photo", "photography", "music", "film", "movie",
                "series", "book", "reading", "podcast", "album", "song",
                "playlist", "game", "gaming", "lens", "sony", "canon", "nikon",
            ])
            add(.technology, [
                "phone", "laptop", "computer", "app", "software", "screen",
                "battery", "charger", "wifi", "device", "mode", "dark", "light",
                "setting", "settings",
            ])
            add(.assistantBehaviour, [
                "remind", "reminder", "reminders", "notify", "notification",
                "alarm", "alert", "nudge", "snooze", "repeat", "confirm",
                "prefer", "preference", "tone", "concise", "brief", "verbose",
            ])
            add(.sleep, [
                "sleep", "sleeping", "bed", "bedtime", "nap", "tired", "rest",
                "asleep", "awake", "night", "overnight",
            ])
            add(.calendarDay, [
                "monday", "tuesday", "wednesday", "thursday", "friday",
                "saturday", "sunday", "weekend", "weekends", "weekday",
                "weekdays", "daily", "weekly", "monthly", "today", "tomorrow",
                "morning", "afternoon", "evening", "date", "day", "week",
                "month", "year",
            ])
            add(.weather, [
                "weather", "rain", "raining", "sun", "sunny", "snow", "cold",
                "hot", "warm", "wind", "windy", "forecast", "umbrella",
            ])
            add(.trip, [
                "holiday", "vacation", "flight", "airport", "hotel", "booking",
                "passport", "luggage", "suitcase", "abroad", "visit",
            ])
            add(.study, [
                "study", "studying", "class", "course", "exam", "lecture",
                "revision", "revise", "homework", "assignment", "university",
                "school", "college", "deadline",
            ])
            add(.communication, [
                "call", "calling", "email", "message", "text", "reply",
                "respond", "letter", "post", "voicemail", "chat", "ring",
            ])
            add(.admin, [
                "form", "paperwork", "application", "renew", "renewal",
                "registration", "licence", "license", "document", "contract",
                "council", "admin",
            ])
            add(.leisure, [
                "hobby", "relax", "weekendplan", "cinema", "theatre", "concert",
                "walk", "park", "garden", "friends", "socialise", "socialize",
            ])

            return table
        }()
    }
}
