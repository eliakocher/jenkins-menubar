import Foundation

/// A parameter a Jenkins job defines, from `property[parameterDefinitions[…]]` (PIPE-09).
public struct ParameterDefinition: Hashable, Sendable, Identifiable {
    /// How the parameter is edited.
    public enum Kind: String, Hashable, Sendable {
        /// a toggle; the form sends `true` or `false`
        case boolean
        /// a picker over ``choices``
        case choice
        /// one line of text
        case string
        /// several lines of text
        case text
        /// a secret: Jenkins never shows its value, so the sheet shows none and sends one only when it is typed
        case password
        /// a run, a file or a plugin's own type: it isn't edited here, Jenkins takes its default
        case unsupported
    }

    public var name: String
    public var kind: Kind
    /// the choices of a ``Kind/choice``, in Jenkins's order, the first being the job's default
    public var choices: [String]
    /// the job's default as a form sends it; `nil` when Jenkins shows none, as for a password
    public var defaultValue: String?
    /// the definition's description, which the sheet shows under the field
    public var details: String?

    public var id: String { name }

    public init(name: String, kind: Kind, choices: [String] = [], defaultValue: String? = nil, details: String? = nil) {
        self.name = name
        self.kind = kind
        self.choices = choices
        self.defaultValue = defaultValue
        self.details = details
    }

    /// Returns the kind a Jenkins type name stands for.
    ///
    /// Jenkins names it in `_class` (`hudson.model.StringParameterDefinition`) and in the exported `type`; a plugin's
    /// own type, a run or a file is ``Kind/unsupported``.
    ///
    /// - Parameter name: `_class` or `type`
    public static func kind(ofJenkinsType name: String) -> Kind {
        let simple = name.split(separator: ".").last.map(String.init) ?? name
        let base = simple.hasSuffix("ParameterDefinition") ? String(simple.dropLast("ParameterDefinition".count)) : simple
        switch base {
        case "String": return .string
        case "Text": return .text
        case "Boolean": return .boolean
        case "Choice": return .choice
        case "Password": return .password
        default: return .unsupported
        }
    }
}

/// One parameter of the rebuild sheet: the job's definition and the value as it stands in the form.
public struct RebuildField: Hashable, Sendable, Identifiable {
    public var definition: ParameterDefinition
    /// the value as a form sends it: the text, `true` or `false`; empty for a password nobody typed
    public var value: String

    public var id: String { definition.name }

    public init(definition: ParameterDefinition, value: String) {
        self.definition = definition
        self.value = value
    }

    /// whether a toggle reads on; for a boolean field
    public var isOn: Bool {
        get { value == "true" }
        set { value = newValue ? "true" : "false" }
    }
}

/// What "Rebuild with Changes…" edits: the job's parameters, filled with the build's values (PIPE-09).
public struct RebuildForm: Hashable, Sendable {
    /// the editable parameters, in the job's order
    public var fields: [RebuildField]
    /// the names of the parameters the sheet can't edit; Jenkins takes their defaults
    public var skipped: [String]
    /// whether the job defines parameters at all; a job without gets `build`, not `buildWithParameters`
    public var isParameterized: Bool

    public init(fields: [RebuildField], skipped: [String] = [], isParameterized: Bool) {
        self.fields = fields
        self.skipped = skipped
        self.isParameterized = isParameterized
    }

    /// Fills the job's definitions with a build's parameters.
    ///
    /// A parameter the build has no value for takes the job's default, a choice its first choice. A choice the job
    /// no longer offers keeps the build's value as one more option, so that "Rebuild" can still send it unchanged. A
    /// parameter the job no longer defines isn't listed: Jenkins ignores it.
    ///
    /// - Parameters:
    ///   - definitions: the job's parameter definitions
    ///   - original: the build's parameters
    public init(definitions: [ParameterDefinition], original: [BuildParameter]) {
        var fields: [RebuildField] = []
        var skipped: [String] = []
        for definition in definitions {
            var definition = definition
            switch definition.kind {
            case .unsupported:
                skipped.append(definition.name)
                continue
            case .password:
                // Jenkins never shows a password's value: empty means "send nothing", so the job's default stays.
                fields.append(RebuildField(definition: definition, value: ""))
                continue
            default:
                break
            }
            let build = original.first { $0.name == definition.name }?.value
            var value = build ?? definition.defaultValue ?? ""
            switch definition.kind {
            case .boolean:
                value = value.lowercased() == "true" ? "true" : "false"
            case .choice:
                if let build, !definition.choices.contains(build) {
                    definition.choices.append(build)
                }
                if build == nil, definition.defaultValue == nil {
                    value = definition.choices.first ?? ""
                }
            default:
                break
            }
            fields.append(RebuildField(definition: definition, value: value))
        }
        self.init(fields: fields, skipped: skipped, isParameterized: !definitions.isEmpty)
    }

    /// The parameters the request sends: every edited field, but not a password nobody typed, so that Jenkins takes
    /// its default as it does for "Rebuild Identically".
    public var parameters: [BuildParameter] {
        fields.compactMap { field in
            if field.definition.kind == .password, field.value.isEmpty {
                return nil
            }
            return BuildParameter(name: field.definition.name, value: field.value)
        }
    }
}
