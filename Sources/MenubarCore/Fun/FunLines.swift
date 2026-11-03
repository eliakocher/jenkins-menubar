import Foundation

/// The built-in lines of the fun layer: at least ten for each ``FunKey``, funny and kind, with no name of a person or a
/// company. They stand in whenever Haiku's pool is empty, Claude is off, or the app is offline.
///
/// A line may hold tokens (``FunKey/tokens``) that ``fill(_:_:)`` replaces with the real number.
public enum FunLines {
    /// Returns the built-in lines of a key.
    public static func lines(for key: FunKey) -> [String] {
        switch key {
        case .redemption: redemption
        case .streak: streak
        case .longBuild: longBuild
        case .fridayFail: fridayFail
        case .mondayFirst: mondayFirst
        case .thirdFailure: thirdFailure
        case .merged: merged
        case .inboxZero: inboxZero
        case .funFact: funFact
        case .tip: tips
        case .caught: caught
        case .lunch: lunch
        case .goHome: goHome
        case .noDeploys: noDeploys
        case .midnightOil: midnightOil
        case .joke: jokes
        case .birthday: birthday
        case .anniversary: anniversary
        }
    }

    /// Replaces the tokens of a line.
    ///
    /// - Parameters:
    ///   - line: the line, like `{d} of building.`
    ///   - values: the token's value by its name with braces, like `["{d}": "1h12m"]`
    public static func fill(_ line: String, _ values: [String: String]) -> String {
        values.reduce(line) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    // MARK: - Build moments

    static let redemption = [
        "Back to green. The butler lowers the tissue box.",
        "Redemption arc complete. Roll the credits.",
        "Green again. Nobody saw the red. Nobody.",
        "From red to green: the comeback nobody asked for and everybody needed.",
        "The pipeline has seen the light.",
        "Fixed it. The butler is quietly proud.",
        "Red no more. Please step away from the keyboard slowly.",
        "A green build after all that. Frame this one.",
        "And just like that, it passes. Don't ask it why.",
        "Plot twist: it works. The butler checked twice.",
        "The red ones are a bad dream now. Enjoy the green.",
    ]

    /// the kicker after "🔥 10 green in a row."
    static let streak = [
        "The butler is taking notes.",
        "Somebody call the press.",
        "Don't touch anything.",
        "Nobody breathe on the pipeline.",
        "This is how legends start.",
        "The flaky tests must be on holiday.",
        "Keep this energy.",
        "The butler is running out of hats.",
        "Suspiciously good.",
        "Please do not push. Just admire it.",
    ]

    static let longBuild = [
        "{d} of building. The butler read a novel meanwhile.",
        "That build took {d}. Somewhere a kettle went cold.",
        "{d}. You could have flown to a small country.",
        "More than an hour of pipeline. The butler took up knitting.",
        "{d} later, it finishes. Patience is a build artifact.",
        "A {d} build: the longest relationship this week.",
        "It ran for {d}. The butler aged gracefully.",
        "{d}: enough time to learn the cello.",
        "Done after {d}. The coffee machine sends its regards.",
        "{d} of waiting, rewarded with a notification. Worth it.",
    ]

    static let fridayFail = [
        "A red build on a Friday afternoon. The butler suggests Monday.",
        "Friday, after four, and red. Close the laptop. It will still be red on Monday.",
        "The weekend starts in a moment. This failure can wait. Probably.",
        "Failing on a Friday evening is a power move. Go home.",
        "Whatever broke, it will look smaller after the weekend.",
        "Friday builds fail. It is written. Rebuild on Monday?",
        "The butler has seen this movie. It ends with a Monday fix.",
        "Red on Friday: the universe's way of saying log off.",
        "Do not deploy. Do not rebase. Do not make eye contact with the pipeline.",
        "A Friday failure. Take a screenshot, take a walk.",
    ]

    static let mondayFirst = [
        "First build of the week. The butler had a coffee already. Where is yours?",
        "Monday's first build. A gentle start, please.",
        "A new week, a fresh pipeline. The butler believes in you.",
        "Monday morning build. The weekend is a distant memory.",
        "The week begins. The butler irons his tie.",
        "It's Monday. Every build is a small victory.",
        "Monday build, reporting for duty.",
        "Welcome back. The pipelines missed you, mostly.",
        "First build of the week: no pressure, only vibes.",
        "The inbox can wait until the coffee is done.",
    ]

    static let thirdFailure = [
        "Third failure in a row on this one. The butler is out of tissues.",
        "Three reds in a row. Maybe ask the code nicely?",
        "Three strikes. Take a short walk, then read the log properly.",
        "Third time unlucky. The butler recommends a second pair of eyes.",
        "Red, red, red. The traffic light is stuck.",
        "Three in a row: a pattern, not bad luck.",
        "The third failure. A rubber duck is standing by.",
        "Three reds. Time to question one assumption. Any assumption.",
        "A hat trick! The wrong kind, sadly.",
        "Third failure on this merge request. Deep breath, kettle on.",
    ]

    static let merged = [
        "Merged! The butler throws a very small parade.",
        "Into the trunk it goes. Well done.",
        "Shipped, merged and one open tab fewer.",
        "Another one lands. The main branch says thank you.",
        "Merged. The butler is wearing his good bow tie.",
        "Done and merged. Go stretch, you earned it.",
        "Off your plate and onto the main branch.",
        "Merge complete. The review comments can finally rest.",
        "Gone but not forgotten: merged.",
        "That's a wrap on this one. Merged.",
    ]

    static let inboxZero = [
        "The butler polished the empty tray.",
        "Nothing needs you. Enjoy the silence.",
        "All clear. The butler does a tiny victory lap.",
        "Zero. Zilch. Nada. Beautiful.",
        "Everything is handled. Go make tea.",
        "A rare and beautiful creature: the empty inbox.",
        "You did it. The tray is empty and so is the guilt.",
        "No to-dos left. Suspicious, but lovely.",
        "The butler has nothing to carry. Suspiciously restful.",
        "A clean slate. Don't look at your other inboxes.",
    ]

    static let funFact = [
        "You've watched {builds} builds. The butler is tired.",
        "{builds} builds seen so far. The butler would like a raise.",
        "{greens} of {builds} builds went green. The butler is an optimist.",
        "The butler has been on duty for {days} days. No sick leave yet.",
        "Fun fact: a green build feels better after a red one.",
        "Fun fact: the butler can't read logs. He just nods wisely.",
        "Fun fact: \"it works on my machine\" has shipped more than one machine.",
        "Fun fact: every flaky test was green when it was written.",
        "Fun fact: the butler counts builds instead of sheep.",
        "Fun fact: coffee has never failed a build. Correlation is strong.",
        "Fun fact: somewhere, a build is running that nobody remembers starting.",
    ]

    static let caught = [
        "You caught me. Tell no one.",
        "Hey! I was just checking the weather in there.",
        "Okay, okay. You got me. Nice reflexes.",
        "Shhh. I wasn't here.",
        "Caught! The butler bows, red in the face.",
        "I do this for the thrill. Don't tell the pipelines.",
        "Fast fingers. Take a cookie.",
        "You win this round. I'll be back.",
        "Peek-a-boo, but you actually clicked. Respect.",
        "Alright, I'm going back to work. Mostly.",
    ]

    // MARK: - Timers and surprises

    static let lunch = [
        "Lunch time. The builds will keep; the sandwich won't.",
        "It's noon. The pipelines can eat later.",
        "Lunch! Even the butler takes his plate seriously.",
        "Step away from the keyboard. Soup is a valid deployment strategy.",
        "Midday. Go outside; the sun doesn't run in CI.",
        "The butler recommends food, then the next red build.",
        "Time to eat. The merge request will still be there.",
        "Noon. The coffee machine says hello, the kitchen says soup.",
        "Lunch break: zero tickets, maximum calories.",
        "The best code is written after a decent lunch.",
    ]

    static let goHome = [
        "It's 17:30. The pipelines will run without you. Go home.",
        "Half past five. Close the laptop, the builds will manage.",
        "Time to go home. The butler locks up.",
        "The day is done. Whatever is red will be red tomorrow too.",
        "Go home. Seriously. The butler has it covered.",
        "17:30: the last push of the day is a bad idea. Go home.",
        "Home time. The tests can flake all they like without you.",
        "The workday ends here. The butler turns off the lights.",
        "Log off, stretch, and let the pipeline finish its sentence.",
        "Evening! Leave the debugging for the morning you.",
    ]

    static let noDeploys = [
        "Friday afternoon: no deploys. The butler checks your pockets.",
        "It's Friday after four. The deploy button is on a break.",
        "No deploys today. Let the weekend be quiet.",
        "Friday 16:00: the butler hides the big red button.",
        "Whatever you were about to ship, it will ship better on Monday.",
        "Deploying on a Friday is how stories start. Don't be the story.",
        "The weekend is near. Keep the production calm.",
        "A Friday deploy is a bold choice. A Monday deploy is a wise one.",
        "The butler has taken the deploy keys. He'll give them back Monday.",
        "No heroics on a Friday afternoon, please.",
    ]

    static let midnightOil = [
        "It's {time}. The butler yawns. Go to bed; the build can wait.",
        "{time} already? The butler is asleep standing up.",
        "Burning the midnight oil at {time}. The butler brought a blanket.",
        "It's {time}. Nothing good gets merged at this hour.",
        "{time}. The bug will still be there in the morning, rested and smug.",
        "The butler yawns at {time}. Take the hint.",
        "{time}: the hour of questionable decisions. Sleep on it.",
        "Late again at {time}. The butler pours you a warm milk.",
        "It's {time}. Even the flaky tests are asleep.",
        "{time}. Future you sends a polite request: go to bed.",
    ]

    static let jokes = [
        "There are two hard things in software: naming, caching and off-by-one errors.",
        "A test walks into a bar. It passes. Then it fails. Then it passes.",
        "The butler's favorite git command is the one that undoes the last one.",
        "A flaky test is just a test with a mood.",
        "Merge conflicts are just code meeting each other for the first time.",
        "The build is green. Nobody touch it. Nobody breathe.",
        "Why do pipelines never get lonely? They always have stages.",
        "Rubber duck debugging works. The duck has seen things.",
        "A good commit message is a gift to future you. Future you is a stranger.",
        "The cloud is just someone else's computer. The butler checks its pulse.",
        "Rebase: because history should read like you knew what you were doing.",
    ]

    static let birthday = [
        "A build has been running for {h}. Happy birthday, little build. 🎂",
        "{h} of running. The build blows out a candle.",
        "The build turns {h} old. Don't rush it, it's growing.",
        "Cake for the build: it has run for {h}.",
        "{h} and still going. The butler sings quietly.",
        "Happy runtime-birthday! {h} on the clock.",
        "{h} in, and the build is in great spirits.",
        "The build is celebrating {h} of uptime. Confetti not included.",
        "One more candle: {h} of running.",
        "{h} old and still compiling. Respect.",
    ]

    static let anniversary = [
        "{y} with MegaMonitor. The butler is still here. Fireworks!",
        "Happy anniversary: {y} of watching builds together.",
        "{y} since the butler's first day. He has opinions about your pipelines now.",
        "The butler celebrates {y} on the job. No raise requested. Much.",
        "{y} together. The butler brought sparklers.",
        "Anniversary! {y} of green, red and everything between.",
        "{y} of builds watched. The butler is wearing a party hat.",
        "Cheers to {y}: the butler's contract renews automatically.",
        "{y} on duty. The butler counts that as a good start.",
        "Fireworks for {y} of faithful butler service.",
    ]

    // MARK: - The butler's tip of the day

    /// The tips: some about the app, some plain developer wisdom. The first group is checked against the app.
    static let tips = [
        "Press ⌘R in the pane to check now, ⌘0 to open the window.",
        "Hold ⌥ while you click a row to open it in the browser instead of the app.",
        "Watch a Build… follows a build of a colleague, with an alert when it ends.",
        "Rebuild with Changes… lets you edit the parameters before a build starts again.",
        "Hide Until the Next Build clears a finished build from the list for now.",
        "Settings → Notifications sets where each Inbox event goes: Big Panel, Desktop or Inbox Only.",
        "The Menu Bar settings reorder the pane's rows and decide which ones have a flyout.",
        "A failed build's page can ask Claude why it failed, when Claude is on.",
        "Right-click an alert's background to open its console or hide its build.",
        "Small commits are easier to review. The butler has seen what happens to the other kind.",
        "Read the first failing line of a log before the last one: the cause comes first, the noise last.",
        "If a test fails only sometimes, write down when. The pattern is the bug.",
        "A branch name that says what it is saves a question every week.",
        "Before you rebuild, read the log. A rebuild is a coin toss with extra steps.",
        "The best review comment explains why, not only what.",
        "Name the flaky test in the merge request. It makes the next person's day shorter.",
        "A green build you don't understand is only a red build that hasn't happened yet.",
        "Drink some water. The compiler will wait.",
        "Take a short walk when the same error shows up twice. It helps more than a third rebuild.",
        "Delete code with joy. The best line is the one you didn't have to maintain.",
        "A good TODO has a name and a reason. A bad one has a date that has passed.",
        "Ask for a review early, while the change is still small and your pride too.",
        "The log is a story. Start at the first sentence that sounds wrong.",
        "Tabs, spaces, both fine. The butler cares about the tests.",
        "Close one tab you don't need. Then another. Feel lighter.",
        "Say thanks in a review. Nobody ever regretted it.",
        "The rubber duck on your desk has solved more bugs than you give it credit for.",
        "Stand up and stretch between two builds. The pipeline never minds.",
        "A flaky test is a bug with a day job. Give it your attention.",
        "Commit messages are letters to the future. Write one that is easy to read.",
    ]
}
