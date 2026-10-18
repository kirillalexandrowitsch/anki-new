/// Domain failures carry values, never database errors or localized UI text.
public enum ValidationError: Error, Equatable, Sendable {
    case emptyName
    case duplicateName(normalized: String)
    case invalidUUID(String)
    case outOfRange(field: String)
    case arithmeticOverflow
    case invalidTimeZone(String)
    case invalidStudyDate
}
