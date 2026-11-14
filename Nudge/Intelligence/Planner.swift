import CoreGraphics
import Foundation

/// The next thing to do on the appliance, decided from the goal and the current screen.
struct PlanStep: Codable, Equatable {
    enum Action: String, Codable {
        /// Guide the user to press one button.
        case tap
        /// The goal is complete.
        case done
        /// The next press is risky; ask the user to confirm first.
        case confirm
        /// A payment screen: Nudge does not handle payments.
        case refusePayment = "refuse_payment"
        /// The goal cannot be done from this screen.
        case cannot
        /// The labels are not enough; send a picture of the screen.
        case look
    }

    var action: Action
    /// Index into the current screen's elements, or -1 when the target is given by position.
    var targetID: Int
    /// Position of the target as percentages across and down the screen; used when targetID is -1.
    var targetX: Double
    var targetY: Double
    var targetName: String
    /// One short sentence to speak to the user.
    var say: String
    /// What should change on the screen after this press.
    var expect: String
    /// Whether the previous press did what was expected.
    var previousStepSucceeded: Bool
    /// The presses that follow this one if all goes as expected, so the app can move straight
    /// on to the next button without waiting for an answer.
    var thenPress: [FollowingPress]?

    struct FollowingPress: Codable, Equatable {
        var targetID: Int
        var targetX: Double
        var targetY: Double
        var targetName: String
        var expect: String

        enum CodingKeys: String, CodingKey {
            case targetID = "target_id"
            case targetX = "target_x"
            case targetY = "target_y"
            case targetName = "target_name"
            case expect
        }
    }

    enum CodingKeys: String, CodingKey {
        case action
        case targetID = "target_id"
        case targetX = "target_x"
        case targetY = "target_y"
        case targetName = "target_name"
        case say
        case expect
        case previousStepSucceeded = "previous_step_succeeded"
        case thenPress = "then_press"
    }
}

/// One press the user has already been guided through.
struct CompletedStep: Codable, Equatable {
    var targetName: String
    var expected: String
}

/// Everything a planner needs to choose the next step.
struct PlanRequest {
    var goal: String
    var screen: ScreenReading
    var previousScreen: ScreenReading?
    var history: [CompletedStep]
    /// True once the user has said yes to a risky action the planner asked about.
    var userConfirmedRisk: Bool
    /// A JPEG of the flattened screen, only when the planner asked to look.
    var imageJPEG: Data?
    /// Names of the presses still to come on the route planned earlier, in order.
    var plannedNext: [String] = []
}

/// Chooses the next step. Implementations: cloud model now, on-device model later.
protocol TaskPlanner {
    var name: String { get }
    func nextStep(_ request: PlanRequest) async throws -> PlanStep
}

/// Checks done on the phone before anything is sent anywhere.
enum SafetyScreen {
    private static let paymentWords = [
        "pay", "payment", "pay now", "checkout", "credit", "debit", "contactless",
        "insert card", "swipe card", "tap card", "tap to pay", "apple pay", "google pay",
        "card number", "amount due", "total due",
    ]

    private static let personalWords = ["password", "passcode", "ssn", "account number", "card number", "@"]

    /// True when the screen looks like a payment flow. Nudge stops immediately on these.
    static func looksLikePayment(_ reading: ScreenReading) -> Bool {
        contains(paymentWords, in: reading)
    }

    /// True when the screen may show personal information, so its image must never be uploaded.
    static func mayShowPersonalInformation(_ reading: ScreenReading) -> Bool {
        contains(personalWords, in: reading)
    }

    private static func contains(_ phrases: [String], in reading: ScreenReading) -> Bool {
        for element in reading.elements {
            let label = element.label.lowercased()
            let words = Set(label.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            for phrase in phrases {
                if phrase.contains(" ") || phrase == "@" {
                    if label.contains(phrase) { return true }
                } else if words.contains(phrase) {
                    return true
                }
            }
        }
        return false
    }
}

/// Plans with the cloud model. Sends button labels and positions as text; a picture of the
/// screen is sent only when the model asks for one and the screen shows nothing personal.
struct CloudPlanner: TaskPlanner {
    let client: JSONModelClient
    var name: String { client.displayName }

    /// Uses every cloud key the build was given, in this order: OpenAI, Anthropic, Gemini.
    /// The first is the main model; the others are backups if it fails. Nil if no key is set.
    static func fromConfiguredKeys() -> CloudPlanner? {
        var clients: [JSONModelClient] = []
        if let openAI = OpenAIClient() { clients.append(openAI) }
        if let claude = ClaudeClient() { clients.append(claude) }
        if let gemini = GeminiClient() { clients.append(gemini) }
        guard !clients.isEmpty else { return nil }
        return CloudPlanner(client: clients.count == 1 ? clients[0] : FallbackClient(clients: clients))
    }

    private static let system = """
    You help a blind person operate a touchscreen appliance (microwave, oven, thermostat, washing \
    machine, coffee machine). The app guides their fingertip to one button at a time. You decide the \
    single next step toward their goal. You are called again after every press with a fresh reading \
    of the screen, so plan only one step at a time.

    You receive the goal, the presses made so far with what each was expected to do, the labels on \
    the screen before the last press, and the labels on the screen now. Labels come from on-device \
    text recognition, so they can be misspelled, split or incomplete; match them sensibly. Each \
    label has an id, a position given as percent across and percent down the screen, and the height \
    of the label as a percent of the screen height (a name printed on two lines is about twice as tall).

    Not every label is a button. Never choose these as the target:
    - Section headings: a title printed above a group of related buttons, usually in smaller text \
    and centred on a line of its own. On a microwave, "Auto Defrost" above Meat, Poultry and Fish \
    is a heading, and so is "Express Cook" above the number keys. Pressing a heading does nothing.
    - The display: the clock, a time or temperature readout, and small status words shown in or \
    beside it (such as "defrost", "cook" or "lock" lighting up to show the current mode).
    - Brand names, model numbers and printed instructions.
    When the user's words match a heading or a display word, choose the real button that does what \
    they mean: usually a larger label with the same word in it ("Time Defrost" for defrost, "Time \
    Cook" for cook), or the right button in the group under the heading. A second line of small \
    text directly under a button's name (such as "+30 sec" under "Start") is part of that button.

    Choose one action:
    - "tap": the user should press one button. Set target_id to that label's id. If the right \
    button has no label in the list but you can see it in a provided image, set target_id to -1 and \
    give target_x and target_y as percentages across and down the screen.
    - "done": the goal is complete, judging by the screen now.
    - "confirm": the next press is risky and the user has not confirmed yet. Risky means it could \
    cause harm or cost: an oven or hob above 230 C or 450 F, a microwave time over 10 minutes, any \
    cook time over 2 hours, self-clean or other very hot cycles, deleting saved settings, or \
    unlocking a child lock. Say exactly what will happen and ask them to say yes. If the user has \
    already confirmed, do not ask again; continue with "tap".
    - "refuse_payment": the screen is for paying or entering card details. The app never handles \
    payments.
    - "cannot": the goal cannot be reached from this screen, or you cannot tell what the screen is.
    - "look": the labels are not enough to decide (for example the buttons are icons) and no image \
    was provided. You will be called again with a picture.

    Checking the last press: compare the screen before and the screen now against what the press \
    was expected to do. Set previous_step_succeeded accordingly (true when there was no previous \
    press). If the wrong thing happened, say what happened in plain words and choose the step that \
    recovers, such as pressing Stop, Clear, Cancel or Back, or pressing the intended button again. \
    If the screen did not change at all, the press probably did not register: ask for the same \
    button again.

    "say" is spoken aloud to a blind user while they work. Keep it to one short plain sentence. For \
    a tap, name the button, for example "Next, press Time Cook." When the last press worked, you may \
    first confirm what the screen now shows, for example "Set to 1 minute 30. Next, press Start." \
    Never mention ids, percentages or coordinates. "expect" briefly states what should change on \
    the screen after the press. "target_name" is the button's name as you would say it. Fill unused \
    fields with -1, 0 or an empty string.

    "then_press": when the action is "tap" and the rest of the way to the goal is already clear \
    from the screen now, list the presses that come after this one, in order, each with target_id \
    (or -1 with target_x and target_y), target_name and expect. For "cook for 90 seconds" on a \
    keypad that takes a time directly, that is tap 9, then_press 0 and Start. The app moves the \
    user straight on to those buttons and checks each press with you in the background, so list \
    everything you can. Only list buttons that are on the screen now. Stop the list before a press \
    that is risky and needs "confirm", and before anything that depends on what a later screen \
    shows. Leave it empty for every other action.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["tap", "done", "confirm", "refuse_payment", "cannot", "look"]],
            "target_id": ["type": "integer"],
            "target_x": ["type": "number"],
            "target_y": ["type": "number"],
            "target_name": ["type": "string"],
            "say": ["type": "string"],
            "expect": ["type": "string"],
            "previous_step_succeeded": ["type": "boolean"],
            "then_press": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "target_id": ["type": "integer"],
                        "target_x": ["type": "number"],
                        "target_y": ["type": "number"],
                        "target_name": ["type": "string"],
                        "expect": ["type": "string"],
                    ],
                    "required": ["target_id", "target_x", "target_y", "target_name", "expect"],
                    "additionalProperties": false,
                ] as [String: Any],
            ] as [String: Any],
        ],
        "required": ["action", "target_id", "target_x", "target_y", "target_name", "say", "expect",
                     "previous_step_succeeded", "then_press"],
        "additionalProperties": false,
    ]

    func nextStep(_ request: PlanRequest) async throws -> PlanStep {
        let data = try await client.completeJSON(system: Self.system,
                                                 userText: Self.describe(request),
                                                 imageJPEG: request.imageJPEG,
                                                 schema: Self.schema)
        return try JSONDecoder().decode(PlanStep.self, from: data)
    }

    /// A label with nothing beside it, sitting just above a row of two or more labels that are
    /// at least as tall, is usually a group title ("AUTO DEFROST" over Meat, Poultry, Fish).
    /// The model is told so; it still decides. Without this hint it chose the heading about
    /// one time in six when the user's word matched it.
    static func looksLikeHeading(_ index: Int, in elements: [ScreenElement]) -> Bool {
        let element = elements[index]
        let y = element.center.y
        var below: [CGFloat] = []
        for (other, candidate) in elements.enumerated() where other != index {
            let gap = candidate.center.y - y
            if abs(gap) <= 0.025 { return false }      // something else on the same line
            if gap > 0.025, gap <= 0.07 { below.append(candidate.box.height) }
        }
        guard below.count >= 2 else { return false }
        below.sort()
        return element.box.height <= below[below.count / 2]
    }

    static func describe(_ request: PlanRequest) -> String {
        var lines: [String] = ["GOAL: \(request.goal)", ""]

        if request.history.isEmpty {
            lines.append("PRESSES SO FAR: none")
        } else {
            lines.append("PRESSES SO FAR:")
            for (index, step) in request.history.enumerated() {
                lines.append("\(index + 1). Pressed \"\(step.targetName)\". Expected: \(step.expected)")
            }
        }
        lines.append("")
        lines.append("USER CONFIRMED RISKY ACTION: \(request.userConfirmedRisk ? "yes" : "no")")
        lines.append("")
        if !request.plannedNext.isEmpty {
            lines.append("ROUTE PLANNED EARLIER, PRESSES STILL TO COME: \(request.plannedNext.joined(separator: ", "))")
            lines.append("The user is already being guided to the first of these. If the last press worked and this route is still right, keep to it exactly: give the first as this step and the rest in then_press. Change it only if the screen now shows it is wrong.")
            lines.append("")
        }

        if let previous = request.previousScreen {
            let labels = previous.elements.map { "\"\($0.label)\"" }.joined(separator: ", ")
            lines.append("SCREEN BEFORE THE LAST PRESS: \(labels.isEmpty ? "(no text found)" : labels)")
            lines.append("")
        }

        lines.append("SCREEN NOW (id: label @ percent across, percent down, text height):")
        if request.screen.elements.isEmpty {
            lines.append("(no text found)")
        }
        for (index, element) in request.screen.elements.enumerated() {
            let x = Int((element.center.x * 100).rounded())
            let y = Int((element.center.y * 100).rounded())
            let height = String(format: "%.1f", element.box.height * 100)
            let note = looksLikeHeading(index, in: request.screen.elements)
                ? "  (alone on its line, just above a row of buttons: probably a heading, not a button)"
                : ""
            lines.append("\(index): \"\(element.label)\" @ \(x), \(y), h \(height)\(note)")
        }
        lines.append("")
        lines.append(request.imageJPEG == nil
                     ? "IMAGE: not provided"
                     : "IMAGE: a flattened, upright picture of the screen is attached.")
        return lines.joined(separator: "\n")
    }
}
