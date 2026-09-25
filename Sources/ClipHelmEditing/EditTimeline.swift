import ClipHelmCore

public struct EditTimelineSpan: Equatable, Sendable {
    public let source: MediaTimeRange
    public let edited: MediaTimeRange
}

/// Maps retained source intervals to a gapless edited timeline in integer microseconds.
public struct EditTimeline: Equatable, Sendable {
    public let spans: [EditTimelineSpan]
    public let duration: MediaTime

    public init(spec: ClipHelmEditSpec) throws {
        var cursor: Int64 = 0
        var mapped: [EditTimelineSpan] = []
        for segment in spec.segments {
            let (end, overflow) = cursor.addingReportingOverflow(segment.sourceRange.durationMicroseconds)
            guard !overflow else { throw ModelError.invalid("EditTimeline duration overflow") }
            mapped.append(EditTimelineSpan(source: segment.sourceRange,
                edited: try MediaTimeRange(start: MediaTime(microseconds: cursor),
                                           end: MediaTime(microseconds: end))))
            cursor = end
        }
        spans = mapped
        duration = try MediaTime(microseconds: cursor)
    }

    /// Returns nil for deleted source time. The final source endpoint maps to output end.
    public func editedTime(forSource time: MediaTime) throws -> MediaTime? {
        if time == spans.last?.source.end { return duration }
        guard let span = spans.first(where: { $0.source.start <= time && time < $0.source.end }) else {
            return nil
        }
        return try MediaTime(microseconds: span.edited.start.microseconds +
                             (time.microseconds - span.source.start.microseconds))
    }

    /// A cut boundary belongs to the next retained span; output end maps to source end.
    public func sourceTime(forEdited time: MediaTime) throws -> MediaTime {
        guard time <= duration else { throw ModelError.invalid("EditTimeline edited time") }
        if time == duration, let last = spans.last { return last.source.end }
        guard let span = spans.first(where: { $0.edited.start <= time && time < $0.edited.end }) else {
            throw ModelError.invalid("EditTimeline edited time")
        }
        return try MediaTime(microseconds: span.source.start.microseconds +
                             (time.microseconds - span.edited.start.microseconds))
    }

    public func editedRanges(forSource range: MediaTimeRange) throws -> [MediaTimeRange] {
        try spans.compactMap { span in
            let start = max(range.start, span.source.start)
            let end = min(range.end, span.source.end)
            guard start < end else { return nil }
            return try MediaTimeRange(
                start: MediaTime(microseconds: span.edited.start.microseconds +
                                 (start.microseconds - span.source.start.microseconds)),
                end: MediaTime(microseconds: span.edited.start.microseconds +
                               (end.microseconds - span.source.start.microseconds)))
        }
    }

    public func sourceRanges(forEdited range: MediaTimeRange) throws -> [MediaTimeRange] {
        guard range.end <= duration else { throw ModelError.invalid("EditTimeline edited range") }
        return try spans.compactMap { span in
            let start = max(range.start, span.edited.start)
            let end = min(range.end, span.edited.end)
            guard start < end else { return nil }
            return try MediaTimeRange(
                start: MediaTime(microseconds: span.source.start.microseconds +
                                 (start.microseconds - span.edited.start.microseconds)),
                end: MediaTime(microseconds: span.source.start.microseconds +
                               (end.microseconds - span.edited.start.microseconds)))
        }
    }
}
