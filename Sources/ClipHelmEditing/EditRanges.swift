import ClipHelmCore

func intersection(_ first: MediaTimeRange, _ second: MediaTimeRange) throws -> MediaTimeRange? {
    let start = max(first.start, second.start)
    let end = min(first.end, second.end)
    return start < end ? try MediaTimeRange(start: start, end: end) : nil
}

func subtract(_ ranges: [MediaTimeRange], removing cut: MediaTimeRange) throws -> [MediaTimeRange] {
    var result: [MediaTimeRange] = []
    for range in ranges {
        guard let overlap = try intersection(range, cut) else {
            result.append(range)
            continue
        }
        if range.start < overlap.start {
            result.append(try MediaTimeRange(start: range.start, end: overlap.start))
        }
        if overlap.end < range.end {
            result.append(try MediaTimeRange(start: overlap.end, end: range.end))
        }
    }
    return result
}

func contains(_ range: MediaTimeRange, in segments: [EditSegment]) -> Bool {
    segments.contains { $0.sourceRange.start <= range.start && range.end <= $0.sourceRange.end }
}
