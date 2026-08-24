//
//  TimeSeriesTests.swift
//  SpatiumDDITests
//

import Foundation
import Testing

@testable import SpatiumDDI

/// Folding a server's minute buckets down to something a phone can draw.
@Suite("Time-series condensing")
struct TimeSeriesTests {
    /// One sample a minute, counting up from a fixed instant.
    private func samples(_ values: [Int], every seconds: Int = 60) -> [Sample] {
        values.enumerated().map { index, value in
            Sample(
                t: Date(timeIntervalSince1970: 1_780_000_000 + Double(index * seconds)),
                value: value
            )
        }
    }

    /// Anything already small enough is handed back untouched, bucket width
    /// included. Re-bucketing a 60-point series into 60 buckets would relabel
    /// the axis for no reason.
    @Test("A series under the limit is not touched")
    func underLimit() {
        let input = samples([1, 2, 3, 4, 5])
        let result = TimeSeries.condense(input, bucketSeconds: 60, into: 180)
        #expect(result.samples == input)
        #expect(result.bucketSeconds == 60)
    }

    @Test("An empty series stays empty")
    func empty() {
        let result = TimeSeries.condense([], bucketSeconds: 60)
        #expect(result.samples.isEmpty)
        #expect(result.bucketSeconds == 60)
    }

    /// The whole point: nothing is dropped. A chart that lost traffic while
    /// claiming to show a window would be worse than no chart, because it
    /// reads as a quiet estate.
    @Test("Condensing preserves the total")
    func preservesTotal() {
        let values = (1...1000).map { $0 % 7 }
        let result = TimeSeries.condense(samples(values), bucketSeconds: 60, into: 180)
        #expect(result.samples.reduce(0) { $0 + $1.value } == values.reduce(0, +))
    }

    /// A 24-hour window at one-minute buckets is about 1,400 points and a
    /// 7-day window about 2,000. Both have to come back drawable.
    @Test("Real window sizes come back within the limit", arguments: [60, 343, 1407, 2004])
    func withinLimit(count: Int) {
        let result = TimeSeries.condense(
            samples(Array(repeating: 1, count: count)), bucketSeconds: 60, into: 180)
        #expect(result.samples.count <= 180)
        #expect(result.samples.reduce(0) { $0 + $1.value } == count)
    }

    /// The reported bucket width has to match what the samples actually cover,
    /// or the caption under the chart is a lie about the axis.
    @Test("The bucket width grows by the same factor the samples shrank by")
    func bucketWidth() {
        // 360 samples into at most 180 buckets is a factor of two.
        let result = TimeSeries.condense(
            samples(Array(repeating: 1, count: 360)), bucketSeconds: 60, into: 180)
        #expect(result.samples.count == 180)
        #expect(result.bucketSeconds == 120)
    }

    /// A count that does not divide evenly must not overflow the limit — a
    /// factor that rounded down would leave one bucket too many.
    @Test("An uneven division still fits, with a short final bucket")
    func unevenDivision() {
        let result = TimeSeries.condense(
            samples(Array(repeating: 1, count: 181)), bucketSeconds: 60, into: 180)
        #expect(result.samples.count <= 180)
        // 181 into pairs is 91 buckets, the last holding a single sample.
        #expect(result.samples.count == 91)
        #expect(result.samples.last?.value == 1)
        #expect(result.samples.reduce(0) { $0 + $1.value } == 181)
    }

    /// Buckets are stamped with where they start. Stamping the end would draw
    /// an hour of traffic as though it had already happened.
    @Test("A bucket carries the timestamp of its first sample")
    func stampsBucketStart() {
        let input = samples([1, 1, 1, 1])
        let result = TimeSeries.condense(input, bucketSeconds: 60, into: 2)
        #expect(result.samples.count == 2)
        #expect(result.samples[0].t == input[0].t)
        #expect(result.samples[1].t == input[2].t)
    }

    /// A spike survives rather than being averaged into the baseline — the
    /// reason condensing sums instead of taking a mean.
    @Test("A spike is still visible after condensing")
    func spikeSurvives() {
        var values = Array(repeating: 1, count: 400)
        values[200] = 5000
        let result = TimeSeries.condense(samples(values), bucketSeconds: 60, into: 180)
        let peak = result.samples.map(\.value).max() ?? 0
        let typical = result.samples.map(\.value).min() ?? 0
        #expect(peak > 5000 - 1)
        #expect(peak > typical * 100)
    }
}
